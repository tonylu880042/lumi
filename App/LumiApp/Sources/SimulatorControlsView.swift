import SwiftUI
import LumiDomain
import LumiPresentation

enum SimulatorControlMode: String, CaseIterable, Identifiable {
    case session
    case avatar

    var id: Self { self }

    var label: String {
        switch self {
        case .session:
            "工作階段"
        case .avatar:
            "Avatar 調校"
        }
    }
}

/// Session voice actions exposed by the Simulator overlay. The four
/// artificial lifecycle actions are available only when the injected model
/// owns deterministic Mock voice controls.
enum SimulatorVoiceControl: String, CaseIterable, Identifiable, Equatable {
    case startVoice
    case userSpeechStarted
    case userSpeechEnded
    case responseReady
    case voiceFailure

    var id: Self { self }

    var label: String {
        switch self {
        case .startVoice:
            "啟動語音"
        case .userSpeechStarted:
            "模擬使用者開始說話"
        case .userSpeechEnded:
            "模擬使用者說完"
        case .responseReady:
            "模擬回覆就緒"
        case .voiceFailure:
            "模擬語音失敗"
        }
    }

    func accessibilityHint(hasArtificialVoiceControls: Bool) -> String {
        switch self {
        case .startVoice:
            hasArtificialVoiceControls ? "啟動模擬語音工作階段" : "啟動語音工作階段"
        case .userSpeechStarted:
            "送出使用者開始說話事件"
        case .userSpeechEnded:
            "送出使用者說話結束事件"
        case .responseReady:
            "送出模擬回覆完成事件"
        case .voiceFailure:
            "保留目前狀態並顯示可重試提示"
        }
    }
}

enum SimulatorControlCatalog {
    static let tuningStates: [(label: String, state: AssistantState)] = [
        ("idle", .idle),
        ("detected(left)", .detected(direction: .left)),
        ("detected(center)", .detected(direction: .center)),
        ("detected(right)", .detected(direction: .right)),
        ("rotating", .rotating),
        ("recognizing", .recognizing),
        ("greeting", .greeting),
        ("listening", .listening),
        ("thinking", .thinking),
        ("speaking", .speaking),
        ("encouraging", .encouraging),
        ("reminding", .reminding),
        ("confused", .confused),
        ("offline", .offline),
    ]

    static let events: [(label: String, event: AssistantEvent)] = [
        ("playful", .playful),
        ("memberRecognized", .memberRecognized),
        ("firstVisit", .firstVisit),
        ("longTimeNoSee", .longTimeNoSee),
        ("goalAchieved", .goalAchieved),
        ("weeklyGoalCompleted", .weeklyGoalCompleted),
        ("error", .error),
    ]

    /// Derives the rendered voice-control catalog from the actual model
    /// capability. The view below consumes this exact descriptor list, so Live
    /// has no artificial buttons in its hierarchy rather than merely disabling
    /// them.
    @MainActor
    static func voiceControls(
        for simulationModel: SessionSimulationModel
    ) -> [SimulatorVoiceControl] {
        var controls: [SimulatorVoiceControl] = [.startVoice]
        if simulationModel.hasArtificialVoiceControls {
            controls.append(contentsOf: [
                .userSpeechStarted,
                .userSpeechEnded,
                .responseReady,
                .voiceFailure
            ])
        }
        return controls
    }
}

/// Overlay-only debug controls. It does not own session state or touch ports;
/// all Session actions go through the injected App-side model.
@MainActor
struct SimulatorControlsView: View {
    @ObservedObject private var simulationModel: SessionSimulationModel

    @Binding private var controlsExpanded: Bool
    @Binding private var controlsMode: SimulatorControlMode
    @Binding private var direction: PresenceDirection
    @Binding private var identityChoice: SessionSimulationModel.VisitorIdentityChoice
    @Binding private var conversationDirectionChoice: SessionSimulationModel.ConversationDirectionChoice
    @Binding private var tuningSelection: Int
    @Binding private var eventSelection: Int
    @Binding private var triggeredEvent: AvatarEventCommand?
    @Binding private var cancelEvent: Bool
    @Binding private var rawAmplitude: Double
    @Binding private var processedAmplitude: Double

    private let eventMapper = AvatarEventCommandMapper()

    init(
        simulationModel: SessionSimulationModel,
        controlsExpanded: Binding<Bool>,
        controlsMode: Binding<SimulatorControlMode>,
        direction: Binding<PresenceDirection>,
        identityChoice: Binding<SessionSimulationModel.VisitorIdentityChoice>,
        conversationDirectionChoice: Binding<SessionSimulationModel.ConversationDirectionChoice>,
        tuningSelection: Binding<Int>,
        eventSelection: Binding<Int>,
        triggeredEvent: Binding<AvatarEventCommand?>,
        cancelEvent: Binding<Bool>,
        rawAmplitude: Binding<Double>,
        processedAmplitude: Binding<Double>
    ) {
        self._simulationModel = ObservedObject(wrappedValue: simulationModel)
        self._controlsExpanded = controlsExpanded
        self._controlsMode = controlsMode
        self._direction = direction
        self._identityChoice = identityChoice
        self._conversationDirectionChoice = conversationDirectionChoice
        self._tuningSelection = tuningSelection
        self._eventSelection = eventSelection
        self._triggeredEvent = triggeredEvent
        self._cancelEvent = cancelEvent
        self._rawAmplitude = rawAmplitude
        self._processedAmplitude = processedAmplitude
    }

    var body: some View {
        if controlsExpanded {
            expandedControls
        } else {
            Button {
                controlsExpanded = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("顯示開發控制項")
            .accessibilityHint("開啟工作階段與 Avatar 調校控制")
            .padding(12)
        }
    }

    private var expandedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("控制項")
                    .font(.headline)

                Spacer()

                Button {
                    controlsExpanded = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("隱藏開發控制項")
            }

            Picker("控制模式", selection: $controlsMode) {
                ForEach(SimulatorControlMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("開發控制模式")

            if controlsMode == .session {
                ScrollView(.vertical) {
                    sessionControls
                }
                .frame(maxHeight: 640)
            } else {
                avatarControls
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(12)
        .accessibilityElement(children: .contain)
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("工作階段模擬")
                .font(.subheadline.weight(.semibold))

            Text("目前狀態：\(stateLabel(simulationModel.assistantState))")
                .font(.caption)
                .accessibilityLabel(
                    "目前工作階段狀態：\(stateLabel(simulationModel.assistantState))"
                )

            Picker("來訪方向", selection: $direction) {
                ForEach(PresenceDirection.allCases, id: \.self) { direction in
                    Text(directionLabel(direction)).tag(direction)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!simulationModel.canChooseDirection)
            .accessibilityLabel("來訪方向")

            Button("確認來訪者") {
                simulationModel.confirm(direction: direction)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!simulationModel.canConfirmPresence)
            .accessibilityLabel("確認來訪者")
            .accessibilityHint("確認選定的來訪方向")

            Button("開始轉向") {
                simulationModel.begin()
            }
            .buttonStyle(.bordered)
            .disabled(!simulationModel.canBeginRotation)
            .accessibilityLabel("開始轉向")
            .accessibilityHint("開始轉向並等待模擬抵達")

            Button("完成轉向") {
                simulationModel.completeArrival()
            }
            .buttonStyle(.bordered)
            .disabled(!simulationModel.canCompleteRotation)
            .accessibilityLabel("完成轉向")
            .accessibilityHint("確認模擬硬體已抵達目標位置")

            if simulationModel.hasManualIdentityControls {
                Picker("訪客身分", selection: $identityChoice) {
                    ForEach(SessionSimulationModel.VisitorIdentityChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!simulationModel.canResolveVisitor)
                .accessibilityLabel("訪客身分")
                .accessibilityHint("選擇要完成的模擬身分結果")

                Button("確認訪客身分") {
                    simulationModel.resolveVisitor(identityChoice)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!simulationModel.canResolveVisitor)
                .accessibilityLabel("確認訪客身分")
                .accessibilityHint("完成選定的模擬身分結果")
            } else {
                Button("辨識目前訪客") {
                    simulationModel.recognizeVisitor()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!simulationModel.canResolveVisitor)
                .accessibilityLabel("辨識目前訪客")
                .accessibilityHint("拍攝三次新觀察並套用 44B pilot 判定")
            }

#if DEBUG && LUMI_LIVE
            Picker("對話方向", selection: $conversationDirectionChoice) {
                ForEach(SessionSimulationModel.ConversationDirectionChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!simulationModel.canStartVoiceSession)
            .accessibilityLabel("對話方向")
            .accessibilityHint("選擇下一次語音互動的方向")
#endif

            ForEach(SimulatorControlCatalog.voiceControls(for: simulationModel)) { control in
                voiceControlButton(control)
            }

            Button("模擬逾時") {
                simulationModel.endSession(cause: .timeout)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!simulationModel.canEndSession)
            .accessibilityLabel("模擬逾時")
            .accessibilityHint("結束工作階段並等待回到原位")

            Button("模擬訪客離開") {
                simulationModel.endSession(cause: .visitorLeft)
            }
            .buttonStyle(.bordered)
            .disabled(!simulationModel.canEndSession)
            .accessibilityLabel("模擬訪客離開")
            .accessibilityHint("結束工作階段並等待回到原位")

            if simulationModel.canCompleteReturnHome {
                Button("完成回到原位") {
                    simulationModel.completeReturnHome()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("完成回到原位")
                .accessibilityHint("確認模擬硬體已抵達原位")

                Button("模擬回到原位失敗") {
                    simulationModel.failReturnHome()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("模擬回到原位失敗")
                .accessibilityHint("保留工作階段狀態並顯示可重試提示")
            }

            if let visitorGreeting = simulationModel.visitorGreeting {
                Text(visitorGreeting)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("訪客問候：\(visitorGreeting)")
            }

            if let pendingAction = simulationModel.pendingAction {
                Text(pendingAction.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("進行中的動作：\(pendingAction.label)")
            }

            if let errorMessage = simulationModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("錯誤：\(errorMessage)")
            }
        }
    }

    @ViewBuilder
    private func voiceControlButton(
        _ control: SimulatorVoiceControl
    ) -> some View {
        switch control {
        case .startVoice:
            Button(control.label) {
                simulationModel.startVoiceSession(direction: conversationDirectionChoice)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!simulationModel.canStartVoiceSession)
            .accessibilityLabel(control.label)
            .accessibilityHint(
                control.accessibilityHint(
                    hasArtificialVoiceControls: simulationModel.hasArtificialVoiceControls
                )
            )
        case .userSpeechStarted:
            Button(control.label) {
                simulationModel.simulateUserSpeechStarted()
            }
            .buttonStyle(.bordered)
            .disabled(!simulationModel.canSimulateUserSpeechStarted)
            .accessibilityLabel(control.label)
            .accessibilityHint(
                control.accessibilityHint(
                    hasArtificialVoiceControls: simulationModel.hasArtificialVoiceControls
                )
            )
        case .userSpeechEnded:
            Button(control.label) {
                simulationModel.simulateUserSpeechEnded()
            }
            .buttonStyle(.bordered)
            .disabled(!simulationModel.canSimulateUserSpeechEnded)
            .accessibilityLabel(control.label)
            .accessibilityHint(
                control.accessibilityHint(
                    hasArtificialVoiceControls: simulationModel.hasArtificialVoiceControls
                )
            )
        case .responseReady:
            Button(control.label) {
                simulationModel.simulateResponseReady()
            }
            .buttonStyle(.bordered)
            .disabled(!simulationModel.canSimulateResponseReady)
            .accessibilityLabel(control.label)
            .accessibilityHint(
                control.accessibilityHint(
                    hasArtificialVoiceControls: simulationModel.hasArtificialVoiceControls
                )
            )
        case .voiceFailure:
            Button(control.label) {
                simulationModel.simulateVoiceFailure()
            }
            .buttonStyle(.bordered)
            .disabled(!simulationModel.canSimulateVoiceFailure)
            .accessibilityLabel(control.label)
            .accessibilityHint(
                control.accessibilityHint(
                    hasArtificialVoiceControls: simulationModel.hasArtificialVoiceControls
                )
            )
        }
    }

    private var avatarControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Avatar tuning")
                .font(.subheadline.weight(.semibold))

            Picker("State", selection: $tuningSelection) {
                ForEach(Array(SimulatorControlCatalog.tuningStates.enumerated()), id: \.offset) { index, item in
                    Text(item.label).tag(index)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Avatar tuning state")

            HStack(spacing: 8) {
                Picker("Event", selection: $eventSelection) {
                    ForEach(Array(SimulatorControlCatalog.events.enumerated()), id: \.offset) { index, item in
                        Text(item.label).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Avatar event")

                Button("Trigger") {
                    triggeredEvent = eventMapper.map(SimulatorControlCatalog.events[eventSelection].event)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Trigger avatar event")

                Button("Cancel") {
                    cancelEvent = true
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel avatar event")
            }

            Text(
                "Amplitude raw: \(rawAmplitude, specifier: "%.2f") · processed: \(processedAmplitude, specifier: "%.2f")"
            )
            .font(.caption)

            Slider(value: $rawAmplitude, in: 0 ... 1)
                .accessibilityLabel("Raw amplitude")
                .accessibilityValue("\(rawAmplitude, specifier: "%.2f")")
        }
    }

    private func directionLabel(_ direction: PresenceDirection) -> String {
        switch direction {
        case .left:
            "左"
        case .center:
            "中"
        case .right:
            "右"
        }
    }

    private func stateLabel(_ state: AssistantState) -> String {
        switch state {
        case .idle:
            "閒置"
        case .detected(let direction):
            "已偵測（\(directionLabel(direction))）"
        case .rotating:
            "轉向中"
        case .recognizing:
            "辨識中"
        case .greeting:
            "問候"
        case .listening:
            "聆聽中"
        case .thinking:
            "思考中"
        case .speaking:
            "說話中"
        case .encouraging:
            "鼓勵中"
        case .reminding:
            "提醒中"
        case .confused:
            "困惑"
        case .offline:
            "離線"
        }
    }
}
