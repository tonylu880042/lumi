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

    private static let productionLoader:
        AppIdentityCalibrationPortProxy.Loader = {
            try Task.checkCancellation()

            // Resolve every bundled resource before creating a database
            // directory. Missing model resources therefore leave no partial
            // calibration store behind.
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
}

#endif
