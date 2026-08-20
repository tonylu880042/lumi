import Foundation
import LumiApplication

/// Start failures owned by the Realtime adapter rather than the provider.
public enum OpenAIRealtimeAdapterError: Error, Equatable, Sendable {
    case startInProgress
    case alreadyActive
    case connectionEndedBeforeReady
    case toolTransportUnavailable
    case toolResultSendFailed
}

/// Maps an injected WebRTC transport into Lumi's provider-independent voice port.
public actor OpenAIRealtimeAdapter: VoiceSessionPort, VoiceToolCallPort {
    private enum Phase {
        case idle
        case starting
        case active
    }

    private let configuration: OpenAIRealtimeConfiguration
    private let clientSecretSource: any OpenAIRealtimeClientSecretSource
    private let transportFactory: any OpenAIRealtimeTransportFactory
    private let supportsWeeklySummaryTool: Bool

    private var phase: Phase = .idle
    private var generation: UInt64 = 0
    private var connectionAttemptToken: UInt64 = 0
    private var readyConnectionToken: UInt64?
    private var weeklySummaryToolEnabledForSession = false
    private var worker: Task<Void, Never>?
    private var currentTransport: (any OpenAIRealtimeTransport)?
    private var startContinuation: AsyncThrowingStream<Void, any Error>.Continuation?

    private var nextSubscriberID: UInt64 = 0
    private var subscribers: [UInt64: AsyncStream<VoiceSessionEvent>.Continuation] = [:]
    private var nextToolSubscriberID: UInt64 = 0
    private var toolSubscribers: [UInt64: AsyncStream<VoiceToolCall>.Continuation] = [:]

    public init(
        configuration: OpenAIRealtimeConfiguration,
        clientSecretSource: any OpenAIRealtimeClientSecretSource,
        transportFactory: any OpenAIRealtimeTransportFactory,
        enablesWeeklySummaryTool: Bool = false
    ) {
        self.configuration = configuration
        self.clientSecretSource = clientSecretSource
        self.transportFactory = transportFactory
        self.supportsWeeklySummaryTool = enablesWeeklySummaryTool
    }

    /// Returns after the provider emits `session.created`.
    public func start(context: VoiceContext) async throws {
        switch phase {
        case .starting:
            throw OpenAIRealtimeAdapterError.startInProgress
        case .active:
            throw OpenAIRealtimeAdapterError.alreadyActive
        case .idle:
            break
        }

        phase = .starting
        weeklySummaryToolEnabledForSession =
            supportsWeeklySummaryTool && context == .returningMember
        clearToolConnectionReadiness()
        generation &+= 1
        let acceptedGeneration = generation

        let readiness = AsyncThrowingStream<Void, any Error>.makeStream()
        startContinuation = readiness.continuation
        let sessionConfiguration = configuration(for: context)
        worker = Task { [weak self] in
            await self?.runSession(
                generation: acceptedGeneration,
                configuration: sessionConfiguration
            )
        }

        do {
            try await withTaskCancellationHandler(operation: {
                for try await _ in readiness.stream {
                    return
                }
                throw OpenAIRealtimeAdapterError.connectionEndedBeforeReady
            }, onCancel: {
                Task { [weak self] in
                    await self?.cancelStart(generation: acceptedGeneration)
                }
            })
        } catch {
            if error is CancellationError || Task.isCancelled {
                await cancelStart(generation: acceptedGeneration)
                throw CancellationError()
            }
            throw error
        }
    }

    public func eventUpdates() -> AsyncStream<VoiceSessionEvent> {
        let subscriberID = nextSubscriberID
        nextSubscriberID &+= 1
        let pair = AsyncStream<VoiceSessionEvent>.makeStream(
            of: VoiceSessionEvent.self,
            bufferingPolicy: .unbounded
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeSubscriber(id: subscriberID)
            }
        }
        subscribers[subscriberID] = pair.continuation
        return pair.stream
    }

    public func toolCallUpdates() -> AsyncStream<VoiceToolCall> {
        let subscriberID = nextToolSubscriberID
        nextToolSubscriberID &+= 1
        let pair = AsyncStream<VoiceToolCall>.makeStream(
            of: VoiceToolCall.self,
            bufferingPolicy: .unbounded
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeToolSubscriber(id: subscriberID)
            }
        }
        toolSubscribers[subscriberID] = pair.continuation
        return pair.stream
    }

    public func sendToolResult(_ result: VoiceToolResult) async throws {
        guard
            weeklySummaryToolEnabledForSession,
            phase == .active,
            let readyConnectionToken,
            let transport = currentTransport
        else {
            throw OpenAIRealtimeAdapterError.toolTransportUnavailable
        }

        try Task.checkCancellation()

        let functionCallOutput: Data
        let responseCreate: Data
        do {
            functionCallOutput = try OpenAIRealtimeWireEncoder.functionCallOutput(
                for: result
            )
            responseCreate = try OpenAIRealtimeWireEncoder.responseCreate()
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw OpenAIRealtimeAdapterError.toolResultSendFailed
        }

        try await sendToolData(functionCallOutput, via: transport)
        try Task.checkCancellation()
        guard
            phase == .active,
            self.readyConnectionToken == readyConnectionToken
        else {
            throw OpenAIRealtimeAdapterError.toolResultSendFailed
        }
        try await sendToolData(responseCreate, via: transport)
    }

    /// Stops the current session. Repeated calls do not close a transport twice.
    public func stop() async {
        guard phase != .idle || worker != nil || currentTransport != nil else {
            finishSubscribers()
            finishToolSubscribers()
            clearSessionToolCapability()
            return
        }

        generation &+= 1
        phase = .idle
        clearSessionToolCapability()
        worker?.cancel()
        worker = nil
        finishStart(throwing: CancellationError())

        let transport = currentTransport
        currentTransport = nil
        await transport?.close()
        finishSubscribers()
        finishToolSubscribers()
    }

    private func runSession(
        generation acceptedGeneration: UInt64,
        configuration sessionConfiguration: OpenAIRealtimeConfiguration
    ) async {
        var retryCount = 0

        while acceptedGeneration == generation, !Task.isCancelled {
            let outcome = await runConnection(
                generation: acceptedGeneration,
                configuration: sessionConfiguration,
                purpose: retryCount == 0 ? .initial : .reconnect
            )
            guard acceptedGeneration == generation, !Task.isCancelled else { return }

            switch outcome {
            case .stopped:
                return
            case .failedBeforeReady(let error):
                phase = .idle
                clearSessionToolCapability()
                finishStart(throwing: error)
                finishToolSubscribers()
                currentTransport = nil
                worker = nil
                return
            case .unexpectedEnd:
                guard retryCount == 0 else {
                    if phase == .starting {
                        phase = .idle
                        clearSessionToolCapability()
                        finishStart(
                            throwing: OpenAIRealtimeAdapterError.connectionEndedBeforeReady
                        )
                        finishToolSubscribers()
                        currentTransport = nil
                        worker = nil
                    } else {
                        finishTerminalFailure()
                    }
                    return
                }
                retryCount += 1
            case .retryFailed:
                finishTerminalFailure()
                return
            case .authorizationRequired:
                phase = .idle
                clearSessionToolCapability()
                publish(.authorizationRequired)
                finishSubscribers()
                finishToolSubscribers()
                currentTransport = nil
                worker = nil
                return
            }
        }
    }

    private enum ConnectionOutcome {
        case stopped
        case failedBeforeReady(any Error)
        case unexpectedEnd
        case retryFailed
        case authorizationRequired
    }

    private func runConnection(
        generation acceptedGeneration: UInt64,
        configuration sessionConfiguration: OpenAIRealtimeConfiguration,
        purpose: OpenAIRealtimeConnectionPurpose
    ) async -> ConnectionOutcome {
        let wasStarting = phase == .starting
        connectionAttemptToken &+= 1
        let acceptedConnectionToken = connectionAttemptToken
        clearToolConnectionReadiness()

        do {
            let secret = try await clientSecretSource.clientSecret(
                for: sessionConfiguration
            )
            guard acceptedGeneration == generation, !Task.isCancelled else {
                return .stopped
            }

            let transport = await transportFactory.makeTransport()
            let events = await transport.eventUpdates()
            guard acceptedGeneration == generation, !Task.isCancelled else {
                await transport.close()
                return .stopped
            }

            currentTransport = transport
            try await transport.connect(
                clientSecret: secret,
                configuration: sessionConfiguration,
                purpose: purpose,
                enablesWeeklySummaryTool: weeklySummaryToolEnabledForSession
            )
            guard acceptedGeneration == generation, !Task.isCancelled else {
                await transport.close()
                return .stopped
            }

            let mapper = OpenAIRealtimeEventMapper()
            var connectionReady = false
            for await providerEvent in events {
                guard acceptedGeneration == generation, !Task.isCancelled else {
                    return .stopped
                }

                if case .toolCall(let call) = providerEvent,
                   weeklySummaryToolEnabledForSession,
                   readyConnectionToken == acceptedConnectionToken,
                   phase == .active
                {
                    publishToolCall(call)
                }

                for mappedEvent in await mapper.map(providerEvent) {
                    switch mappedEvent {
                    case .ready:
                        connectionReady = true
                        readyConnectionToken = acceptedConnectionToken
                        if phase == .starting {
                            phase = .active
                            finishStartSuccessfully()
                        }
                    case .voice(let event):
                        guard connectionReady else {
                            if event == .failure {
                                clearToolConnectionReadiness()
                                await transport.close()
                                currentTransport = nil
                                if wasStarting {
                                    return .failedBeforeReady(
                                        OpenAIRealtimeAdapterError.connectionEndedBeforeReady
                                    )
                                }
                                return .retryFailed
                            }
                            continue
                        }
                        guard phase == .active else { continue }
                        publish(event)
                    }
                }
            }

            guard acceptedGeneration == generation, !Task.isCancelled else {
                return .stopped
            }
            clearToolConnectionReadiness()
            await transport.close()
            currentTransport = nil
            return .unexpectedEnd
        } catch {
            guard acceptedGeneration == generation, !Task.isCancelled else {
                return .stopped
            }
            let transport = currentTransport
            currentTransport = nil
            clearToolConnectionReadiness()
            await transport?.close()
            if wasStarting {
                return .failedBeforeReady(error)
            }
            if let authorizationError = error as? VoiceSessionAuthorizationError,
               authorizationError == .authorizationRequired {
                return .authorizationRequired
            }
            return .retryFailed
        }
    }

    private func cancelStart(generation acceptedGeneration: UInt64) async {
        guard acceptedGeneration == generation, phase == .starting else { return }
        generation &+= 1
        phase = .idle
        clearSessionToolCapability()
        worker?.cancel()
        worker = nil
        finishStart(throwing: CancellationError())

        let transport = currentTransport
        currentTransport = nil
        await transport?.close()
        finishToolSubscribers()
    }

    private func clearToolConnectionReadiness() {
        readyConnectionToken = nil
    }

    private func clearSessionToolCapability() {
        weeklySummaryToolEnabledForSession = false
        clearToolConnectionReadiness()
    }

    private func finishStartSuccessfully() {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.yield()
        continuation.finish()
    }

    private func finishStart(throwing error: any Error) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.finish(throwing: error)
    }

    private func publish(_ event: VoiceSessionEvent) {
        var terminated: [UInt64] = []
        for (id, continuation) in subscribers {
            if case .terminated = continuation.yield(event) {
                terminated.append(id)
            }
        }
        for id in terminated {
            subscribers.removeValue(forKey: id)
        }
    }

    private func publishToolCall(_ call: VoiceToolCall) {
        var terminated: [UInt64] = []
        for (id, continuation) in toolSubscribers {
            if case .terminated = continuation.yield(call) {
                terminated.append(id)
            }
        }
        for id in terminated {
            toolSubscribers.removeValue(forKey: id)
        }
    }

    private func finishTerminalFailure() {
        phase = .idle
        clearSessionToolCapability()
        publish(.failure)
        finishSubscribers()
        finishToolSubscribers()
        currentTransport = nil
        worker = nil
    }

    private func finishSubscribers() {
        let continuations = Array(subscribers.values)
        subscribers.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func finishToolSubscribers() {
        let continuations = Array(toolSubscribers.values)
        toolSubscribers.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeSubscriber(id subscriberID: UInt64) {
        subscribers.removeValue(forKey: subscriberID)
    }

    private func removeToolSubscriber(id subscriberID: UInt64) {
        toolSubscribers.removeValue(forKey: subscriberID)
    }

    private func sendToolData(
        _ data: Data,
        via transport: any OpenAIRealtimeTransport
    ) async throws {
        do {
            try await transport.send(data)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw OpenAIRealtimeAdapterError.toolResultSendFailed
        }
    }

    private func configuration(
        for context: VoiceContext
    ) -> OpenAIRealtimeConfiguration {
        let greetingInstruction: String
        switch context {
        case .returningMember:
            greetingInstruction = """
            這位訪客是已確認的回訪會員。請用「歡迎回來」問候，\
            但不要說出姓名或任何私人資料。
            """
        case .visitor:
            greetingInstruction = """
            這位訪客沒有已確認的會員身分。請使用不包含私人資料的一般問候。
            """
        }

        return OpenAIRealtimeConfiguration(
            model: configuration.model,
            voice: configuration.voice,
            instructions: configuration.instructions + "\n" + greetingInstruction
        )
    }
}
