#if DEBUG

import SwiftUI
import PhotosUI
import LumiPresentation

/// DEBUG-only surface for manually collecting temporary calibration samples.
///
/// The view renders only Presentation-owned strings, counts, and raw score
/// evidence. It never reaches into camera, Vision, Core ML, SQLite, or model
/// loading APIs.
@MainActor
struct DebugIdentityCalibrationView: View {
    struct ViewIntent: Equatable, Sendable {
        let title: String
        let enrollmentLabel: String
        let sampleGuidance: String
        let startLabel: String
        let stopLabel: String
        let returnLabel: String
        let noThresholdCopy: String
        let enrollmentPhotoLabel: String
        let returnPhotoLabel: String
        let photoTestCopy: String
        let photoFilesGuidance: String
        let enrollmentPhotoAccessibilityIdentifier: String
        let returnPhotoAccessibilityIdentifier: String
    }

    static let viewIntent = ViewIntent(
        title: "DEBUG 身份校準",
        enrollmentLabel: "非正式 enrollment",
        sampleGuidance: "建議 3–5 個樣本",
        startLabel: "開始相機",
        stopLabel: "停止相機",
        returnLabel: "拍攝回訪",
        noThresholdCopy: "僅供校準觀察",
        enrollmentPhotoLabel: "匯入 enrollment 照片",
        returnPhotoLabel: "匯入回訪照片",
        photoTestCopy: "DEBUG 相簿照片測試，僅處理你選取的一張照片，不代表 iPad 相機品質",
        photoFilesGuidance: "請從相簿選取一張照片；照片只在本次校準操作中使用",
        enrollmentPhotoAccessibilityIdentifier: "debug-identity-calibration-enrollment-photo",
        returnPhotoAccessibilityIdentifier: "debug-identity-calibration-return-photo"
    )

    private static let photoPickerFailureMessage = "照片匯入失敗，請再試一次"

    @Bindable private var model: DebugIdentityCalibrationModel
    @State private var isResetDialogPresented = false
    @State private var selectedEnrollmentPhotoItem: PhotosPickerItem?
    @State private var selectedReturnPhotoItem: PhotosPickerItem?
    @State private var photoPickerFailureMessage: String?

    init(model: DebugIdentityCalibrationModel) {
        _model = Bindable(model)
    }

    private var canCaptureEnrollment: Bool {
        model.state == .ready && model.selectedMemberID != nil
    }

    private var canCaptureReturn: Bool {
        model.state == .ready
    }

    private var canImportPhoto: Bool {
        switch model.state {
        case .stopped, .ready:
            true
        case .starting, .waitingEnrollment, .waitingReturn, .error:
            false
        }
    }

    private var canImportEnrollmentPhoto: Bool {
        canImportPhoto && model.selectedMemberID != nil
    }

    private var canImportReturnPhoto: Bool {
        canImportPhoto
    }

    private var showsStartButton: Bool {
        switch model.state {
        case .stopped, .error:
            true
        case .starting, .ready, .waitingEnrollment, .waitingReturn:
            false
        }
    }

    private var stateCopy: String {
        switch model.state {
        case .stopped:
            "相機已停止"
        case .starting:
            "正在啟動相機"
        case .ready:
            "相機已準備好"
        case .waitingEnrollment:
            "正在等待下一張 enrollment frame"
        case .waitingReturn:
            "正在等待下一張回訪 frame"
        case let .error(message):
            message
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(Self.viewIntent.title)
                        .font(.title2.weight(.semibold))
                    Text(Self.viewIntent.enrollmentLabel)
                    Text(Self.viewIntent.sampleGuidance)
                    Text(Self.viewIntent.noThresholdCopy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Self.viewIntent.photoTestCopy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Self.viewIntent.photoFilesGuidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("臨時會員") {
                    TextField("臨時 member ID", text: $model.memberIDInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("載入樣本數") {
                        Task { await model.selectTemporaryMember() }
                    }
                    if let selectedMemberID = model.selectedMemberID {
                        Text("目前 ID：\(selectedMemberID)")
                        Text("樣本數：\(model.selectedSampleCount)")
                    }
                }

                Section("相機") {
                    Button {
                        Task {
                            if showsStartButton {
                                await model.startCamera()
                            } else {
                                await model.stopCamera()
                            }
                        }
                    } label: {
                        Text(showsStartButton
                            ? Self.viewIntent.startLabel
                            : Self.viewIntent.stopLabel)
                    }
                    Text(stateCopy)
                        .foregroundStyle(.secondary)
                }

                Section("校準操作") {
                    Button(Self.viewIntent.enrollmentLabel) {
                        Task { await model.captureEnrollment() }
                    }
                    .disabled(!canCaptureEnrollment)

                    Button(Self.viewIntent.returnLabel) {
                        Task { await model.captureReturnVisit() }
                    }
                    .disabled(!canCaptureReturn)

                    PhotosPicker(
                        selection: $selectedEnrollmentPhotoItem,
                        matching: .images,
                        preferredItemEncoding: .current
                    ) {
                        Text(Self.viewIntent.enrollmentPhotoLabel)
                    }
                    .disabled(!canImportEnrollmentPhoto)
                    .accessibilityIdentifier(
                        Self.viewIntent.enrollmentPhotoAccessibilityIdentifier
                    )
                    .onChange(of: selectedEnrollmentPhotoItem) { _, item in
                        guard let item else { return }
                        selectedEnrollmentPhotoItem = nil
                        photoPickerFailureMessage = nil
                        Task { await handleEnrollmentPhotoSelection(item) }
                    }

                    PhotosPicker(
                        selection: $selectedReturnPhotoItem,
                        matching: .images,
                        preferredItemEncoding: .current
                    ) {
                        Text(Self.viewIntent.returnPhotoLabel)
                    }
                    .disabled(!canImportReturnPhoto)
                    .accessibilityIdentifier(
                        Self.viewIntent.returnPhotoAccessibilityIdentifier
                    )
                    .onChange(of: selectedReturnPhotoItem) { _, item in
                        guard let item else { return }
                        selectedReturnPhotoItem = nil
                        photoPickerFailureMessage = nil
                        Task { await handleReturnPhotoSelection(item) }
                    }

                    Button("重設選取 ID", role: .destructive) {
                        model.requestReset()
                        isResetDialogPresented = model.isResetConfirmationPresented
                    }
                    .disabled(model.selectedMemberID == nil)
                }

                if let evidence = model.scoreEvidence {
                    Section("分數證據") {
                        Text("gallery samples：\(evidence.gallerySampleCount)")
                        if let top1 = evidence.top1 {
                            Text("top 1 \(top1.memberID)：\(top1.cosineSimilarity)")
                        }
                        if let top2 = evidence.top2 {
                            Text("top 2 \(top2.memberID)：\(top2.cosineSimilarity)")
                        }
                        if let margin = evidence.margin {
                            Text("margin：\(margin)")
                        }
                    }
                }

                if let statusMessage = model.statusMessage {
                    Section {
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                    }
                }

                if let photoPickerFailureMessage {
                    Section {
                        Text(photoPickerFailureMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(Self.viewIntent.title)
        }
        .confirmationDialog(
            "確認重設選取 ID？",
            isPresented: $isResetDialogPresented,
            titleVisibility: .visible
        ) {
            Button("重設", role: .destructive) {
                Task { await model.confirmReset() }
            }
            Button("取消", role: .cancel) {
                model.cancelReset()
            }
        } message: {
            Text("只會刪除目前選取的臨時 ID 樣本。")
        }
        .onDisappear {
            Task { await model.stopCamera() }
        }
    }

    private func handleEnrollmentPhotoSelection(
        _ item: PhotosPickerItem
    ) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PhotoSelectionError.missingData
            }
            await model.captureEnrollmentPhoto(from: data)
        } catch {
            photoPickerFailureMessage = Self.photoPickerFailureMessage
        }
    }

    private func handleReturnPhotoSelection(
        _ item: PhotosPickerItem
    ) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PhotoSelectionError.missingData
            }
            await model.captureReturnVisitPhoto(from: data)
        } catch {
            photoPickerFailureMessage = Self.photoPickerFailureMessage
        }
    }
}

private enum PhotoSelectionError: Error {
    case missingData
}

#endif
