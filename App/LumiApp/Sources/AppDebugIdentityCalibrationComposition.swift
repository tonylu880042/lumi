#if DEBUG

import Foundation
import LumiApplication
import LumiDomain
import LumiInfrastructure
import LumiPresentation

/// Lazy Application-port boundary for the DEBUG identity calibration tool.
///
/// The App owns composition, but the port still owns camera, Vision, Core ML,
/// and SQLite details. Camera start, member-count selection, and photo import
/// lazily load the graph; none of the latter operations starts the camera.
actor AppIdentityCalibrationPortProxy: IdentityCalibrationPort {
    typealias Loader = @Sendable () async throws -> any IdentityCalibrationPort

    private let loader: Loader
    private var cachedPort: (any IdentityCalibrationPort)?
    private var loadingTask: Task<any IdentityCalibrationPort, Error>?

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func startCamera() async throws {
        let port = try await loadPort()
        try await port.startCamera()
    }

    func stopCamera() async {
        guard let cachedPort else { return }
        await cachedPort.stopCamera()
    }

    /// Preview access never widens the lazy-load boundary. The camera start
    /// operation must have populated the cached port before a preview can be
    /// observed; a pre-start request therefore returns an immediately finished
    /// stream.
    func previewFrames() async -> AsyncStream<IdentityCalibrationPreviewFrame> {
        guard let cachedPort else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return await cachedPort.previewFrames()
    }

    func captureEnrollmentSample(
        for temporaryMemberID: MemberID,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        guard let cachedPort else { throw IdentityCalibrationError.failed }
        return try await cachedPort.captureEnrollmentSample(
            for: temporaryMemberID,
            at: createdAt
        )
    }

    func captureReturnVisit() async throws -> IdentityCalibrationReturnResult {
        guard let cachedPort else { throw IdentityCalibrationError.failed }
        return try await cachedPort.captureReturnVisit()
    }

    func captureEnrollmentPhoto(
        for temporaryMemberID: MemberID,
        from imageURL: URL,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        let port = try await loadPort()
        return try await port.captureEnrollmentPhoto(
            for: temporaryMemberID,
            from: imageURL,
            at: createdAt
        )
    }

    func captureEnrollmentPhoto(
        for temporaryMemberID: MemberID,
        from photo: IdentityCalibrationPhoto,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        let port = try await loadPort()
        return try await port.captureEnrollmentPhoto(
            for: temporaryMemberID,
            from: photo,
            at: createdAt
        )
    }

    func captureReturnVisitPhoto(
        from imageURL: URL
    ) async throws -> IdentityCalibrationReturnResult {
        let port = try await loadPort()
        return try await port.captureReturnVisitPhoto(from: imageURL)
    }

    func captureReturnVisitPhoto(
        from photo: IdentityCalibrationPhoto
    ) async throws -> IdentityCalibrationReturnResult {
        let port = try await loadPort()
        return try await port.captureReturnVisitPhoto(from: photo)
    }

    func sampleCount(for temporaryMemberID: MemberID) async throws -> Int {
        let port = try await loadPort()
        return try await port.sampleCount(for: temporaryMemberID)
    }

    func reset(for temporaryMemberID: MemberID) async throws {
        guard let cachedPort else { throw IdentityCalibrationError.failed }
        try await cachedPort.reset(for: temporaryMemberID)
    }

    private func loadPort() async throws -> any IdentityCalibrationPort {
        if let cachedPort { return cachedPort }
        if let loadingTask { return try await loadingTask.value }

        let task = Task<any IdentityCalibrationPort, Error> {
            try await loader()
        }
        loadingTask = task

        do {
            let port = try await task.value
            loadingTask = nil
            cachedPort = port
            return port
        } catch {
            loadingTask = nil
            throw error
        }
    }
}

/// Lazy DEBUG bridge for the session Simulator's 44B recognition action.
///
/// App composition owns resource/database discovery. The cached value remains
/// the narrow Application port, so camera, Vision, Core ML, and SQLite values
/// never reach the UI model.
actor AppPilotIdentityRecognitionPortProxy: IdentityRecognitionPort {
    typealias Loader = @Sendable () async throws -> any IdentityRecognitionPort

    private let loader: Loader
    private var cachedPort: (any IdentityRecognitionPort)?
    private var loadingTask: Task<any IdentityRecognitionPort, Error>?

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func recognizeCurrentVisitor() async throws -> RecognitionResult {
        do {
            try Task.checkCancellation()
            let port = try await loadPort()
            try Task.checkCancellation()
            let result = try await port.recognizeCurrentVisitor()
            try Task.checkCancellation()
            return result
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw PilotIdentityRecognitionError.failed
        }
    }

    private func loadPort() async throws -> any IdentityRecognitionPort {
        if let cachedPort { return cachedPort }
        if let loadingTask { return try await loadingTask.value }

        let task = Task<any IdentityRecognitionPort, Error> {
            try await loader()
        }
        loadingTask = task

        do {
            let port = try await task.value
            loadingTask = nil
            cachedPort = port
            return port
        } catch {
            loadingTask = nil
            throw error
        }
    }
}

/// Lazy DEBUG-Live bridge for the continuous visitor-presence loop.
/// Loading begins only when the ready Avatar asks for its first visitor.
actor AppVisitorPresenceMonitoringPortProxy: VisitorPresenceMonitoringPort {
    typealias Loader = @Sendable () async throws -> any VisitorPresenceMonitoringPort

    private let loader: Loader
    private var cachedPort: (any VisitorPresenceMonitoringPort)?
    private var loadingTask: Task<any VisitorPresenceMonitoringPort, Error>?

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func waitForVisitor() async throws {
        try await loadPort().waitForVisitor()
    }

    func waitForDeparture() async throws {
        try await loadPort().waitForDeparture()
    }

    func stop() async {
        guard let cachedPort else { return }
        await cachedPort.stop()
    }

    private func loadPort() async throws -> any VisitorPresenceMonitoringPort {
        if let cachedPort { return cachedPort }
        if let loadingTask { return try await loadingTask.value }

        let task = Task<any VisitorPresenceMonitoringPort, Error> {
            try await loader()
        }
        loadingTask = task
        do {
            let port = try await task.value
            loadingTask = nil
            cachedPort = port
            return port
        } catch {
            loadingTask = nil
            throw error
        }
    }
}

/// One lazy Debug-Live bridge shared by conversational enrollment and the
/// subsequent local spoken-name lookup.
actor AppVisitorEnrollmentPortProxy:
    VisitorEnrollmentPort,
    VoiceMemberAddressRepository
{
    typealias Service = any VisitorEnrollmentPort & VoiceMemberAddressRepository
    typealias Loader = @Sendable () async throws -> Service

    private let loader: Loader
    private var cachedService: Service?
    private var loadingTask: Task<Service, Error>?

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func begin(consentedAt: Date) async throws -> VisitorEnrollmentBeginResult {
        try await loadService().begin(consentedAt: consentedAt)
    }

    func complete(
        memberID: MemberID,
        address: VoiceMemberAddress,
        completedAt: Date
    ) async throws {
        try await loadService().complete(
            memberID: memberID,
            address: address,
            completedAt: completedAt
        )
    }

    func cancel() async {
        guard let cachedService else { return }
        await cachedService.cancel()
    }

    func address(for memberID: MemberID) async throws -> VoiceMemberAddress? {
        try await loadService().address(for: memberID)
    }

    private func loadService() async throws -> Service {
        if let cachedService { return cachedService }
        if let loadingTask { return try await loadingTask.value }

        let task = Task<Service, Error> { try await loader() }
        loadingTask = task
        do {
            let service = try await task.value
            loadingTask = nil
            cachedService = service
            return service
        } catch {
            loadingTask = nil
            throw error
        }
    }
}

/// Ensures recognition, enrollment, and address lookup use one in-memory
/// camera/model service while still sharing the same durable SQLite file with
/// the calibration tool.
actor AppCoreMLIdentityServiceLoader {
    typealias Loader = @Sendable () async throws -> CoreMLIdentityCalibrationService

    private let loader: Loader
    private var cachedService: CoreMLIdentityCalibrationService?
    private var loadingTask: Task<CoreMLIdentityCalibrationService, Error>?

    init(loader: @escaping Loader = {
        try await AppIdentityCalibrationComposition.loadProductionService()
    }) {
        self.loader = loader
    }

    func load() async throws -> CoreMLIdentityCalibrationService {
        if let cachedService { return cachedService }
        if let loadingTask { return try await loadingTask.value }

        let task = Task<CoreMLIdentityCalibrationService, Error> {
            try await loader()
        }
        loadingTask = task
        do {
            let service = try await task.value
            loadingTask = nil
            cachedService = service
            return service
        } catch {
            loadingTask = nil
            throw error
        }
    }
}

extension AppCoreMLIdentityServiceLoader: IdentityEnrollmentSummaryPort {
    func enrolledMemberCount() async throws -> Int {
        try await load().enrolledMemberCount()
    }
}

/// App-only composition for the DEBUG calibration graph.
enum AppIdentityCalibrationComposition {
    static let databaseDirectoryName = "Lumi"
    static let databaseFileName = "IdentityCalibration.sqlite"

    @MainActor
    static func makeModel(
        loader: @escaping AppIdentityCalibrationPortProxy.Loader
    ) -> DebugIdentityCalibrationModel {
        DebugIdentityCalibrationModel(
            port: AppIdentityCalibrationPortProxy(loader: loader)
        )
    }

    /// Production composition is shared by Mock Debug and Debug-Live.  The
    /// loader remains lazy so App launch never loads a model or opens SQLite.
    @MainActor
    static func makeModel() -> DebugIdentityCalibrationModel {
        makeModel(loader: productionLoader)
    }

    /// Pure path derivation used by the loader and by App tests.  It does not
    /// create directories or touch the filesystem.
    static func databaseURL(applicationSupportURL: URL) -> URL {
        applicationSupportURL
            .appendingPathComponent(databaseDirectoryName, isDirectory: true)
            .appendingPathComponent(databaseFileName, isDirectory: false)
    }

    /// Prepares the exact local directory chain needed by the calibration DB.
    ///
    /// The fresh iOS container may not contain Application Support yet, so
    /// each missing directory is created explicitly without asking Foundation
    /// to create unrelated intermediate paths.
    static func prepareDatabaseURL(
        applicationSupportURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        if !fileManager.fileExists(atPath: applicationSupportURL.path) {
            try fileManager.createDirectory(
                at: applicationSupportURL,
                withIntermediateDirectories: false
            )
        }

        let derivedDatabaseURL = databaseURL(
            applicationSupportURL: applicationSupportURL
        )
        let databaseDirectoryURL = derivedDatabaseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: databaseDirectoryURL.path) {
            try fileManager.createDirectory(
                at: databaseDirectoryURL,
                withIntermediateDirectories: false
            )
        }

        return derivedDatabaseURL
    }

    /// Builds the single concrete DEBUG identity graph used by either the
    /// calibration tool or the 44B session pilot. Callers keep this lazy.
    static func loadProductionService() async throws
        -> CoreMLIdentityCalibrationService
    {
        try Task.checkCancellation()

        // Resolve every bundled resource before creating a database directory.
        // Missing models therefore leave no partial calibration store behind.
        let resources = try AppIdentityModelResources.resolve(using: Bundle.main)
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw IdentityCalibrationError.failed
        }
        let derivedDatabaseURL = try prepareDatabaseURL(
            applicationSupportURL: applicationSupportURL,
            fileManager: .default
        )

        return try await CoreMLIdentityCalibrationFactory.load(
            sFaceModelURL: resources.sFaceModelURL,
            yuNetModelURL: resources.yuNetModelURL,
            databaseURL: derivedDatabaseURL
        )
    }

    private static let productionLoader:
        AppIdentityCalibrationPortProxy.Loader = {
            try await loadProductionService()
        }
}

/// DEBUG-only session composition for the owner-approved 44B pilot.
enum AppPilotIdentityRecognitionComposition {
    /// Owner-approved DEBUG-Live bridge: a safe enrollment identifier may be
    /// spoken as a temporary address until the member system supplies a name.
    /// Invalid/free-form identifiers remain anonymous.
    static func voiceMemberAddress(
        for memberID: MemberID
    ) -> VoiceMemberAddress? {
        try? VoiceMemberAddress(spokenLabel: memberID.rawValue)
    }

    static func makePort(
        loader: @escaping AppPilotIdentityRecognitionPortProxy.Loader
    ) -> any IdentityRecognitionPort {
        AppPilotIdentityRecognitionPortProxy(loader: loader)
    }

    static func makePort() -> any IdentityRecognitionPort {
        makePort {
            let service = try await AppIdentityCalibrationComposition
                .loadProductionService()
            return PilotIdentityRecognitionAdapter(source: service)
        }
    }
}

#endif
