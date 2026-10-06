import Foundation
import LumiApplication
import OSLog

/// Start failures owned by the Realtime adapter rather than the provider.
public enum OpenAIRealtimeAdapterError: Error, Equatable, Sendable {
    case startInProgress
    case alreadyActive
    case connectionEndedBeforeReady
    case recordedGreetingUnavailable
    case toolTransportUnavailable
    case toolResultSendFailed
}

/// Maps an injected WebRTC transport into Lumi's provider-independent voice port.
public actor OpenAIRealtimeAdapter: VoiceSessionPort, VoiceToolCallPort {
    private static let startupLogger = Logger(
        subsystem: "com.curves.lumi", category: "realtime-startup"
    )

    private static func logStartup(_ event: OpenAIRealtimeStartupEvent) {
        #if DEBUG
        startupLogger.notice("realtime startup: \(event.rawValue, privacy: .public)")
        #endif
    }

    private static func logStartupFailure(_ error: any Error) {
        #if DEBUG
        let reason = OpenAIRealtimeStartupFailure(classifying: error)
        startupLogger.error("realtime startup failed: \(reason.rawValue, privacy: .public)")
        #endif
    }

    private enum Phase {
        case idle
        case starting
        case active
    }

    private let configuration: OpenAIRealtimeConfiguration
    private let clientSecretSource: any OpenAIRealtimeClientSecretSource
    private let transportFactory: any OpenAIRealtimeTransportFactory
    private let supportsWeeklySummaryTool: Bool
    private let supportsVisitorEnrollmentTools: Bool
    private let supportsMemberMemoryTool: Bool
    private let recordedGreeting: (any RecordedGreetingPlayer)?
    private let now: @Sendable () -> Date

    // One-off Realtime cost-telemetry milestone. `nil` (the default) means no
    // usage is ever reported; this never affects voice-session behavior.
    private let usageReporter: (any OpenAIRealtimeUsageReporting)?
    private var nextUsageReportTurn = 0

    private var phase: Phase = .idle
    private var generation: UInt64 = 0
    private var connectionAttemptToken: UInt64 = 0
    private var readyConnectionToken: UInt64?
    private var standbyReady = false
    private var standbyWorkerGeneration: UInt64?
    private var weeklySummaryToolEnabledForSession = false
    private var visitorEnrollmentToolsEnabledForSession = false
    private var memberMemoryToolEnabledForSession = false
    private var conversationClosingToolEnabledForSession = false
    private var acceptedUserTurnForConversationClosing = false
    private var worker: Task<Void, Never>?
    private var currentTransport: (any OpenAIRealtimeTransport)?
    private var activeSessionConfiguration: OpenAIRealtimeConfiguration?
    private var activeSessionConfigurationWithoutMemory: OpenAIRealtimeConfiguration?
    private var activeVoiceContext: VoiceContext?
    private var activeConversationDirection: VoiceConversationDirection = .general
    private var activeMemberAddress: VoiceMemberAddress?
    private var activeMemoryContext: VoiceMemberMemoryContext?
    private var generatedGreetingPending = false
    private var generatedGreetingOutputIsActive = false
    private var localGreetingTask: Task<Void, Never>?
    private var conversationClosingTask: Task<Void, Never>?
    private var conversationClosingGeneration: UInt64?
    private var conversationEndRequestSent = false
    private var localGreetingTeardownInProgress = false
    private var localGreetingTeardownToken: UInt64?
    private var nextLocalGreetingTeardownToken: UInt64 = 0
    private var standbyActivationInProgress = false
    private var pendingActivationEvents: [VoiceSessionEvent] = []
    private var startContinuation: AsyncThrowingStream<Void, any Error>.Continuation?
    private(set) var processedProviderEventCount = 0

    private var nextSubscriberID: UInt64 = 0
    private var subscribers: [UInt64: AsyncStream<VoiceSessionEvent>.Continuation] = [:]
    private var nextToolSubscriberID: UInt64 = 0
    private var toolSubscribers: [UInt64: AsyncStream<VoiceToolCall>.Continuation] = [:]

    public init(
        configuration: OpenAIRealtimeConfiguration,
        clientSecretSource: any OpenAIRealtimeClientSecretSource,
        transportFactory: any OpenAIRealtimeTransportFactory,
        enablesWeeklySummaryTool: Bool = false,
        enablesVisitorEnrollmentTools: Bool = false,
        enablesMemberMemoryTool: Bool = false,
        usageReporter: (any OpenAIRealtimeUsageReporting)? = nil,
        recordedGreeting: (any RecordedGreetingPlayer)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.clientSecretSource = clientSecretSource
        self.transportFactory = transportFactory
        self.supportsWeeklySummaryTool = enablesWeeklySummaryTool
        self.supportsVisitorEnrollmentTools = enablesVisitorEnrollmentTools
        self.supportsMemberMemoryTool = enablesMemberMemoryTool
        self.usageReporter = usageReporter
        self.recordedGreeting = recordedGreeting
        self.now = now
    }

    /// Returns after the provider emits `session.created` using the general
    /// conversation direction.
    public func start(context: VoiceContext) async throws {
        try await start(
            context: context,
            direction: .general,
            memberAddress: nil,
            memoryContext: nil
        )
    }

    /// Returns after the provider emits `session.created` using the selected
    /// provider-neutral conversation direction.
    public func start(
        context: VoiceContext,
        direction: VoiceConversationDirection
    ) async throws {
        try await start(
            context: context,
            direction: direction,
            memberAddress: nil,
            memoryContext: nil
        )
    }

    /// Returns after the provider emits `session.created`, optionally with a
    /// validated label for an already-confirmed returning member.
    public func start(
        context: VoiceContext,
        direction: VoiceConversationDirection,
        memberAddress: VoiceMemberAddress?
    ) async throws {
        try await start(
            context: context,
            direction: direction,
            memberAddress: memberAddress,
            memoryContext: nil
        )
    }

    public func start(
        context: VoiceContext,
        direction: VoiceConversationDirection,
        memberAddress: VoiceMemberAddress?,
        memoryContext: VoiceMemberMemoryContext?
    ) async throws {
        guard !localGreetingTeardownInProgress else {
            throw OpenAIRealtimeAdapterError.startInProgress
        }

        switch phase {
        case .starting:
            throw OpenAIRealtimeAdapterError.startInProgress
        case .active:
            throw OpenAIRealtimeAdapterError.alreadyActive
        case .idle:
            break
        }

        guard !configuration.usesExternalGreeting || recordedGreeting != nil else {
            throw OpenAIRealtimeAdapterError.recordedGreetingUnavailable
        }

        activeVoiceContext = context
        activeConversationDirection = direction
        activeMemberAddress = memberAddress
        let effectiveMemoryContext = memoryContext?.effective(at: now())
        activeMemoryContext = effectiveMemoryContext
        generatedGreetingPending = context == .returningMember
            && effectiveMemoryContext?.hasPersonalizedOpening == true
        generatedGreetingOutputIsActive = false

        weeklySummaryToolEnabledForSession =
            supportsWeeklySummaryTool && context == .returningMember
        visitorEnrollmentToolsEnabledForSession =
            supportsVisitorEnrollmentTools && context == .visitor
        memberMemoryToolEnabledForSession =
            supportsMemberMemoryTool
                && context == .returningMember
                && effectiveMemoryContext != nil
        let sessionConfiguration = configuration(
            for: context,
            direction: direction,
            memberAddress: memberAddress,
            memoryContext: effectiveMemoryContext
        )
        activeSessionConfiguration = sessionConfiguration
        activeSessionConfigurationWithoutMemory = configuration(
            for: context,
            direction: direction,
            memberAddress: memberAddress,
            memoryContext: nil
        )
        conversationClosingToolEnabledForSession =
            sessionConfiguration.allowsConversationClosing && recordedGreeting != nil
        acceptedUserTurnForConversationClosing = false

        // A standby worker can finish between its transport cleanup and the
        // actor turn that clears `worker`. Do not join that completed task:
        // invalidate it and let this explicit start create a fresh session.
        if worker != nil,
           standbyWorkerGeneration == nil,
           currentTransport == nil,
           readyConnectionToken == nil
        {
            generation &+= 1
            worker?.cancel()
            worker = nil
        }

        if let transport = currentTransport, readyConnectionToken != nil {
            phase = .starting
            standbyReady = false
            standbyActivationInProgress = true
            pendingActivationEvents.removeAll()
            let acceptedGeneration = generation
            do {
                Self.logStartup(.activationRequested)
                try await withTaskCancellationHandler(operation: {
                    try await transport.activate(
                        configuration: sessionConfiguration,
                        enablesWeeklySummaryTool: weeklySummaryToolEnabledForSession,
                        enablesVisitorEnrollmentTools: visitorEnrollmentToolsEnabledForSession,
                        enablesMemberMemoryTool: memberMemoryToolEnabledForSession
                    )
                }, onCancel: {
                    Task { await transport.close() }
                })
                try Task.checkCancellation()
                guard acceptedGeneration == generation else {
                    throw CancellationError()
                }
                Self.logStartup(.activationReady)
                standbyActivationInProgress = false
                phase = .active
                flushPendingActivationEvents()
                startLocalGreetingIfNeeded(generation: acceptedGeneration)
                return
            } catch {
                guard acceptedGeneration == generation else {
                    throw CancellationError()
                }
                standbyActivationInProgress = false
                generation &+= 1
                phase = .idle
                standbyReady = false
                pendingActivationEvents.removeAll()
                standbyWorkerGeneration = nil
                clearSessionToolCapability()
                worker?.cancel()
                worker = nil
                currentTransport = nil
                await transport.close()
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                Self.logStartupFailure(error)
                throw error
            }
        }

        let readiness = AsyncThrowingStream<Void, any Error>.makeStream()
        startContinuation = readiness.continuation
        phase = .starting
        standbyReady = false
        let acceptedGeneration: UInt64

        if worker == nil {
            clearToolConnectionReadiness()
            generation &+= 1
            acceptedGeneration = generation
            worker = Task { [weak self] in
                await self?.runSession(
                    generation: acceptedGeneration,
                    configuration: sessionConfiguration
                )
            }
        } else {
            acceptedGeneration = generation
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

    /// Pre-warms the WebRTC transport in standby mode before conversation starts.
    public func prewarm() async {
        guard
            phase == .idle,
            worker == nil,
            currentTransport == nil,
            standbyWorkerGeneration == nil,
            !localGreetingTeardownInProgress
        else { return }
        generation &+= 1
        let acceptedGeneration = generation
        standbyWorkerGeneration = acceptedGeneration
        worker = Task { [weak self] in
            await self?.runStandby(generation: acceptedGeneration)
        }
    }

    private func runStandby(generation acceptedGeneration: UInt64) async {
        defer {
            if standbyWorkerGeneration == acceptedGeneration {
                standbyWorkerGeneration = nil
                worker = nil
            }
        }

        var hasRetriedAfterPromotion = false
        while acceptedGeneration == generation, !Task.isCancelled {
            if phase == .active {
                refreshActiveMemoryContextForCurrentTime()
            }
            let connectionConfiguration: OpenAIRealtimeConfiguration
            if phase == .active {
                connectionConfiguration = activeSessionConfiguration ?? configuration
            } else {
                connectionConfiguration = configuration
            }
            let purpose: OpenAIRealtimeConnectionPurpose =
                hasRetriedAfterPromotion ? .reconnect : .standby
            let outcome = await runConnection(
                generation: acceptedGeneration,
                configuration: connectionConfiguration,
                purpose: purpose
            )
            guard acceptedGeneration == generation, !Task.isCancelled else { return }

            switch outcome {
            case .stopped:
                return
            case .failedBeforeReady(let error):
                if phase == .starting {
                    finishStandbyFailure(error: error)
                } else {
                    clearStandbyWorker()
                }
                return
            case .unexpectedEnd:
                if phase == .active, !hasRetriedAfterPromotion {
                    hasRetriedAfterPromotion = true
                    continue
                }
                if phase == .starting {
                    finishStandbyFailure(
                        error: OpenAIRealtimeAdapterError.connectionEndedBeforeReady
                    )
                } else if phase == .active {
                    finishTerminalFailure()
                } else {
                    clearStandbyWorker()
                }
                return
            case .retryFailed:
                if phase == .starting {
                    finishStandbyFailure(
                        error: OpenAIRealtimeAdapterError.connectionEndedBeforeReady
                    )
                } else if phase == .active {
                    finishTerminalFailure()
                } else {
                    clearStandbyWorker()
                }
                return
            case .authorizationRequired:
                if phase == .starting {
                    finishStandbyFailure(
                        error: VoiceSessionAuthorizationError.authorizationRequired
                    )
                } else if phase == .active {
                    phase = .idle
                    clearSessionToolCapability()
                    publish(.authorizationRequired)
                    finishSubscribers()
                    finishToolSubscribers()
                    currentTransport = nil
                    worker = nil
                } else {
                    clearStandbyWorker()
                }
                return
            }
        }
    }

    private func finishStandbyFailure(error: any Error) {
        phase = .idle
        standbyReady = false
        standbyWorkerGeneration = nil
        standbyActivationInProgress = false
        pendingActivationEvents.removeAll()
        clearSessionToolCapability()
        currentTransport = nil
        worker = nil
        finishStart(throwing: error)
        finishToolSubscribers()
    }

    private func clearStandbyWorker() {
        phase = .idle
        standbyReady = false
        clearSessionToolCapability()
        currentTransport = nil
        worker = nil
        finishToolSubscribers()
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
            sessionHasTools,
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
        guard !localGreetingTeardownInProgress else { return }
        guard phase != .idle || worker != nil || currentTransport != nil else {
            finishSubscribers()
            finishToolSubscribers()
            standbyActivationInProgress = false
            pendingActivationEvents.removeAll()
            clearSessionToolCapability()
            return
        }

        // A transport close may intentionally overlap the next generation
        // (for example, a standby promotion whose old close is still
        // draining). Only a local greeting requires rejecting a new start:
        // sharing the injected player while its stop is suspended could stop
        // the new greeting or clear its task handle.
        let teardownToken: UInt64?
        if localGreetingTask != nil || conversationClosingTask != nil {
            nextLocalGreetingTeardownToken &+= 1
            let token = nextLocalGreetingTeardownToken
            localGreetingTeardownToken = token
            localGreetingTeardownInProgress = true
            teardownToken = token
        } else {
            teardownToken = nil
        }
        defer {
            if let teardownToken,
               localGreetingTeardownToken == teardownToken
            {
                localGreetingTeardownToken = nil
                localGreetingTeardownInProgress = false
            }
        }

        generation &+= 1
        phase = .idle
        standbyReady = false
        standbyWorkerGeneration = nil
        standbyActivationInProgress = false
        pendingActivationEvents.removeAll()
        clearSessionToolCapability()
        worker?.cancel()
        worker = nil
        finishStart(throwing: CancellationError())
        finishSubscribers()
        finishToolSubscribers()

        await cancelConversationClosing()
        await cancelLocalGreeting()

        let transport = currentTransport
        currentTransport = nil
        readyConnectionToken = nil
        await transport?.close()
    }

    /// Drops the active member-memory instructions and tool capability after a
    /// management clear/disable. The provider receives a fresh session update
    /// without the historical context; no new response is requested here.
    public func invalidateMemberMemoryContext() async {
        activeMemoryContext = nil
        memberMemoryToolEnabledForSession = false
        guard phase == .active,
              let transport = currentTransport,
              let configuration = activeSessionConfigurationWithoutMemory
        else { return }

        activeSessionConfiguration = configuration
        guard let update = try? OpenAIRealtimeWireEncoder.sessionUpdate(
            for: configuration,
            enablesWeeklySummaryTool: weeklySummaryToolEnabledForSession,
            enablesVisitorEnrollmentTools: visitorEnrollmentToolsEnabledForSession,
            enablesMemberMemoryTool: false
        ) else { return }
        try? await transport.send(update)
    }

    /// Refreshes the bounded session-only disclosure in the provider
    /// instructions. The member identity remains local and the tool remains
    /// enabled only for the already-authorized returning-member session.
    public func updateMemberMemoryContext(
        _ context: VoiceMemberMemoryContext
    ) async {
        guard activeVoiceContext == .returningMember else { return }
        let effectiveContext = context.effective(at: now())
        activeMemoryContext = effectiveContext
        let refreshed = configuration(
            for: .returningMember,
            direction: activeConversationDirection,
            memberAddress: activeMemberAddress,
            memoryContext: effectiveContext
        )
        activeSessionConfiguration = refreshed
        activeSessionConfigurationWithoutMemory = configuration(
            for: .returningMember,
            direction: activeConversationDirection,
            memberAddress: activeMemberAddress,
            memoryContext: nil
        )
        guard phase == .active,
              let transport = currentTransport,
              let update = try? OpenAIRealtimeWireEncoder.sessionUpdate(
                  for: refreshed,
                  enablesWeeklySummaryTool: weeklySummaryToolEnabledForSession,
                  enablesVisitorEnrollmentTools:
                      visitorEnrollmentToolsEnabledForSession,
                  enablesMemberMemoryTool: memberMemoryToolEnabledForSession
              )
        else { return }
        try? await transport.send(update)
    }

    private func runSession(
        generation acceptedGeneration: UInt64,
        configuration sessionConfiguration: OpenAIRealtimeConfiguration
    ) async {
        var retryCount = 0

        while acceptedGeneration == generation, !Task.isCancelled {
            if retryCount > 0 {
                refreshActiveMemoryContextForCurrentTime()
            }
            let configurationForConnection = retryCount == 0
                ? sessionConfiguration
                : (activeSessionConfiguration ?? sessionConfiguration)
            let outcome = await runConnection(
                generation: acceptedGeneration,
                configuration: configurationForConnection,
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
                // A provider-generated contextual opener is valid only on the
                // initial connection. If that connection ends before its
                // completion boundary, a reconnect must never turn a later
                // assistant output into a remembered meeting.
                generatedGreetingPending = false
                generatedGreetingOutputIsActive = false
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
            Self.logStartup(.credentialsRequested)
            let secret = try await clientSecretSource.clientSecret(
                for: sessionConfiguration
            )
            guard acceptedGeneration == generation, !Task.isCancelled else {
                return .stopped
            }
            Self.logStartup(.credentialsReady)

            let transport = await transportFactory.makeTransport()
            let events = await transport.eventUpdates()
            guard acceptedGeneration == generation, !Task.isCancelled else {
                await transport.close()
                return .stopped
            }

            currentTransport = transport
            Self.logStartup(.transportConnecting)
            try await transport.connect(
                clientSecret: secret,
                configuration: sessionConfiguration,
                purpose: purpose,
                enablesWeeklySummaryTool: weeklySummaryToolEnabledForSession,
                enablesVisitorEnrollmentTools: visitorEnrollmentToolsEnabledForSession,
                enablesMemberMemoryTool: memberMemoryToolEnabledForSession
            )
            guard acceptedGeneration == generation, !Task.isCancelled else {
                await transport.close()
                return .stopped
            }
            Self.logStartup(.transportConnected)

            // One-off Realtime cost-telemetry milestone: consumed on a
            // separate child task from a separate transport stream so it can
            // never affect the provider-event loop below or this
            // connection's own generation/cancellation semantics. It is
            // cancelled on every exit from this scope, including retries.
            let usageTask: Task<Void, Never>? = usageReporter.map { reporter in
                Task { [weak self] in
                    let usageStream = await transport.usageUpdates()
                    for await usage in usageStream {
                        guard let self else { return }
                        await self.reportUsage(usage, using: reporter)
                    }
                }
            }
            defer { usageTask?.cancel() }

            let mapper = OpenAIRealtimeEventMapper()
            var connectionReady = false
            for await providerEvent in events {
                guard acceptedGeneration == generation, !Task.isCancelled else {
                    return .stopped
                }

                // A long-running connection can cross the store-day boundary
                // without reconnecting. Refresh the locally bounded context
                // before handling the next provider event so a later member
                // turn cannot use yesterday's `completedToday` instruction.
                // The update changes instructions only and never requests a
                // response on its own.
                if connectionReady,
                   readyConnectionToken == acceptedConnectionToken,
                   refreshActiveMemoryContextForCurrentTime(),
                   let refreshed = activeSessionConfiguration,
                   let update = try? OpenAIRealtimeWireEncoder.sessionUpdate(
                       for: refreshed,
                       enablesWeeklySummaryTool:
                           weeklySummaryToolEnabledForSession,
                       enablesVisitorEnrollmentTools:
                           visitorEnrollmentToolsEnabledForSession,
                       enablesMemberMemoryTool:
                           memberMemoryToolEnabledForSession
                   )
                {
                    try? await transport.send(update)
                }
                processedProviderEventCount &+= 1

                // An accepted goodbye is terminal for this generation. Ignore
                // late provider speech/errors/tools while local farewell drains.
                if conversationClosingGeneration == acceptedGeneration { continue }

                if case .inputAudioSpeechStarted = providerEvent {
                    // OpenAIWebRTCTransport emits this provider event only
                    // after its local barge-in policy accepts the visitor turn.
                    // This prevents an opening/rejected echo from arming the
                    // contextual closing capability.
                    acceptedUserTurnForConversationClosing = true
                }

                if case .toolCall(let call) = providerEvent {
                    if call.kind == .endConversation {
                        guard conversationClosingToolEnabledForSession,
                              acceptedUserTurnForConversationClosing,
                              readyConnectionToken == acceptedConnectionToken,
                              phase == .active
                        else {
                            continue
                        }
                        beginConversationClosing(generation: acceptedGeneration)
                        continue
                    }

                    if sessionHasTools,
                       readyConnectionToken == acceptedConnectionToken,
                       phase == .active
                    {
                        publishToolCall(call)
                    }
                }

                for mappedEvent in await mapper.map(providerEvent) {
                    switch mappedEvent {
                    case .ready:
                        Self.logStartup(.providerReady)
                        connectionReady = true
                        readyConnectionToken = acceptedConnectionToken
                        if phase == .starting {
                            if purpose == .standby, !standbyActivationInProgress {
                                standbyActivationInProgress = true
                                let configToApply = activeSessionConfiguration ?? sessionConfiguration
                                do {
                                    Self.logStartup(.activationRequested)
                                    try await transport.activate(
                                        configuration: configToApply,
                                        enablesWeeklySummaryTool: weeklySummaryToolEnabledForSession,
                                        enablesVisitorEnrollmentTools: visitorEnrollmentToolsEnabledForSession,
                                        enablesMemberMemoryTool: memberMemoryToolEnabledForSession
                                    )
                                    try Task.checkCancellation()
                                    guard acceptedGeneration == generation else {
                                        await transport.close()
                                        return .stopped
                                    }
                                    Self.logStartup(.activationReady)
                                } catch {
                                    guard acceptedGeneration == generation,
                                          !Task.isCancelled
                                    else {
                                        await transport.close()
                                        return .stopped
                                    }
                                    await transport.close()
                                    guard acceptedGeneration == generation,
                                          !Task.isCancelled
                                    else {
                                        return .stopped
                                    }
                                    standbyActivationInProgress = false
                                    clearToolConnectionReadiness()
                                    currentTransport = nil
                                    Self.logStartupFailure(error)
                                    finishStart(throwing: error)
                                    return .failedBeforeReady(error)
                                }
                                standbyActivationInProgress = false
                            }
                            if !standbyActivationInProgress {
                                phase = .active
                                flushPendingActivationEvents()
                                finishStartSuccessfully()
                                startLocalGreetingIfNeeded(generation: acceptedGeneration)
                            }
                        } else if phase == .idle {
                            standbyReady = true
                        }
                    case .voice(let event):
                        guard connectionReady else {
                            if event == .failure {
                                await transport.close()
                                guard acceptedGeneration == generation,
                                      !Task.isCancelled
                                else {
                                    return .stopped
                                }
                                clearToolConnectionReadiness()
                                currentTransport = nil
                                if wasStarting {
                                    Self.logStartupFailure(
                                        OpenAIRealtimeAdapterError.connectionEndedBeforeReady
                                    )
                                    return .failedBeforeReady(
                                        OpenAIRealtimeAdapterError.connectionEndedBeforeReady
                                    )
                                }
                                return .retryFailed
                            }
                            continue
                        }
                        if phase == .active {
                            publishVoiceEvent(event)
                        } else if phase == .starting {
                            pendingActivationEvents.append(event)
                        }
                    }
                }
            }

            guard acceptedGeneration == generation, !Task.isCancelled else {
                return .stopped
            }
            if conversationClosingGeneration == acceptedGeneration {
                await cancelConversationClosing()
                await transport.close()
                requestConversationEnd(generation: acceptedGeneration)
                return .stopped
            }
            await cancelConversationClosing()
            await cancelLocalGreeting()
            await transport.close()
            guard acceptedGeneration == generation, !Task.isCancelled else {
                return .stopped
            }
            clearToolConnectionReadiness()
            currentTransport = nil
            return .unexpectedEnd
        } catch {
            guard acceptedGeneration == generation, !Task.isCancelled else {
                return .stopped
            }
            Self.logStartupFailure(error)
            if conversationClosingGeneration == acceptedGeneration {
                await cancelConversationClosing()
                await currentTransport?.close()
                requestConversationEnd(generation: acceptedGeneration)
                return .stopped
            }
            await cancelConversationClosing()
            await cancelLocalGreeting()
            let transport = currentTransport
            await transport?.close()
            guard acceptedGeneration == generation, !Task.isCancelled else {
                return .stopped
            }
            currentTransport = nil
            clearToolConnectionReadiness()
            if wasStarting || phase == .starting {
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
        standbyReady = false
        standbyActivationInProgress = false
        pendingActivationEvents.removeAll()
        clearSessionToolCapability()
        worker?.cancel()
        worker = nil
        finishStart(throwing: CancellationError())
        finishToolSubscribers()

        let transport = currentTransport
        currentTransport = nil
        readyConnectionToken = nil
        await transport?.close()
    }

    /// Assigns the next turn number and fires the usage report without
    /// awaiting it. The reporter itself must never throw, retry, or block;
    /// this actor only ever spends synchronous time here.
    private func reportUsage(
        _ usage: OpenAIRealtimeResponseUsage,
        using reporter: any OpenAIRealtimeUsageReporting
    ) {
        nextUsageReportTurn &+= 1
        let turn = nextUsageReportTurn
        Task {
            await reporter.report(usage, turn: turn)
        }
    }

    private func clearToolConnectionReadiness() {
        readyConnectionToken = nil
    }

    private func clearSessionToolCapability() {
        weeklySummaryToolEnabledForSession = false
        visitorEnrollmentToolsEnabledForSession = false
        memberMemoryToolEnabledForSession = false
        conversationClosingToolEnabledForSession = false
        acceptedUserTurnForConversationClosing = false
        conversationClosingGeneration = nil
        conversationEndRequestSent = false
        generatedGreetingPending = false
        generatedGreetingOutputIsActive = false
        clearToolConnectionReadiness()
        activeVoiceContext = nil
        activeMemberAddress = nil
        activeConversationDirection = .general
        activeMemoryContext = nil
        activeSessionConfiguration = nil
        activeSessionConfigurationWithoutMemory = nil
    }

    private func flushPendingActivationEvents() {
        let events = pendingActivationEvents
        pendingActivationEvents.removeAll()
        for event in events {
            publishVoiceEvent(event)
        }
    }

    private var sessionHasTools: Bool {
        weeklySummaryToolEnabledForSession
            || visitorEnrollmentToolsEnabledForSession
            || memberMemoryToolEnabledForSession
            || conversationClosingToolEnabledForSession
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
        if event == .assistantOutputStarted {
            Self.logStartup(.outputStarted)
        }
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

    /// Publishes provider output lifecycle events and marks the one
    /// provider-generated memory opener only after a complete output boundary.
    /// Ordinary assistant responses never emit `greetingCompleted`.
    private func publishVoiceEvent(_ event: VoiceSessionEvent) {
        switch event {
        case .assistantOutputStarted:
            if generatedGreetingPending {
                generatedGreetingOutputIsActive = true
            }
            publish(event)

        case .assistantOutputEnded:
            let completedGeneratedGreeting = generatedGreetingPending
                && generatedGreetingOutputIsActive
            generatedGreetingOutputIsActive = false
            publish(event)
            if completedGeneratedGreeting {
                generatedGreetingPending = false
                publish(.greetingCompleted)
            }

        case .assistantOutputCleared:
            generatedGreetingPending = false
            generatedGreetingOutputIsActive = false
            publish(event)

        case .assistantInterrupted, .userSpeechStarted:
            // Barge-in or an accepted user turn means the generated opener did
            // not complete, even if a stale output-ended callback follows.
            generatedGreetingPending = false
            generatedGreetingOutputIsActive = false
            publish(event)

        case .failure:
            generatedGreetingPending = false
            generatedGreetingOutputIsActive = false
            publish(event)

        default:
            publish(event)
        }
    }

    private func finishTerminalFailure() {
        phase = .idle
        standbyActivationInProgress = false
        pendingActivationEvents.removeAll()
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

    /// Starts one local opening after Realtime readiness. The task is separate
    /// from `start` so the voice port can return as soon as the provider is
    /// ready and the coordinator can observe output lifecycle events while the
    /// WAV is still playing.
    private func startLocalGreetingIfNeeded(generation acceptedGeneration: UInt64) {
        guard localGreetingTask == nil,
              let recordedGreeting,
              let context = activeVoiceContext,
              let sessionConfiguration = activeSessionConfiguration,
              sessionConfiguration.usesExternalGreeting,
              !(activeMemoryContext?.hasPersonalizedOpening ?? false),
              phase == .active,
              acceptedGeneration == generation else {
            return
        }

        localGreetingGeneration = acceptedGeneration
        localGreetingTask = Task { [weak self, recordedGreeting] in
            await self?.runLocalGreeting(
                generation: acceptedGeneration,
                context: context,
                player: recordedGreeting
            )
        }
    }

    /// Handles the provider's contextual closing request entirely inside
    /// Infrastructure. The Application receives only the payload-free
    /// lifecycle event after the one local farewell has finished.
    private func beginConversationClosing(generation acceptedGeneration: UInt64) {
        guard conversationClosingTask == nil,
              conversationClosingGeneration == nil,
              conversationClosingToolEnabledForSession,
              acceptedUserTurnForConversationClosing,
              phase == .active,
              acceptedGeneration == generation,
              recordedGreeting != nil
        else { return }

        conversationClosingGeneration = acceptedGeneration
        conversationClosingTask = Task { [weak self] in
            await self?.runConversationClosing(generation: acceptedGeneration)
        }
    }

    private func runConversationClosing(generation acceptedGeneration: UInt64) async {
        defer {
            if conversationClosingGeneration == acceptedGeneration {
                conversationClosingTask = nil
            }
        }

        guard acceptedGeneration == generation,
              phase == .active,
              !Task.isCancelled,
              let player = recordedGreeting
        else { return }

        let transport = currentTransport
        if let transport {
            do {
                try await transport.setConversationMediaEnabled(false)
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                // Without a confirmed media gate the recording could feed
                // the microphone. Skip it and end instead of risking echo.
                requestConversationEnd(generation: acceptedGeneration)
                return
            }

            for data in [
                try? OpenAIRealtimeWireEncoder.responseCancel(),
                try? OpenAIRealtimeWireEncoder.outputAudioBufferClear(),
            ].compactMap({ $0 }) {
                do {
                    try await transport.send(data)
                    try Task.checkCancellation()
                } catch is CancellationError {
                    return
                } catch {
                    // Closing remains local and deterministic even if the
                    // provider has already completed the response.
                }
            }
        }

        guard acceptedGeneration == generation,
              phase == .active,
              !Task.isCancelled
        else { return }

        publish(.responseReady)
        publish(.assistantOutputStarted)
        do {
            try await player.playGoodbye()
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            // Playback failure must still close the conversation; the local
            // clip is an enhancement, never a reason to leave Realtime open.
        }

        guard acceptedGeneration == generation,
              phase == .active,
              !Task.isCancelled
        else { return }

        publish(.assistantOutputEnded)
        requestConversationEnd(generation: acceptedGeneration)
    }

    private func requestConversationEnd(generation acceptedGeneration: UInt64) {
        guard acceptedGeneration == generation, phase == .active,
              !Task.isCancelled, !conversationEndRequestSent else { return }
        conversationEndRequestSent = true
        publish(.conversationEndRequested)
    }

    private var localGreetingGeneration: UInt64? = nil

    private func runLocalGreeting(
        generation acceptedGeneration: UInt64,
        context: VoiceContext,
        player: any RecordedGreetingPlayer
    ) async {
        var outputStarted = false
        var outputEnded = false

        defer {
            if localGreetingGeneration == acceptedGeneration {
                localGreetingGeneration = nil
                localGreetingTask = nil
            }
        }

        guard acceptedGeneration == generation,
              phase == .active,
              !Task.isCancelled else {
            return
        }

        publish(.assistantOutputStarted)
        outputStarted = true
        do {
            try Task.checkCancellation()
            try await player.play(context: context)
            try Task.checkCancellation()
        } catch is CancellationError {
            if outputStarted,
               !outputEnded,
               acceptedGeneration == generation,
               phase == .active
            {
                publish(.assistantOutputEnded)
            }
            return
        } catch {
            guard acceptedGeneration == generation, !Task.isCancelled else {
                return
            }
            if outputStarted, !outputEnded {
                publish(.assistantOutputEnded)
                outputEnded = true
            }
            publish(.failure)
            return
        }

        guard acceptedGeneration == generation,
              phase == .active,
              !Task.isCancelled else {
            return
        }

        publish(.assistantOutputEnded)
        outputEnded = true

        guard let transport = currentTransport,
              readyConnectionToken != nil else {
            publish(.failure)
            return
        }

        do {
            try await transport.setConversationMediaEnabled(true)
            guard acceptedGeneration == generation,
                  phase == .active,
                  !Task.isCancelled else { return }
            publish(.greetingCompleted)
        } catch is CancellationError {
            return
        } catch {
            guard acceptedGeneration == generation, !Task.isCancelled else {
                return
            }
            publish(.failure)
        }
    }

    /// Stops an in-flight local opening before a transport is closed. This
    /// ordering prevents the old WAV from racing a reconnect and being picked
    /// up as microphone input by the new connection.
    private func cancelLocalGreeting() async {
        guard let task = localGreetingTask,
              let acceptedGreetingGeneration = localGreetingGeneration
        else { return }
        task.cancel()
        await recordedGreeting?.stop()
        await task.value
        if localGreetingGeneration == acceptedGreetingGeneration {
            localGreetingTask = nil
            localGreetingGeneration = nil
        }
    }

    private func cancelConversationClosing() async {
        guard let task = conversationClosingTask else { return }
        task.cancel()
        await recordedGreeting?.stop()
        await task.value
        conversationClosingTask = nil
    }

    @discardableResult
    private func refreshActiveMemoryContextForCurrentTime() -> Bool {
        guard let activeMemoryContext else { return false }
        let effectiveContext = activeMemoryContext.effective(at: now())
        guard effectiveContext != activeMemoryContext else { return false }

        self.activeMemoryContext = effectiveContext
        guard let activeVoiceContext else { return false }
        activeSessionConfiguration = configuration(
            for: activeVoiceContext,
            direction: activeConversationDirection,
            memberAddress: activeMemberAddress,
            memoryContext: effectiveContext
        )
        activeSessionConfigurationWithoutMemory = configuration(
            for: activeVoiceContext,
            direction: activeConversationDirection,
            memberAddress: activeMemberAddress,
            memoryContext: nil
        )
        return true
    }

    private func configuration(
        for context: VoiceContext,
        direction: VoiceConversationDirection,
        memberAddress: VoiceMemberAddress?,
        memoryContext: VoiceMemberMemoryContext?
    ) -> OpenAIRealtimeConfiguration {
        let greetingInstruction: String
        switch context {
        case .returningMember:
            if let memberAddress {
                greetingInstruction = OpenAIConversationPrompts.returningMember(
                    address: memberAddress,
                    memoryContext: memoryContext,
                    includesWeeklySummaryTool: weeklySummaryToolEnabledForSession
                )
            } else {
                greetingInstruction = OpenAIConversationPrompts
                    .anonymousReturningMemberPrompt(
                        memoryContext: memoryContext,
                        includesWeeklySummaryTool: weeklySummaryToolEnabledForSession
                    )
            }
        case .visitor:
            if visitorEnrollmentToolsEnabledForSession {
                greetingInstruction =
                    OpenAIConversationPrompts.enrollmentCapableVisitor
            } else {
                greetingInstruction = OpenAIConversationPrompts.anonymousVisitor
            }
        }

        var instructions = configuration.instructions + "\n" + greetingInstruction
        switch direction {
        case .general:
            break
        case .preWorkoutReminder:
            instructions += "\n" + OpenAIConversationPrompts.preWorkoutReminder
        case .postWorkoutReview:
            instructions += "\n" + OpenAIConversationPrompts.postWorkoutReview
        }
        let usesPersonalizedGreeting =
            context == .returningMember && memoryContext?.hasPersonalizedOpening == true
        if !usesPersonalizedGreeting,
           (configuration.usesExternalGreeting || recordedGreeting != nil)
        {
            instructions += "\n" + OpenAIConversationPrompts.externalGreetingAlreadyPlayed
        }
        if configuration.allowsConversationClosing, recordedGreeting != nil {
            instructions += "\n" + OpenAIConversationPrompts.naturalConversationClosing
        }

        return OpenAIRealtimeConfiguration(
            model: configuration.model,
            voice: configuration.voice,
            instructions: instructions,
            maxResponseOutputTokens: configuration.maxResponseOutputTokens,
            usesExternalGreeting: usesPersonalizedGreeting
                ? false
                : configuration.usesExternalGreeting || recordedGreeting != nil,
            allowsConversationClosing: configuration.allowsConversationClosing
                && recordedGreeting != nil
        )
    }
}
