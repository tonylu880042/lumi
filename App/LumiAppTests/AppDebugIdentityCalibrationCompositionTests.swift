#if DEBUG

import Foundation
import LumiApplication
import LumiDomain
import LumiPresentation
import Testing
import UniformTypeIdentifiers
@testable import LumiApp

@Suite("DEBUG identity calibration App composition")
struct AppDebugIdentityCalibrationCompositionTests {
    @Test("stop before first start does not invoke the lazy loader")
    func stopBeforeLoadIsNoOp() async throws {
        let recorder = DebugCalibrationLoaderRecorder()
        let proxy = AppIdentityCalibrationPortProxy {
            try await recorder.load()
        }

        await proxy.stopCamera()

        #expect(await recorder.loadCallCount == 0)
    }

    @Test("the lazy proxy loads once and forwards the Application port")
    func lazyProxyLoadsOnceAndForwards() async throws {
        let recorder = DebugCalibrationLoaderRecorder()
        let fake = RecordingDebugIdentityCalibrationPort()
        await recorder.setPort(fake)
        let proxy = AppIdentityCalibrationPortProxy {
            try await recorder.load()
        }
        let memberID = try MemberID(rawValue: "temporary-a")

        try await proxy.startCamera()
        try await proxy.startCamera()
        _ = try await proxy.sampleCount(for: memberID)
        _ = try await proxy.captureReturnVisit()
        try await proxy.reset(for: memberID)
        await proxy.stopCamera()

        #expect(await recorder.loadCallCount == 1)
        #expect(await fake.startCallCount == 2)
        #expect(await fake.sampleCountCalls == [memberID])
        #expect(await fake.returnCallCount == 1)
        #expect(await fake.resetMemberIDs == [memberID])
        #expect(await fake.stopCallCount == 1)
    }

    @Test("sample count before camera lazily loads without starting camera")
    func sampleCountBeforeCameraLoadsWithoutStarting() async throws {
        let recorder = DebugCalibrationLoaderRecorder()
        let fake = RecordingDebugIdentityCalibrationPort()
        await recorder.setPort(fake)
        let proxy = AppIdentityCalibrationPortProxy {
            try await recorder.load()
        }
        let memberID = try MemberID(rawValue: "temporary-a")

        #expect(try await proxy.sampleCount(for: memberID) == 0)
        #expect(await recorder.loadCallCount == 1)
        #expect(await fake.startCallCount == 0)
        #expect(await fake.sampleCountCalls == [memberID])
    }

    @Test("first photo operations lazily load once and forward exact transient values")
    func firstPhotoOperationsLoadOnceAndForward() async throws {
        let recorder = DebugCalibrationLoaderRecorder()
        let fake = RecordingDebugIdentityCalibrationPort()
        await recorder.setPort(fake)
        let proxy = AppIdentityCalibrationPortProxy {
            try await recorder.load()
        }
        let memberID = try MemberID(rawValue: "temporary-photo")
        let enrollmentURL = URL(fileURLWithPath: "/tmp/enrollment.png")
        let returnURL = URL(fileURLWithPath: "/tmp/return.heic")
        let createdAt = Date(timeIntervalSince1970: 123)

        #expect(try await proxy.captureEnrollmentPhoto(
            for: memberID,
            from: enrollmentURL,
            at: createdAt
        ) == .stored)
        #expect(try await proxy.captureReturnVisitPhoto(from: returnURL) == .noUsableFace)

        #expect(await recorder.loadCallCount == 1)
        #expect(await fake.startCallCount == 0)
        #expect(await fake.photoEnrollmentMemberIDs == [memberID])
        #expect(await fake.photoEnrollmentURLs == [enrollmentURL])
        #expect(await fake.photoEnrollmentDates == [createdAt])
        #expect(await fake.photoReturnURLs == [returnURL])
    }

    @Test("photo loader failure is redacted by the Presentation model")
    @MainActor
    func photoLoaderFailureIsRedactedByModel() async throws {
        let model = AppIdentityCalibrationComposition.makeModel {
            throw DebugCalibrationMarkerError.marker
        }

        await model.captureReturnVisitPhoto(
            from: URL(fileURLWithPath: "/tmp/loader-failure.jpg")
        )

        #expect(model.state == .stopped)
        #expect(model.statusMessage == DebugIdentityCalibrationModel.genericFailureMessage)
        #expect(String(describing: model.state).contains("marker") == false)
    }

    @Test("camera and photo operations forward after the lazy port is cached")
    func cameraAndPhotoForwardAfterCachedLoad() async throws {
        let recorder = DebugCalibrationLoaderRecorder()
        let fake = RecordingDebugIdentityCalibrationPort()
        await recorder.setPort(fake)
        let proxy = AppIdentityCalibrationPortProxy {
            try await recorder.load()
        }
        let memberID = try MemberID(rawValue: "temporary-cached")
        let enrollmentURL = URL(fileURLWithPath: "/tmp/cached.png")
        let returnURL = URL(fileURLWithPath: "/tmp/cached.jpg")

        try await proxy.startCamera()
        #expect(try await proxy.captureEnrollmentPhoto(
            for: memberID,
            from: enrollmentURL,
            at: Date(timeIntervalSince1970: 124)
        ) == .stored)
        #expect(try await proxy.captureReturnVisitPhoto(from: returnURL) == .noUsableFace)
        await proxy.stopCamera()

        #expect(await recorder.loadCallCount == 1)
        #expect(await fake.startCallCount == 1)
        #expect(await fake.stopCallCount == 1)
        #expect(await fake.photoEnrollmentURLs == [enrollmentURL])
        #expect(await fake.photoReturnURLs == [returnURL])
    }

    @Test("composition model does not invoke injected loader until start")
    @MainActor
    func modelCompositionIsLazy() async throws {
        let recorder = DebugCalibrationLoaderRecorder()
        await recorder.setPort(RecordingDebugIdentityCalibrationPort())
        let model = AppIdentityCalibrationComposition.makeModel {
            try await recorder.load()
        }

        #expect(await recorder.loadCallCount == 0)
        await model.stopCamera()
        #expect(await recorder.loadCallCount == 0)

        await model.startCamera()
        await model.stopCamera()
        await model.startCamera()

        #expect(await recorder.loadCallCount == 1)
        #expect(model.state == .ready)
    }

    @Test("loader failure is mapped to fixed Presentation copy")
    @MainActor
    func loaderFailureIsRedactedByModel() async throws {
        let model = AppIdentityCalibrationComposition.makeModel {
            throw DebugCalibrationMarkerError.marker
        }

        await model.startCamera()

        #expect(model.state == .error(
            message: DebugIdentityCalibrationModel.genericFailureMessage
        ))
        #expect(String(describing: model.state).contains("marker") == false)
    }

    @Test("database URL is pure exact Application Support/Lumi derivation")
    func databaseURLIsExactAndDoesNotCreateParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "lumi-debug-calibration-support-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        let databaseURL = AppIdentityCalibrationComposition.databaseURL(
            applicationSupportURL: root
        )

        #expect(databaseURL.path == root
            .appendingPathComponent("Lumi", isDirectory: true)
            .appendingPathComponent("IdentityCalibration.sqlite")
            .path)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Lumi").path
        ))
    }

    @Test("fresh Application Support is prepared one directory at a time")
    func freshApplicationSupportIsPreparedWithoutCreatingDatabaseFile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "lumi-debug-calibration-fresh-container-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let libraryURL = root.appendingPathComponent("Library", isDirectory: true)
        try fileManager.createDirectory(
            at: libraryURL,
            withIntermediateDirectories: false
        )
        let applicationSupportURL = libraryURL
            .appendingPathComponent("Application Support", isDirectory: true)
        #expect(!fileManager.fileExists(atPath: applicationSupportURL.path))

        let databaseURL = try AppIdentityCalibrationComposition.prepareDatabaseURL(
            applicationSupportURL: applicationSupportURL,
            fileManager: fileManager
        )

        let expectedDatabaseURL = applicationSupportURL
            .appendingPathComponent("Lumi", isDirectory: true)
            .appendingPathComponent("IdentityCalibration.sqlite", isDirectory: false)
        #expect(databaseURL == expectedDatabaseURL)
        #expect(fileManager.fileExists(atPath: applicationSupportURL.path))
        #expect(fileManager.fileExists(
            atPath: applicationSupportURL
                .appendingPathComponent("Lumi", isDirectory: true)
                .path
        ))
        #expect(!fileManager.fileExists(atPath: databaseURL.path))

        let rootEntries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        #expect(rootEntries.map(\.lastPathComponent) == ["Library"])
        let libraryEntries = try fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: nil
        )
        #expect(libraryEntries.map(\.lastPathComponent) == ["Application Support"])
        let supportEntries = try fileManager.contentsOfDirectory(
            at: applicationSupportURL,
            includingPropertiesForKeys: nil
        )
        #expect(supportEntries.map(\.lastPathComponent) == ["Lumi"])
    }

    @Test("both DEBUG app configurations declare camera usage copy")
    func debugBuildSettingsDeclareCameraUsage() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LumiApp.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectURL, encoding: .utf8)
        let key = "INFOPLIST_KEY_NSCameraUsageDescription = \"Lumi 需要使用相機，才能進行現場人臉校準與辨識測試。\";"

        #expect(project.components(separatedBy: key).count - 1 >= 2)
        #expect(project.contains("name = Debug;") && project.contains("name = \"Debug-Live\";"))
    }

    @Test("debug calibration view consumes the approved copy and renders")
    @MainActor
    func debugCalibrationViewUsesApprovedCopy() {
        let model = DebugIdentityCalibrationModel(
            port: RecordingDebugIdentityCalibrationPort()
        )
        let view = DebugIdentityCalibrationView(model: model)
        _ = view.body

        #expect(DebugIdentityCalibrationView.viewIntent.title == "DEBUG 身份校準")
        #expect(DebugIdentityCalibrationView.viewIntent.enrollmentLabel == "非正式 enrollment")
        #expect(DebugIdentityCalibrationView.viewIntent.sampleGuidance == "建議 3–5 個樣本")
        #expect(DebugIdentityCalibrationView.viewIntent.startLabel == "開始相機")
        #expect(DebugIdentityCalibrationView.viewIntent.stopLabel == "停止相機")
        #expect(DebugIdentityCalibrationView.viewIntent.returnLabel == "拍攝回訪")
        #expect(DebugIdentityCalibrationView.viewIntent.noThresholdCopy == "僅供校準觀察")
        #expect(DebugIdentityCalibrationView.viewIntent.enrollmentPhotoLabel == "匯入 enrollment 照片")
        #expect(DebugIdentityCalibrationView.viewIntent.returnPhotoLabel == "匯入回訪照片")
        #expect(DebugIdentityCalibrationView.viewIntent.photoTestCopy == "DEBUG 檔案測試，不代表 iPad 相機品質")
        #expect(DebugIdentityCalibrationView.viewIntent.photoFilesGuidance == "請先把照片放到 Simulator 可存取的「檔案/iCloud Drive」")
        #expect(DebugIdentityCalibrationView.viewIntent.enrollmentPhotoAccessibilityIdentifier == "debug-identity-calibration-enrollment-photo")
        #expect(DebugIdentityCalibrationView.viewIntent.returnPhotoAccessibilityIdentifier == "debug-identity-calibration-return-photo")
        #expect(DebugIdentityCalibrationView.allowedPhotoTypeIdentifiers == [
            UTType.jpeg.identifier,
            UTType.png.identifier,
            UTType.heic.identifier
        ])
    }
}

private actor DebugCalibrationLoaderRecorder {
    private var port: (any IdentityCalibrationPort)?
    private(set) var loadCallCount = 0

    func setPort(_ port: any IdentityCalibrationPort) {
        self.port = port
    }

    func load() async throws -> any IdentityCalibrationPort {
        loadCallCount += 1
        guard let port else { throw DebugCalibrationMarkerError.marker }
        return port
    }
}

private actor RecordingDebugIdentityCalibrationPort: IdentityCalibrationPort {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var sampleCountCalls: [MemberID] = []
    private(set) var photoEnrollmentMemberIDs: [MemberID] = []
    private(set) var photoEnrollmentURLs: [URL] = []
    private(set) var photoEnrollmentDates: [Date] = []
    private(set) var photoReturnURLs: [URL] = []
    private(set) var resetMemberIDs: [MemberID] = []
    private(set) var returnCallCount = 0

    func startCamera() async throws {
        startCallCount += 1
    }

    func stopCamera() async {
        stopCallCount += 1
    }

    func captureEnrollmentSample(
        for temporaryMemberID: MemberID,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        _ = temporaryMemberID
        _ = createdAt
        return .noUsableFace
    }

    func captureReturnVisit() async throws -> IdentityCalibrationReturnResult {
        returnCallCount += 1
        return .measured(IdentityCalibrationEvidence(
            gallerySampleCount: 0,
            top1: nil,
            top2: nil
        ))
    }

    func captureEnrollmentPhoto(
        for temporaryMemberID: MemberID,
        from imageURL: URL,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        photoEnrollmentMemberIDs.append(temporaryMemberID)
        photoEnrollmentURLs.append(imageURL)
        photoEnrollmentDates.append(createdAt)
        return .stored
    }

    func captureReturnVisitPhoto(
        from imageURL: URL
    ) async throws -> IdentityCalibrationReturnResult {
        photoReturnURLs.append(imageURL)
        return .noUsableFace
    }

    func sampleCount(for temporaryMemberID: MemberID) async throws -> Int {
        sampleCountCalls.append(temporaryMemberID)
        return 0
    }

    func reset(for temporaryMemberID: MemberID) async throws {
        resetMemberIDs.append(temporaryMemberID)
    }
}

private enum DebugCalibrationMarkerError: Error {
    case marker
}

#endif
