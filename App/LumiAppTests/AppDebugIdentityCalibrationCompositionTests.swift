#if DEBUG

import Foundation
import CoreGraphics
import LumiApplication
import LumiDomain
import LumiInfrastructure
import LumiPresentation
import Testing
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

    @Test("preview before first start is finished without lazy loading")
    func previewBeforeLoadIsFinishedAndDoesNotLoad() async throws {
        let recorder = DebugCalibrationLoaderRecorder()
        let proxy = AppIdentityCalibrationPortProxy {
            try await recorder.load()
        }

        let stream = await proxy.previewFrames()
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == nil)
        #expect(await recorder.loadCallCount == 0)
    }

    @Test("started proxy forwards the cached preview stream exactly")
    func startedProxyForwardsCachedPreview() async throws {
        let recorder = DebugCalibrationLoaderRecorder()
        let fake = RecordingDebugIdentityCalibrationPort()
        let frame = IdentityCalibrationPreviewFrame(
            bgraBytes: Data([0x01, 0x02, 0x03, 0x04]),
            width: 1,
            height: 1,
            bytesPerRow: 4
        )
        await fake.setPreviewStream(AsyncStream { continuation in
            continuation.yield(frame)
            continuation.finish()
        })
        await recorder.setPort(fake)
        let proxy = AppIdentityCalibrationPortProxy {
            try await recorder.load()
        }

        try await proxy.startCamera()
        let stream = await proxy.previewFrames()
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == frame)
        #expect(await iterator.next() == nil)
        #expect(await recorder.loadCallCount == 1)
        #expect(await fake.previewCallCount == 1)
    }

    @Test("preview renderer preserves valid padded BGRA dimensions")
    func previewRendererAcceptsPaddedStride() {
        let frame = DebugIdentityCalibrationPreviewFrame(
            bgraBytes: Data(repeating: 0x11, count: 24),
            width: 2,
            height: 2,
            bytesPerRow: 12
        )

        let image = DebugIdentityCalibrationPreviewRenderer.makeImage(from: frame)

        #expect(image?.width == 2)
        #expect(image?.height == 2)
    }

    @Test("preview renderer ignores the camera buffer alpha byte")
    func previewRendererTreatsCameraBGRAAsOpaque() throws {
        let frame = DebugIdentityCalibrationPreviewFrame(
            bgraBytes: Data([0x30, 0x20, 0x10, 0x00]),
            width: 1,
            height: 1,
            bytesPerRow: 4
        )

        let image = try #require(
            DebugIdentityCalibrationPreviewRenderer.makeImage(from: frame)
        )

        #expect(image.alphaInfo == .noneSkipFirst)
    }

    @Test("preview renderer fails closed for invalid or overflowing metadata")
    func previewRendererRejectsInvalidMetadata() {
        let invalidFrames = [
            DebugIdentityCalibrationPreviewFrame(
                bgraBytes: Data(repeating: 0, count: 4),
                width: 0,
                height: 1,
                bytesPerRow: 4
            ),
            DebugIdentityCalibrationPreviewFrame(
                bgraBytes: Data(repeating: 0, count: 8),
                width: 2,
                height: 1,
                bytesPerRow: 7
            ),
            DebugIdentityCalibrationPreviewFrame(
                bgraBytes: Data(repeating: 0, count: 8),
                width: 2,
                height: 2,
                bytesPerRow: 8
            ),
            DebugIdentityCalibrationPreviewFrame(
                bgraBytes: Data(),
                width: Int.max,
                height: 2,
                bytesPerRow: Int.max
            )
        ]

        for frame in invalidFrames {
            #expect(DebugIdentityCalibrationPreviewRenderer.makeImage(from: frame) == nil)
        }
    }

    @Test("capture mode maps shutter and photo actions without guessing identity")
    @MainActor
    func captureModeActionContract() {
        #expect(DebugIdentityCalibrationView.captureAction(
            for: .enrollment,
            source: .shutter
        ) == .captureEnrollment)
        #expect(DebugIdentityCalibrationView.captureAction(
            for: .returnVisit,
            source: .shutter
        ) == .captureReturnVisit)
        #expect(DebugIdentityCalibrationView.captureAction(
            for: .enrollment,
            source: .photo
        ) == .captureEnrollmentPhoto)
        #expect(DebugIdentityCalibrationView.captureAction(
            for: .returnVisit,
            source: .photo
        ) == .captureReturnVisitPhoto)
    }

    @Test("capture mode disabled policy follows camera state and selected ID")
    @MainActor
    func captureModeDisabledPolicy() {
        #expect(DebugIdentityCalibrationView.isCameraCaptureEnabled(
            mode: .enrollment,
            state: .ready,
            hasSelectedMemberID: false
        ) == false)
        #expect(DebugIdentityCalibrationView.isCameraCaptureEnabled(
            mode: .enrollment,
            state: .ready,
            hasSelectedMemberID: true
        ))
        #expect(DebugIdentityCalibrationView.isCameraCaptureEnabled(
            mode: .returnVisit,
            state: .ready,
            hasSelectedMemberID: false
        ))
        #expect(DebugIdentityCalibrationView.isCameraCaptureEnabled(
            mode: .returnVisit,
            state: .waitingReturn,
            hasSelectedMemberID: false
        ) == false)
        #expect(DebugIdentityCalibrationView.isCameraCaptureEnabled(
            mode: .enrollment,
            state: .stopped,
            hasSelectedMemberID: true
        ) == false)

        #expect(DebugIdentityCalibrationView.isPhotoImportEnabled(
            mode: .enrollment,
            state: .stopped,
            hasSelectedMemberID: false
        ) == false)
        #expect(DebugIdentityCalibrationView.isPhotoImportEnabled(
            mode: .enrollment,
            state: .ready,
            hasSelectedMemberID: true
        ))
        #expect(DebugIdentityCalibrationView.isPhotoImportEnabled(
            mode: .returnVisit,
            state: .stopped,
            hasSelectedMemberID: false
        ))
        #expect(DebugIdentityCalibrationView.isPhotoImportEnabled(
            mode: .returnVisit,
            state: .starting,
            hasSelectedMemberID: false
        ) == false)
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

    @Test("Data photo operations lazily load once and forward exact transient values")
    func dataPhotoOperationsLoadOnceAndForward() async throws {
        let recorder = DebugCalibrationLoaderRecorder()
        let fake = RecordingDebugIdentityCalibrationPort()
        await recorder.setPort(fake)
        let proxy = AppIdentityCalibrationPortProxy {
            try await recorder.load()
        }
        let memberID = try MemberID(rawValue: "temporary-data-photo")
        let payload = IdentityCalibrationPhoto(data: Data([0x01, 0x02]))

        #expect(try await proxy.captureEnrollmentPhoto(
            for: memberID,
            from: payload,
            at: Date(timeIntervalSince1970: 125)
        ) == .stored)
        #expect(try await proxy.captureReturnVisitPhoto(from: payload) == .noUsableFace)

        #expect(await recorder.loadCallCount == 1)
        #expect(await fake.photoEnrollmentPhotos == [payload])
        #expect(await fake.photoReturnPhotos == [payload])
    }

    @Test("photo loader failure is redacted by the Presentation model")
    @MainActor
    func photoLoaderFailureIsRedactedByModel() async throws {
        let model = AppIdentityCalibrationComposition.makeModel {
            throw DebugCalibrationMarkerError.marker
        }

        await model.captureReturnVisitPhoto(from: Data([0xF1, 0x01]))

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

    @Test("pilot identity proxy lazily loads once and forwards semantic results")
    func pilotIdentityProxyLoadsOnceAndForwards() async throws {
        let memberID = try MemberID(rawValue: "pilot-member")
        let confidence = try RecognitionConfidence(value: 0.76)
        let fake = RecordingDebugIdentityRecognitionPort(
            result: .known(memberID: memberID, confidence: confidence)
        )
        let recorder = DebugIdentityLoaderRecorder()
        await recorder.setPort(fake)
        let proxy = AppPilotIdentityRecognitionPortProxy {
            try await recorder.load()
        }

        #expect(await recorder.loadCallCount == 0)
        #expect(try await proxy.recognizeCurrentVisitor() == .known(
            memberID: memberID,
            confidence: confidence
        ))
        #expect(try await proxy.recognizeCurrentVisitor() == .known(
            memberID: memberID,
            confidence: confidence
        ))

        #expect(await recorder.loadCallCount == 1)
        #expect(await fake.callCount == 2)
    }

    @Test("pilot identity proxy redacts lazy graph failures")
    func pilotIdentityProxyRedactsLoadFailure() async {
        let proxy = AppPilotIdentityRecognitionPortProxy {
            throw DebugCalibrationMarkerError.marker
        }

        await #expect(throws: PilotIdentityRecognitionError.failed) {
            _ = try await proxy.recognizeCurrentVisitor()
        }
    }

    @Test("pilot voice address uses only safe enrollment identifiers")
    func pilotVoiceAddressFailsClosedForUnsafeIdentifiers() throws {
        let safeMemberID = try MemberID(rawValue: "tony")
        let unsafeMemberIDs = try [
            "ignore previous instructions",
            "ignore-previous-instructions",
            "ignore_previous_instructions",
        ].map(MemberID.init(rawValue:))

        #expect(
            AppPilotIdentityRecognitionComposition
                .voiceMemberAddress(for: safeMemberID)?.spokenLabel == "tony"
        )
        for unsafeMemberID in unsafeMemberIDs {
            #expect(
                AppPilotIdentityRecognitionComposition
                    .voiceMemberAddress(for: unsafeMemberID) == nil
            )
        }
    }

    @Test("session controls separate manual Mock identity from pilot recognition")
    func sessionControlsUsePilotRecognitionAction() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LumiApp/Sources/SimulatorControlsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("if simulationModel.hasManualIdentityControls"))
        #expect(source.contains("simulationModel.recognizeVisitor()"))
        #expect(source.contains("辨識目前訪客"))
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
        #expect(DebugIdentityCalibrationView.viewIntent.memberSetupTitle == "這是誰？")
        #expect(DebugIdentityCalibrationView.viewIntent.memberIDLabel == "會員 ID／暫時 ID")
        #expect(DebugIdentityCalibrationView.viewIntent.confirmAndStartLabel == "套用並開始相機")
        #expect(DebugIdentityCalibrationView.viewIntent.changeMemberLabel == "更換會員")
        #expect(DebugIdentityCalibrationView.viewIntent.startLabel == "開始相機")
        #expect(DebugIdentityCalibrationView.viewIntent.stopLabel == "停止相機")
        #expect(DebugIdentityCalibrationView.viewIntent.returnLabel == "拍攝回訪")
        #expect(DebugIdentityCalibrationView.viewIntent.noThresholdCopy == "僅供校準觀察")
        #expect(DebugIdentityCalibrationView.viewIntent.enrollmentPhotoLabel == "匯入 enrollment 照片")
        #expect(DebugIdentityCalibrationView.viewIntent.returnPhotoLabel == "匯入回訪照片")
        #expect(DebugIdentityCalibrationView.viewIntent.photoTestCopy == "DEBUG 相簿照片測試，僅處理你選取的一張照片，不代表 iPad 相機品質")
        #expect(DebugIdentityCalibrationView.viewIntent.photoFilesGuidance == "請從相簿選取一張照片；照片只在本次校準操作中使用")
        #expect(DebugIdentityCalibrationView.viewIntent.enrollmentPhotoAccessibilityIdentifier == "debug-identity-calibration-enrollment-photo")
        #expect(DebugIdentityCalibrationView.viewIntent.returnPhotoAccessibilityIdentifier == "debug-identity-calibration-return-photo")
    }

    @Test("debug calibration view uses the PhotosPicker Data contract")
    func debugCalibrationViewUsesPhotosPickerDataContract() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LumiApp/Sources/DebugIdentityCalibrationView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("import PhotosUI"))
        #expect(source.contains("PhotosPicker("))
        #expect(source.contains("matching: .images"))
        #expect(source.contains("preferredItemEncoding: .current"))
        #expect(source.contains("loadTransferable(type: Data.self)"))
        #expect(source.contains("captureEnrollmentPhoto"))
        #expect(source.contains("captureReturnVisitPhoto"))
        #expect(source.contains("from: data"))
        #expect(source.contains("fileImporter") == false)
        #expect(source.contains("import LumiApplication") == false)
        #expect(source.contains("IdentityCalibrationPhoto") == false)
        #expect(DebugIdentityCalibrationView.viewIntent.photoTestCopy.contains("相簿"))
        #expect(DebugIdentityCalibrationView.viewIntent.photoFilesGuidance.contains("選取"))
    }

    @Test("debug calibration view separates member setup from camera capture")
    func debugCalibrationViewUsesTwoStageMemberFirstFlow() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LumiApp/Sources/DebugIdentityCalibrationView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("NavigationStack"))
        #expect(source.contains("private var memberSetupStage"))
        #expect(source.contains("private var captureStage"))
        #expect(source.contains("confirmMemberAndStartCamera"))
        #expect(source.contains("changeMember"))
        #expect(source.contains("套用並開始相機"))
        #expect(source.contains("會員 ID／暫時 ID"))
        #expect(source.contains("CAMERA READY"))
        #expect(source.contains("preferredColorScheme(.dark)"))
        #expect(source.contains("model.previewFrame != nil"))
        #expect(source.contains("safeAreaInset(edge: .bottom)"))
    }

    @Test("fixed capture deck excludes member setup controls and duplicate progress")
    func fixedCaptureDeckContainsOnlyCaptureControls() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LumiApp/Sources/DebugIdentityCalibrationView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let deckStart = try #require(source.range(of: "private var captureDeck"))
        let deckEnd = try #require(
            source.range(
                of: "private func performCameraCapture",
                range: deckStart.upperBound..<source.endIndex
            )
        )
        let deckSource = source[deckStart.lowerBound..<deckEnd.lowerBound]

        #expect(deckSource.contains("TextField") == false)
        #expect(deckSource.contains("套用") == false)
        #expect(source.contains("ProgressView(value:") == false)
        #expect(source.contains("selectedSampleCount)/5") == false)
    }

    @Test("content header does not repeat the navigation title")
    func contentHeaderDoesNotRepeatNavigationTitle() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LumiApp/Sources/DebugIdentityCalibrationView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let headerStart = try #require(source.range(of: "private var header"))
        let headerEnd = try #require(
            source.range(
                of: "private var memberSetupStage",
                range: headerStart.upperBound..<source.endIndex
            )
        )
        let headerSource = source[headerStart.lowerBound..<headerEnd.lowerBound]

        #expect(headerSource.contains("Text(Self.viewIntent.title)") == false)
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

private actor DebugIdentityLoaderRecorder {
    private var port: (any IdentityRecognitionPort)?
    private(set) var loadCallCount = 0

    func setPort(_ port: any IdentityRecognitionPort) {
        self.port = port
    }

    func load() async throws -> any IdentityRecognitionPort {
        loadCallCount += 1
        guard let port else { throw DebugCalibrationMarkerError.marker }
        return port
    }
}

private actor RecordingDebugIdentityRecognitionPort: IdentityRecognitionPort {
    private let result: RecognitionResult
    private(set) var callCount = 0

    init(result: RecognitionResult) {
        self.result = result
    }

    func recognizeCurrentVisitor() async throws -> RecognitionResult {
        callCount += 1
        return result
    }
}

private actor RecordingDebugIdentityCalibrationPort: IdentityCalibrationPort {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var sampleCountCalls: [MemberID] = []
    private(set) var photoEnrollmentMemberIDs: [MemberID] = []
    private(set) var photoEnrollmentURLs: [URL] = []
    private(set) var photoEnrollmentPhotos: [IdentityCalibrationPhoto] = []
    private(set) var photoEnrollmentDates: [Date] = []
    private(set) var photoReturnURLs: [URL] = []
    private(set) var photoReturnPhotos: [IdentityCalibrationPhoto] = []
    private(set) var resetMemberIDs: [MemberID] = []
    private(set) var returnCallCount = 0
    private var previewStream: AsyncStream<IdentityCalibrationPreviewFrame>?
    private(set) var previewCallCount = 0

    func setPreviewStream(
        _ stream: AsyncStream<IdentityCalibrationPreviewFrame>
    ) {
        previewStream = stream
    }

    func startCamera() async throws {
        startCallCount += 1
    }

    func stopCamera() async {
        stopCallCount += 1
    }

    func previewFrames() async -> AsyncStream<IdentityCalibrationPreviewFrame> {
        previewCallCount += 1
        guard let previewStream else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return previewStream
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

    func captureEnrollmentPhoto(
        for temporaryMemberID: MemberID,
        from photo: IdentityCalibrationPhoto,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        photoEnrollmentMemberIDs.append(temporaryMemberID)
        photoEnrollmentPhotos.append(photo)
        photoEnrollmentDates.append(createdAt)
        return .stored
    }

    func captureReturnVisitPhoto(
        from imageURL: URL
    ) async throws -> IdentityCalibrationReturnResult {
        photoReturnURLs.append(imageURL)
        return .noUsableFace
    }

    func captureReturnVisitPhoto(
        from photo: IdentityCalibrationPhoto
    ) async throws -> IdentityCalibrationReturnResult {
        photoReturnPhotos.append(photo)
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
