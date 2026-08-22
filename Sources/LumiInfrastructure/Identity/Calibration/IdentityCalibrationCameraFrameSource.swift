#if DEBUG

import Foundation
import LumiApplication

/// Owns one CameraCaptureAdapter stream and turns each explicit capture into
/// a one-shot next-frame gate. The bounded stream element present when the
/// gate is armed is discarded; the following frame is the captured frame.
actor IdentityCalibrationCameraFrameSource: IdentityCalibrationFrameSource {
    private let adapter: any IdentityCalibrationCameraAdapter
    private var cursor: IdentityCalibrationStreamCursor?
    private var freshFrameSignal = AsyncStream<Void>.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(4)
    )
    private var previewStream: AsyncStream<CameraFrame>?
    private var previewContinuation: AsyncStream<CameraFrame>.Continuation?
    private var previewDeliverySignal = AsyncStream<Void>.makeStream(
        of: Void.self,
        bufferingPolicy: .bufferingNewest(16)
    )
    private var running = false

    init(adapter: any IdentityCalibrationCameraAdapter) {
        self.adapter = adapter
    }

    func start() async throws {
        guard !running else { throw IdentityCalibrationError.failed }
        let stream = try await adapter.start()
        previewDeliverySignal = AsyncStream<Void>.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        let preview = AsyncStream<CameraFrame>.makeStream(
            of: CameraFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let newCursor = IdentityCalibrationStreamCursor(
            stream: stream,
            previewContinuation: preview.continuation,
            previewDeliverySignal: previewDeliverySignal.continuation
        )
        previewStream = preview.stream
        previewContinuation = preview.continuation
        await newCursor.start()
        cursor = newCursor
        running = true
    }

    func stop() async {
        running = false
        if let cursor {
            await cursor.stop()
        }
        self.cursor = nil
        previewContinuation?.finish()
        previewContinuation = nil
        previewStream = nil
        previewDeliverySignal.continuation.finish()
        await adapter.stop()
    }

    /// Returns the current generation's bounded preview stream. Before start,
    /// and after stop, this is an immediately finished stream.
    func previewFrames() async -> AsyncStream<CameraFrame> {
        guard let previewStream else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return previewStream
    }

    /// Deterministic DEBUG test handshake for a frame reaching the preview
    /// continuation. It is not part of the Application port.
    func waitForPreviewDelivery() async {
        var iterator = previewDeliverySignal.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func nextFrame() async throws -> CameraFrame {
        try Task.checkCancellation()
        guard running, let cursor else {
            throw IdentityCalibrationError.failed
        }

        return try await withTaskCancellationHandler(operation: {
            // CameraCaptureAdapter guarantees a newest-one bounded stream.
            // Drain that one element before waiting for the following frame,
            // so a frame delivered before this button press cannot satisfy it.
            guard await cursor.discardOne() else {
                self.cursor = nil
                if !self.running || Task.isCancelled {
                    throw CancellationError()
                }
                throw IdentityCalibrationError.failed
            }
            try Task.checkCancellation()

            freshFrameSignal.continuation.yield(())
            guard let frame = await cursor.next() else {
                self.cursor = nil
                if !self.running || Task.isCancelled {
                    throw CancellationError()
                }
                throw IdentityCalibrationError.failed
            }
            return frame
        }, onCancel: {
            Task { [weak self] in
                await self?.cancelPendingCapture()
            }
        })
    }

    /// Internal deterministic test handshake: emitted after the pre-arm
    /// bounded element is discarded and before the fresh frame is awaited.
    func waitForFreshFrameRequest() async {
        var iterator = freshFrameSignal.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    private func cancelPendingCapture() async {
        running = false
        if let cursor {
            await cursor.stop()
        }
        self.cursor = nil
        await adapter.stop()
    }
}

private actor IdentityCalibrationStreamCursor {
    private let stream: AsyncStream<CameraFrame>
    private let previewContinuation: AsyncStream<CameraFrame>.Continuation
    private let previewDeliverySignal: AsyncStream<Void>.Continuation
    private var queue: [CameraFrame] = []
    private var pending: CheckedContinuation<CameraFrame?, Never>?
    private var ended = false
    private var worker: Task<Void, Never>?

    init(
        stream: AsyncStream<CameraFrame>,
        previewContinuation: AsyncStream<CameraFrame>.Continuation,
        previewDeliverySignal: AsyncStream<Void>.Continuation
    ) {
        self.stream = stream
        self.previewContinuation = previewContinuation
        self.previewDeliverySignal = previewDeliverySignal
    }

    func start() {
        guard worker == nil else { return }
        let stream = self.stream
        worker = Task { [weak self] in
            var iterator = stream.makeAsyncIterator()
            while let frame = await iterator.next() {
                await self?.receive(frame)
            }
            await self?.finish()
        }
    }

    func discardOne() async -> Bool {
        await takeNext() != nil
    }

    func next() async -> CameraFrame? {
        await takeNext()
    }

    func stop() {
        ended = true
        worker?.cancel()
        worker = nil
        queue.removeAll(keepingCapacity: false)
        previewContinuation.finish()
        pending?.resume(returning: nil)
        pending = nil
    }

    private func takeNext() async -> CameraFrame? {
        if !queue.isEmpty {
            return queue.removeFirst()
        }
        guard !ended else { return nil }
        return await withCheckedContinuation { continuation in
            if ended {
                continuation.resume(returning: nil)
            } else {
                pending = continuation
            }
        }
    }

    private func receive(_ frame: CameraFrame) {
        guard !ended else { return }
        _ = previewContinuation.yield(frame)
        previewDeliverySignal.yield(())
        if let pending {
            self.pending = nil
            pending.resume(returning: frame)
        } else {
            // Match the production stream's bufferingNewest(1) contract.
            queue = [frame]
        }
    }

    private func finish() {
        ended = true
        previewContinuation.finish()
        pending?.resume(returning: nil)
        pending = nil
    }
}

#endif
