#if DEBUG

import SwiftUI
import PhotosUI
import CoreGraphics
import LumiPresentation

/// DEBUG-only surface for manually collecting temporary calibration samples.
///
/// The view renders Presentation-owned values and delegates every operation to
/// `DebugIdentityCalibrationModel`. Camera bytes are converted only for the
/// active display preview; they are never persisted, logged, or encoded here.
@MainActor
struct DebugIdentityCalibrationView: View {
    private enum FlowStep: Equatable {
        case memberSetup
        case capture
    }

    enum CaptureMode: String, CaseIterable, Equatable, Sendable {
        case enrollment
        case returnVisit
    }

    enum CaptureSource: Equatable, Sendable {
        case shutter
        case photo
    }

    enum CaptureAction: Equatable, Sendable {
        case captureEnrollment
        case captureReturnVisit
        case captureEnrollmentPhoto
        case captureReturnVisitPhoto
    }

    struct ViewIntent: Equatable, Sendable {
        let title: String
        let enrollmentLabel: String
        let returnModeLabel: String
        let sampleGuidance: String
        let memberSetupTitle: String
        let memberIDLabel: String
        let confirmAndStartLabel: String
        let changeMemberLabel: String
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
        let closeLabel: String
        let shutterAccessibilityLabel: String
        let previewAccessibilityLabel: String
        let readyCopy: String
    }

    static let viewIntent = ViewIntent(
        title: "DEBUG 身份校準",
        enrollmentLabel: "非正式 enrollment",
        returnModeLabel: "回訪",
        sampleGuidance: "建議 3–5 個樣本",
        memberSetupTitle: "這是誰？",
        memberIDLabel: "會員 ID／暫時 ID",
        confirmAndStartLabel: "套用並開始相機",
        changeMemberLabel: "更換會員",
        startLabel: "開始相機",
        stopLabel: "停止相機",
        returnLabel: "拍攝回訪",
        noThresholdCopy: "僅供校準觀察",
        enrollmentPhotoLabel: "匯入 enrollment 照片",
        returnPhotoLabel: "匯入回訪照片",
        photoTestCopy: "DEBUG 相簿照片測試，僅處理你選取的一張照片，不代表 iPad 相機品質",
        photoFilesGuidance: "請從相簿選取一張照片；照片只在本次校準操作中使用",
        enrollmentPhotoAccessibilityIdentifier: "debug-identity-calibration-enrollment-photo",
        returnPhotoAccessibilityIdentifier: "debug-identity-calibration-return-photo",
        closeLabel: "關閉校準",
        shutterAccessibilityLabel: "手動拍攝校準樣本",
        previewAccessibilityLabel: "相機即時預覽",
        readyCopy: "相機已準備好"
    )

    private static let photoPickerFailureMessage = "照片匯入失敗，請再試一次"
    private static let fieldBackground = Color(
        red: 17.0 / 255.0,
        green: 24.0 / 255.0,
        blue: 39.0 / 255.0
    )
    private static let primaryGreen = Color(
        red: 37.0 / 255.0,
        green: 166.0 / 255.0,
        blue: 73.0 / 255.0
    )
    private static let secondaryLime = Color(
        red: 87.0 / 255.0,
        green: 193.0 / 255.0,
        blue: 81.0 / 255.0
    )

    @Environment(\.dismiss) private var dismiss
    @Bindable private var model: DebugIdentityCalibrationModel
    @State private var flowStep: FlowStep = .memberSetup
    @State private var captureMode: CaptureMode = .enrollment
    @State private var isResetDialogPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoPickerFailureMessage: String?
    @FocusState private var isMemberIDFocused: Bool

    init(model: DebugIdentityCalibrationModel) {
        _model = Bindable(model)
    }

    static func captureAction(
        for mode: CaptureMode,
        source: CaptureSource
    ) -> CaptureAction {
        switch (mode, source) {
        case (.enrollment, .shutter):
            .captureEnrollment
        case (.returnVisit, .shutter):
            .captureReturnVisit
        case (.enrollment, .photo):
            .captureEnrollmentPhoto
        case (.returnVisit, .photo):
            .captureReturnVisitPhoto
        }
    }

    static func isCameraCaptureEnabled(
        mode: CaptureMode,
        state: DebugIdentityCalibrationState,
        hasSelectedMemberID: Bool
    ) -> Bool {
        guard state == .ready else { return false }
        switch mode {
        case .enrollment:
            return hasSelectedMemberID
        case .returnVisit:
            return true
        }
    }

    static func isPhotoImportEnabled(
        mode: CaptureMode,
        state: DebugIdentityCalibrationState,
        hasSelectedMemberID: Bool
    ) -> Bool {
        guard state == .stopped || state == .ready else { return false }
        switch mode {
        case .enrollment:
            return hasSelectedMemberID
        case .returnVisit:
            return true
        }
    }

    private var hasSelectedMemberID: Bool {
        model.selectedMemberID != nil
    }

    private var canCaptureCurrentMode: Bool {
        Self.isCameraCaptureEnabled(
            mode: captureMode,
            state: model.state,
            hasSelectedMemberID: hasSelectedMemberID
        )
    }

    private var canImportCurrentMode: Bool {
        Self.isPhotoImportEnabled(
            mode: captureMode,
            state: model.state,
            hasSelectedMemberID: hasSelectedMemberID
        )
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
            Self.viewIntent.readyCopy
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
            ZStack {
                Self.fieldBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        switch flowStep {
                        case .memberSetup:
                            memberSetupStage
                        case .capture:
                            captureStage
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) {
                    if flowStep == .capture {
                        captureDeck
                            .background(Self.fieldBackground)
                    }
                }
            }
            .navigationTitle(Self.viewIntent.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await model.stopCamera()
                            dismiss()
                        }
                    } label: {
                        Label(Self.viewIntent.closeLabel, systemImage: "xmark")
                    }
                    .accessibilityLabel(Self.viewIntent.closeLabel)
                    .accessibilityHint("先停止相機，再關閉身份校準")
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .confirmationDialog(
                "確認清除目前會員樣本？",
                isPresented: $isResetDialogPresented,
                titleVisibility: .visible
            ) {
                Button("清除樣本", role: .destructive) {
                    Task { await model.confirmReset() }
                }
                Button("取消", role: .cancel) {
                    model.cancelReset()
                }
            } message: {
                Text("只會刪除目前會員 ID 的校準樣本，不會刪除會員資料。")
            }
            .onDisappear {
                Task { await model.stopCamera() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("LUMI FIELD / IDENTITY CONSOLE")
                    .font(.caption.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(Self.secondaryLime)
                Spacer(minLength: 12)
                Text("DEBUG")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Self.secondaryLime)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .overlay {
                        Capsule().stroke(Self.secondaryLime.opacity(0.7), lineWidth: 1)
                    }
            }
            Text(Self.viewIntent.noThresholdCopy)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    private var memberSetupStage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(Self.secondaryLime)
                .frame(width: 64, height: 64)
                .background(Self.secondaryLime.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 8) {
                Text(Self.viewIntent.memberSetupTitle)
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text("先確認鏡頭前的會員，再開始校準。這裡可使用會員 ID 或測試用暫時 ID。")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(Self.viewIntent.memberIDLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                TextField("例如 tony", text: $model.memberIDInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .submitLabel(.go)
                    .focused($isMemberIDFocused)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.14), lineWidth: 1)
                    }
                    .foregroundStyle(.white)
                    .tint(Self.primaryGreen)
                    .onSubmit {
                        Task { await confirmMemberAndStartCamera() }
                    }
                    .accessibilityLabel(Self.viewIntent.memberIDLabel)
            }

            if model.selectedMemberID == model.memberIDInput,
               let selectedMemberID = model.selectedMemberID {
                Label(
                    "\(selectedMemberID) 已儲存 \(model.selectedSampleCount) 個樣本",
                    systemImage: "person.text.rectangle"
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
            } else {
                Text("使用既有 ID 時會先載入原有樣本；不會建立或刪除正式會員帳號。")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.54))
            }

            Button {
                Task { await confirmMemberAndStartCamera() }
            } label: {
                HStack(spacing: 10) {
                    if model.state == .starting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "camera.fill")
                    }
                    Text(model.state == .starting
                        ? "正在準備相機"
                        : Self.viewIntent.confirmAndStartLabel)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.primaryGreen)
            .disabled(model.memberIDInput.isEmpty || model.state == .starting)
            .accessibilityLabel(Self.viewIntent.confirmAndStartLabel)

            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Self.secondaryLime)
            } else if case let .error(message) = model.state {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Self.secondaryLime)
            }
        }
        .padding(22)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear {
            isMemberIDFocused = true
        }
    }

    private var captureStage: some View {
        VStack(alignment: .leading, spacing: 16) {
            previewPanel
            captureContext
            evidenceCard
        }
    }

    private var previewPanel: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if let frame = model.previewFrame,
                   let image = DebugIdentityCalibrationPreviewRenderer.makeImage(from: frame) {
                    Image(
                        image,
                        scale: 1,
                        orientation: .up,
                        label: Text(Self.viewIntent.previewAccessibilityLabel)
                    )
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(x: -1, y: 1)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 38, weight: .medium))
                        Text(stateCopy)
                            .font(.headline)
                        if model.state == .ready {
                            Text("CAMERA READY")
                                .font(.caption.weight(.bold))
                                .tracking(1)
                                .foregroundStyle(Self.secondaryLime)
                        }
                        Text("啟動相機後，預覽會顯示在這裡")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                        if showsStartButton {
                            Button {
                                Task { await model.startCamera() }
                            } label: {
                                Label(Self.viewIntent.startLabel, systemImage: "camera.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(minWidth: 150, minHeight: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Self.primaryGreen)
                            .accessibilityLabel(Self.viewIntent.startLabel)
                            .accessibilityHint("重新啟動目前會員的相機預覽")
                        }
                    }
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(24)
                }

                Ellipse()
                    .stroke(Self.secondaryLime.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .frame(
                        width: min(proxy.size.width * 0.68, 320),
                        height: min(proxy.size.height * 0.64, 390)
                    )
                    .allowsHitTesting(false)

                VStack {
                    HStack {
                        Label(stateCopy, systemImage: model.state == .ready ? "checkmark.circle" : "camera")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.55), in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)

                VStack {
                    Spacer()
                    HStack {
                        Label(
                            model.selectedMemberID ?? "尚未套用 ID",
                            systemImage: "person.crop.circle"
                        )
                        .lineLimit(1)
                        Spacer(minLength: 12)
                        Text("已收集 \(model.selectedSampleCount) 個樣本")
                            .font(.caption.weight(.bold).monospacedDigit())
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.62), in: Capsule())
                }
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
        .frame(height: 420)
        .accessibilityElement(children: .contain)
    }

    private var captureContext: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedMemberID ?? "尚未選擇會員")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("已收集 \(model.selectedSampleCount) 個樣本｜\(Self.viewIntent.sampleGuidance)")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.62))
                }
                Spacer(minLength: 8)
                Button(Self.viewIntent.changeMemberLabel) {
                    Task { await changeMember() }
                }
                .buttonStyle(.bordered)
                .tint(Self.secondaryLime)
                .frame(minHeight: 44)
            }

            HStack(spacing: 8) {
                Label(
                    stateCopy,
                    systemImage: model.state == .ready ? "checkmark.circle.fill" : "camera"
                )
                .font(.footnote.weight(.semibold))
                if model.state == .ready, model.previewFrame != nil {
                    Text("LIVE PREVIEW")
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                        .foregroundStyle(Self.secondaryLime)
                }
            }
            .foregroundStyle(.white.opacity(0.8))

            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Self.secondaryLime)
            }

            if let photoPickerFailureMessage {
                Text(photoPickerFailureMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Self.secondaryLime)
            }

            Button("清除目前會員樣本", role: .destructive) {
                model.requestReset()
                isResetDialogPresented = model.isResetConfirmationPresented
            }
            .disabled(model.selectedMemberID == nil)
            .frame(minHeight: 44)
            .accessibilityHint("只刪除目前會員的校準樣本")
        }
        .padding(16)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var captureDeck: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("校準模式", selection: $captureMode) {
                Text(Self.viewIntent.enrollmentLabel)
                    .tag(CaptureMode.enrollment)
                Text(Self.viewIntent.returnModeLabel)
                    .tag(CaptureMode.returnVisit)
            }
            .pickerStyle(.segmented)
            .tint(Self.primaryGreen)
            .accessibilityLabel("校準模式")

            ZStack {
                Button {
                    Task { await performCameraCapture() }
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(canCaptureCurrentMode ? Self.primaryGreen : .gray.opacity(0.45), in: Circle())
                }
                .disabled(!canCaptureCurrentMode)
                .accessibilityLabel(captureMode == .enrollment
                    ? "手動拍攝 enrollment 樣本"
                    : Self.viewIntent.shutterAccessibilityLabel.replacingOccurrences(of: "校準樣本", with: "回訪照片"))
                .accessibilityHint("手動拍攝，不會自動擷取")

                HStack {
                    Spacer()
                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .images,
                        preferredItemEncoding: .current
                    ) {
                        Label("相簿", systemImage: "photo.on.rectangle")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 72, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(Self.secondaryLime)
                    .disabled(!canImportCurrentMode)
                    .accessibilityLabel(captureMode == .enrollment
                        ? Self.viewIntent.enrollmentPhotoLabel
                        : Self.viewIntent.returnPhotoLabel)
                    .accessibilityHint(Self.viewIntent.photoFilesGuidance)
                    .accessibilityIdentifier(captureMode == .enrollment
                        ? Self.viewIntent.enrollmentPhotoAccessibilityIdentifier
                        : Self.viewIntent.returnPhotoAccessibilityIdentifier)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 76)

            Text(captureMode == .enrollment
                ? "手動快門會儲存一個 enrollment 樣本"
                : "手動快門會執行一次回訪分數測量")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.62))
                .accessibilityHidden(true)
        }
        .padding(16)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onChange(of: captureMode) { _, _ in
            selectedPhotoItem = nil
            photoPickerFailureMessage = nil
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            selectedPhotoItem = nil
            photoPickerFailureMessage = nil
            let mode = captureMode
            Task { await handlePhotoSelection(item, mode: mode) }
        }
    }

    @ViewBuilder
    private var evidenceCard: some View {
        if let evidence = model.scoreEvidence {
            VStack(alignment: .leading, spacing: 8) {
                Text("分數證據")
                    .font(.headline)
                    .foregroundStyle(.white)
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
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.white.opacity(0.78))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("分數證據，gallery samples \(evidence.gallerySampleCount)")
        }
    }

    private func confirmMemberAndStartCamera() async {
        isMemberIDFocused = false
        photoPickerFailureMessage = nil
        guard await model.confirmMemberAndStartCamera() else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            flowStep = .capture
        }
    }

    private func changeMember() async {
        await model.stopCamera()
        captureMode = .enrollment
        selectedPhotoItem = nil
        photoPickerFailureMessage = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            flowStep = .memberSetup
        }
        isMemberIDFocused = true
    }

    private func performCameraCapture() async {
        switch Self.captureAction(for: captureMode, source: .shutter) {
        case .captureEnrollment:
            await model.captureEnrollment()
        case .captureReturnVisit:
            await model.captureReturnVisit()
        case .captureEnrollmentPhoto, .captureReturnVisitPhoto:
            break
        }
    }

    private func handlePhotoSelection(
        _ item: PhotosPickerItem,
        mode: CaptureMode
    ) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PhotoSelectionError.missingData
            }
            switch Self.captureAction(for: mode, source: .photo) {
            case .captureEnrollmentPhoto:
                await model.captureEnrollmentPhoto(from: data)
            case .captureReturnVisitPhoto:
                await model.captureReturnVisitPhoto(from: data)
            case .captureEnrollment, .captureReturnVisit:
                break
            }
        } catch {
            photoPickerFailureMessage = Self.photoPickerFailureMessage
        }
    }
}

private enum PhotoSelectionError: Error {
    case missingData
}

#endif
