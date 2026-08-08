import AppKit
import CoreImage
import Darwin
import SwiftUI
import UniformTypeIdentifiers

struct AhaKeyStudioView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager
    @StateObject private var voiceRelay = VoiceRelayService.shared
    @StateObject private var nativeSpeech = NativeSpeechTranscriptionService.shared
    @StateObject private var ahaType = AhaTypeTextOptimizer.shared
    @StateObject private var cloudAccount = CloudAccountManager.shared
    @StateObject private var agentManager = AgentManager.shared

    @State private var studioDraft: AhaKeyStudioDraft
    @State private var lastSyncedDraft: AhaKeyStudioDraft
    @State private var selectedMode: AhaKeyModeSlot
    @State private var selectedPart: AhaKeyStudioPart
    @State private var lightBarPreview: IDEState
    @State private var modeCustomNames: [Int: String] = [:]
    @State private var lastSyncDate: Date?
    @State private var syncStatusMessage = "변경 사항은 먼저 로컬에 저장되며, 기기를 연결한 뒤 동기화됩니다."
    @State private var isSyncing = false
    // AhaKeyStudio가 블루투스를 에이전트에 반환하는 전환 구간: 에이전트가 인수하거나 타임아웃될 때까지 "연결됨" 표시를 유지한다.
    @State private var isTransitioningToKeyboardControl = false
    @State private var showsOLEDPlaybackPreview = false
    @State private var showsDeviceInfo = false
    @State private var showsCloudAccount = false
    @State private var showsAhaTypeLoginRequiredToast = false
    @AppStorage(UnifiedOnboardingStorage.completedKey) private var unifiedOnboardingCompleted = false
    @State private var isEditingInspector = false
    @State private var showsDiagnostics = false
    @State private var showsKeyHelp = false
    @State private var selectedTriggerTab: Int = 0
    /// 메인 App이 BLE 연결을 직접 점유하는 데 성공할 때마다 기본 LCD 자동 동기화를 한 번만 실행한다.
    /// .onChange(of: isConnected)에서 연결이 끊기면 초기화하고, 다음 재연결 때 다시 한 번 트리거한다.
    @State private var oledAutoSyncDoneForConnection: Bool = false
    @State private var showsHelpCenter = false
    @State private var showsGuidanceDetail = false
    @State private var editingModeSlot: AhaKeyModeSlot?
    @State private var editingModeName: String = ""
    @FocusState private var modeNameFieldFocused: Bool
    @State private var showsWriteResultAlert = false
    @State private var writeResultAlertMessage = ""

    init(bleManager: AhaKeyBLEManager) {
        self.bleManager = bleManager
        let initialDraft = AhaKeyStudioStore.load() ?? .default
        // 주의: 여기서 VoiceRelayService.updateRoutes를 호출하지 말 것 —— SwiftUI는 bleManager의
        // @Published 속성(workMode/배터리/연결 상태 등) 때문에 view를 자주 다시 만들고, init도 여러 번 실행된다.
        // init 안에서 updateRoutes를 호출하면 functionRelay의 holdingRoute(누르고 있는 상태)가 초기화되어,
        // 위챗 등의 "누른 채 말하기"가 몇 초 뒤 자동으로 끝난다. 올바른 진입점은 아래의 .onAppear다.
        _studioDraft = State(initialValue: initialDraft)
        _lastSyncedDraft = State(initialValue: initialDraft)
        let initialMode = AhaKeyModeSlot(rawValue: bleManager.workMode) ?? .mode0
        _selectedMode = State(initialValue: initialMode)
        _selectedPart = State(initialValue: .key1)
        _lightBarPreview = State(initialValue: .preToolUse)
        _modeCustomNames = State(initialValue: AhaKeyModeNameStore.load())
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                canvasPane
                Divider()
                inspectorPane
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 1180, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            agentManager.applyStoredBluetoothPreferenceOnLaunch(bleManager: bleManager)
            voiceRelay.start()
            nativeSpeech.start()
            bleManager.refreshBluetoothAuthorization()
            applyCursorRejectMacroSelfHealIfNeeded()
            voiceRelay.updateRoutes(from: studioDraft)
            SwitchStateNotifier.shared.bind(to: bleManager)
            NotificationCenter.default.post(
                name: .ahaKeyKeyboardWorkModeChanged,
                object: nil,
                userInfo: ["workMode": bleManager.workMode]
            )
            scheduleStartupPermissionOnboarding()
        }
        .onChange(of: studioDraft) { newValue in
            AhaKeyStudioStore.save(newValue)
            voiceRelay.updateRoutes(from: newValue)
        }
        // 키보드 물리 단계 변경(BLE 조회/알림 보고) → 해당 Mode 탭으로 자동 전환한다.
        // 이렇게 해야 LCD 미리보기, 단축키 초안, 전송되는 updateState 세 가지가 일치한다.
        .onChange(of: bleManager.workMode) { newValue in
            if let slot = AhaKeyModeSlot(rawValue: newValue), slot != selectedMode {
                selectedMode = slot
            }
        }
        .onChange(of: selectedMode) { newValue in
            guard bleManager.isConnected,
                  bleManager.commandCharReady,
                  bleManager.workMode != newValue.rawValue else { return }
            bleManager.setWorkMode(UInt8(newValue.rawValue))
            syncStatusMessage = "키보드를 \(newValue.title)(으)로 전환하도록 알렸습니다."
        }
        .onChange(of: bleManager.isConnected) { connected in
            if !connected { oledAutoSyncDoneForConnection = false }
        }
        .onChange(of: bleManager.keyboardPictureStates) { _ in
            guard !oledAutoSyncDoneForConnection else { return }
            // 네 개 mode 모두 조회 결과가 돌아온 뒤에 진행한다
            guard bleManager.keyboardPictureStates.count == AhaKeyModeSlot.allCases.count else { return }
            oledAutoSyncDoneForConnection = true
            Task { await autoSyncDefaultOLEDsIfNeeded() }
        }
        .onChange(of: bleManager.bluetoothPermissionGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: bleManager.bluetoothPoweredOn) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: voiceRelay.inputMonitoringGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: voiceRelay.accessibilityGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: nativeSpeech.microphoneGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: nativeSpeech.speechRecognitionGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: nativeSpeech.siriEnabled) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: nativeSpeech.dictationEnabled) { _ in
            refreshStartupPermissionOnboarding()
        }
        .alert("Agent", isPresented: Binding(
            get: { agentManager.agentUserAlert != nil },
            set: { if !$0 { agentManager.agentUserAlert = nil } }
        )) {
            Button("확인", role: .cancel) {
                agentManager.agentUserAlert = nil
            }
        } message: {
            Text(agentManager.agentUserAlert ?? "")
        }
        .alert("AhaType 미가입 · 미로그인", isPresented: $showsAhaTypeLoginRequiredToast) {
            Button("알겠습니다", role: .cancel) {}
            Button("가입 · 로그인") {
                showsCloudAccount = true
            }
        } message: {
            Text("먼저 AhaType에 가입하고 로그인한 뒤 클라우드 정리를 켜 주세요.")
        }
        .sheet(isPresented: $showsOLEDPlaybackPreview) {
            OLEDMotionPreviewSheet(
                modeTitle: selectedMode.title,
                assetPath: currentModeDraft.oled.localAssetPath
            )
        }
        .sheet(isPresented: $showsDeviceInfo) {
            DeviceInfoSheetContainer(bleManager: bleManager)
                .frame(width: 720, height: 720)
        }
        .sheet(isPresented: $showsCloudAccount) {
            CloudAccountView()
                .frame(width: 520, height: 620)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text("AhaKey Studio")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
            }
            .layoutPriority(1)

            HStack(spacing: 8) {
                infoPill(
                    title: isEffectivelyConnected ? "연결됨" : (bleManager.isScanning ? "검색 중" : "연결 안 됨"),
                    subtitle: bleManager.deviceName ?? "기기 대기 중",
                    accent: isEffectivelyConnected ? .green : .orange,
                    width: 118
                )
                infoPill(
                    title: "배터리",
                    subtitle: isEffectivelyConnected ? "\(bleManager.batteryLevel)%" : "—",
                    accent: .blue
                )
                infoPill(
                    title: "레버",
                    subtitle: currentSwitchTitle,
                    accent: currentSwitchTitle == "자동 승인" ? .mint : .indigo
                )
            }
            .layoutPriority(2)

            Spacer(minLength: 0)

            if !bleManager.isConnected, agentManager.bluetoothConnectionOwner == .ahaKeyStudio {
                Button(bleManager.isScanning ? "검색 중…" : "기기 연결") {
                    bleManager.userInitiatedConnect()
                }
                .buttonStyle(.bordered)
                .disabled(bleManager.isScanning)
            }

            ahaTypeModeStatus

            configurationModeStatus

            if shouldShowTopBarInstallStartButton {
                Button("설치 후 시작") {
                    installStartAgentFromTopBar()
                }
                .buttonStyle(.borderedProminent)
                .disabled(agentManager.isAgentOperationInProgress)
                .help("에이전트와 훅을 설치/복구하고, 에이전트를 시작해 키보드를 제어합니다.")
            }

            Button {
                NSPasteboard.general.clearContents()
            } label: {
                Image(systemName: "arrow.counterclockwise.circle")
                    .imageScale(.medium)
            }
            .buttonStyle(.bordered)
            .help("클립보드 비우기")

            Menu {
                Button("현재 모드 기본값 복원") {
                    restoreCurrentModeDefaults()
                }
                Button("기기 재연결") {
                    bleManager.disconnect()
                    bleManager.userInitiatedConnect()
                }
                Button("기기 정보 · 에이전트…") {
                    showsDeviceInfo = true
                }
                Divider()
                Button("클라우드 계정 · AhaType…") {
                    showsCloudAccount = true
                }
                Button("AhaType 상태 새로 고침") {
                    ahaType.refreshFromDisk()
                }
                Divider()
                Button("백그라운드로 숨기기") {
                    NSApp.keyWindow?.close()
                }
                Button("AhaKey Studio 종료") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32, height: 28)
            .help("더 보기")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(chromeBarBackground)
    }

    private var configurationModeStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isEditingConfiguration ? Color.blue : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(isEditingConfiguration ? "설정 편집 중" : "키보드 제어 중")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(configurationModeDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: 138, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .help("평소에는 에이전트가 키보드를 제어합니다. 키 변경, LCD, 동기화가 필요할 때는 설정 편집에 들어가 AhaKey Studio가 블루투스를 임시로 인수합니다.")
    }

    private var ahaTypeModeStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ahaType.isEnabled ? Color.green : Color.gray.opacity(0.55))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(ahaType.isEnabled ? "AhaType 켜짐" : "AhaType 꺼짐")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(ahaType.isEnabled ? "클라우드 정리 사용 중" : "음성 결과 바로 붙여넣기")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Toggle("", isOn: Binding(
                get: { ahaType.isEnabled },
                set: { enabled in
                    if enabled, !cloudAccount.isLoggedIn {
                        showsAhaTypeLoginRequiredToast = true
                    } else {
                        ahaType.setEnabled(enabled)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .frame(width: 150, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .help("켜면 macOS 기본 음성 전사 결과가 AhaType 클라우드 정리를 거친 뒤 현재 커서 위치에 붙여넣어집니다.")
    }

    private var canvasPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            modeEditorHeader

            VStack(alignment: .leading, spacing: 8) {
                AhaKeyKeyboardCanvasView(
                    modeDraft: currentModeDraft,
                    selectedPart: selectedPart,
                    lightBarPreview: lightBarPreview,
                    switchTitle: currentSwitchTitle,
                    dirtyParts: dirtyPartsForCurrentMode(),
                    onSelect: { selectedPart = $0 },
                    onModeSwitch: { cycleModeForward() },
                    onSwitchToggle: { toggleVirtualSwitch() },
                    liveLightMode: liveCanvasLightMode,
                    liveIDEStateValue: liveCanvasIDEStateValue,
                    switchState: liveCanvasSwitchState,
                    keyboardPictureFrameCount: bleManager.keyboardPictureStates[selectedMode.rawValue]?.frameCount
                )
                .aspectRatio(109.0 / 54.0, contentMode: .fit)
                .frame(maxWidth: .infinity)

                Text("라이트바, 화면, 네 개의 키 또는 레버를 누르면 해당 설정으로 이동합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func modeTabItem(_ mode: AhaKeyModeSlot) -> some View {
        let isSelected = selectedMode == mode
        let isEditing = editingModeSlot == mode

        if isEditing {
            TextField("", text: $editingModeName, onCommit: { commitModeNameEdit() })
                .textFieldStyle(.plain)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .focused($modeNameFieldFocused)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(Color.accentColor.opacity(0.15))
                .onExitCommand { commitModeNameEdit() }
                .onAppear { modeNameFieldFocused = true }
                .onChange(of: modeNameFieldFocused) { focused in
                    if !focused { commitModeNameEdit() }
                }
        } else {
            Text(modeCustomNames[mode.rawValue] ?? mode.defaultName)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    commitModeNameEdit()
                    editingModeName = modeCustomNames[mode.rawValue] ?? mode.defaultName
                    editingModeSlot = mode
                    selectedMode = mode
                }
                .onTapGesture(count: 1) {
                    commitModeNameEdit()
                    selectedMode = mode
                }
        }
    }

    private func commitModeNameEdit() {
        guard let slot = editingModeSlot else { return }
        let capped = String(editingModeName.prefix(30))
        if capped.isEmpty || capped == slot.defaultName {
            modeCustomNames.removeValue(forKey: slot.rawValue)
        } else {
            modeCustomNames[slot.rawValue] = capped
        }
        AhaKeyModeNameStore.save(modeCustomNames)
        editingModeSlot = nil
    }

    private var modeEditorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Keyboard Mode")
                    .font(.system(size: 17, weight: .semibold))

                HStack(spacing: 0) {
                    ForEach(AhaKeyModeSlot.allCases) { mode in
                        modeTabItem(mode)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .frame(width: 480)

                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(selectedMode.guidance)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let detail = selectedMode.guidanceHoverDetail {
                    Button {
                        showsGuidanceDetail.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    .buttonStyle(.borderless)
                    .help(detail)
                    .onHover { showsGuidanceDetail = $0 }
                    .popover(isPresented: $showsGuidanceDetail, arrowEdge: .top) {
                        Text(detail)
                            .font(.callout)
                            .padding(14)
                            .frame(width: 320)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var inspectorPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isEditingInspector {
                        Label(selectedPart.title, systemImage: selectedPart.systemImage)
                            .font(.system(size: 18, weight: .semibold))

                        Group {
                            switch selectedPart {
                            case .key1, .key2, .key3, .key4: keyInspector
                            case .oledDisplay: oledInspector
                            case .lightBar: lightBarInspector
                            case .toggleSwitch: switchInspector
                            }
                        }

                    } else {
                        inspectorHeader

                        VStack(alignment: .leading, spacing: 0) {
                            partSummaryContent
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.black.opacity(0.07), lineWidth: 1)
                                )
                        )

                        HStack {
                            Spacer()
                            Button {
                                enterEditingConfiguration()
                                withAnimation(.easeInOut(duration: 0.2)) { isEditingInspector = true }
                            } label: {
                                Label("수정", systemImage: "pencil")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .keyboardShortcut("e", modifiers: .command)
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(24)
            }

            if isEditingInspector {
                Divider()
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isEditingInspector = false
                            returnToKeyboardControl()
                        }
                    } label: {
                        Label("돌아가기", systemImage: "chevron.left")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer()

                    if selectedPart == .lightBar {
                        Button {
                            previewLightEffect(for: lightBarPreview)
                        } label: {
                            Label("키보드에서 미리보기", systemImage: "play.fill")
                                .font(.callout.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isSyncing || !bleManager.isConnected || !bleManager.commandCharReady)
                    }

                    Button {
                        writeToKeyboard()
                    } label: {
                        Label(isSyncing ? "기록 중…" : "키보드에 기록", systemImage: isSyncing ? "arrow.trianglehead.2.clockwise" : "square.and.arrow.down")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isSyncing || !bleManager.isConnected)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 390)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .onChange(of: selectedPart) { _ in
            commitModeNameEdit()
            withAnimation(.easeInOut(duration: 0.18)) { isEditingInspector = false }
        }
        .onChange(of: selectedMode) { _ in
            if editingModeSlot != nil && editingModeSlot != selectedMode {
                commitModeNameEdit()
            }
        }
        .alert("기록 결과", isPresented: $showsWriteResultAlert) {
            Button("계속 편집", role: .cancel) {}
            Button("편집 완료") {
                if writeResultAlertMessage.contains("성공") {
                    completeEditingAfterSuccessfulWrite()
                }
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(writeResultAlertMessage)
        }
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label(selectedPart.title, systemImage: selectedPart.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                if partIsDirty(selectedPart) {
                    Label("미동기화", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if selectedPart.isKey {
                    Button {
                        showsKeyHelp.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .imageScale(.medium)
                    }
                    .buttonStyle(.borderless)
                    .onHover { showsKeyHelp = $0 }
                    .popover(isPresented: $showsKeyHelp, arrowEdge: .leading) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("사용 방법")
                                .font(.headline)
                            Divider()
                            Text("1. 가상 키보드에서 해당 키를 클릭해 선택합니다.")
                            Text("2. 음성 키는 먼저 프리셋을 고르고, 다른 키는 필요에 따라 단일 키 또는 매크로를 고릅니다.")
                            Text("3. 설정을 마친 뒤 「키보드에 기록」을 눌러 키보드에 동기화합니다.")
                            Text("4. 모드를 바꿀 때 LCD가 먼저 설명을 표시한 뒤 해당 모드 애니메이션으로 돌아갑니다.")
                        }
                        .font(.callout)
                        .padding(16)
                        .frame(width: 270)
                    }
                }
            }
            Text(selectedPart.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 권한 진단 팝업

    private var diagnosticsSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("권한 진단")
                        .font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button("닫기") { showsDiagnostics = false }
                        .buttonStyle(.bordered)
                }

                GroupBox("백그라운드 음성 브리지") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(voiceRelay.isListening ? Color.green : Color.orange)
                                .frame(width: 10, height: 10)
                            Text(voiceRelay.isListening ? "백그라운드 감시 중" : "시스템 권한 대기 중")
                                .font(.callout.weight(.semibold))
                            Spacer()
                        }
                        HStack(spacing: 10) {
                            permissionBadge(title: "입력 모니터링", granted: voiceRelay.inputMonitoringGranted)
                            permissionBadge(title: "손쉬운 사용", granted: voiceRelay.accessibilityGranted)
                        }
                        Text(voiceRelay.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(voiceRelay.lastPermissionCheckSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(voiceRelay.activeRouteSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("권한 다시 요청") {
                                requestPermissionsThenOpenPrivacySettingsIfNeeded(
                                    bleManager: bleManager,
                                    voiceRelay: voiceRelay,
                                    nativeSpeech: nativeSpeech
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            Button("권한 다시 확인") {
                                voiceRelay.refreshPermissions(deferredTCCRequery: true)
                            }
                            .buttonStyle(.bordered)
                            RestartToApplyPermissionsButton()
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox("Apple 기본 음성 전사") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(nativeSpeech.isRecording ? Color.red : (nativeSpeech.microphoneGranted && nativeSpeech.speechRecognitionGranted ? Color.green : Color.orange))
                                .frame(width: 10, height: 10)
                            Text(nativeSpeech.isRecording ? "녹음 전사 중" : "트리거 대기 중")
                                .font(.callout.weight(.semibold))
                            Spacer()
                        }
                        HStack(spacing: 10) {
                            permissionBadge(title: "마이크", granted: nativeSpeech.microphoneGranted)
                            permissionBadge(title: "음성 전사", granted: nativeSpeech.speechRecognitionGranted)
                            permissionBadge(title: "Siri", granted: nativeSpeech.siriEnabled)
                            permissionBadge(title: "받아쓰기", granted: nativeSpeech.dictationEnabled)
                        }
                        Text(nativeSpeech.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(nativeSpeech.lastPermissionCheckSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()

                        HStack(spacing: 10) {
                            Circle()
                                .fill(nativeSpeech.isRecording ? Color.red : Color.clear)
                                .frame(width: 8, height: 8)
                            Text(nativeSpeech.isRecording ? "녹음 중" : "전사 테스트")
                                .font(.callout.weight(.semibold))
                            Spacer()
                            if !nativeSpeech.transcriptPreview.isEmpty {
                                Text(nativeSpeech.transcriptPreview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else if !nativeSpeech.lastCommittedText.isEmpty {
                                Text("최근 입력: \(nativeSpeech.lastCommittedText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        HStack(spacing: 8) {
                            Button(nativeSpeech.isRecording ? "종료 후 입력" : "녹음 시작") {
                                nativeSpeech.toggleRecordingFromVoiceKey()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("권한 다시 확인") {
                                nativeSpeech.refreshPermissions(deferredTCCRequery: true)
                            }
                            .buttonStyle(.bordered)
                            RestartToApplyPermissionsButton()
                            if !nativeSpeechPermissionsReady {
                                Button("시스템 설정 열기") { openNativeSpeechPrivacySettings() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                let voiceKey = currentModeDraft.key(for: .voice)
                if let preset = voiceKey.voicePreset, preset == .typeless {
                    GroupBox("Fn 음성 입력기") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Typeless / 위챗 음성 / 더우바오 입력기는 F19로 트리거하며 Fn 누름/해제를 주입합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("문제 해결은 voice-relay.log(matched · function relay · post fn)를 확인하세요. 경로: ~/Library/Application Support/AhaKeyConfig/diagnostics/")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Button("음성 키 한 번 누르기 시뮬레이션") {
                                voiceRelay.simulateInspectorVoiceKeyTap(for: selectedMode)
                            }
                            .buttonStyle(.borderedProminent)
                            if let hint = voiceRelay.lastInspectorSimulateHint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                GroupBox("AhaType 상태") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle(isOn: Binding(
                                get: { ahaType.isEnabled },
                                set: { ahaType.setEnabled($0) }
                            )) {
                                Text("AhaType 클라우드 정리")
                                    .font(.callout.weight(.semibold))
                            }
                            .toggleStyle(.switch)
                            Spacer()
                            Button("새로 고침") { ahaType.refreshFromDisk() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        Text(ahaType.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ahaType.lastQuotaSummary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .frame(width: 500, height: 620)
    }

    // MARK: - Inspector Level 1 Summary

    private func summaryRow(_ title: String, value: String, dot: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            HStack(spacing: 5) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 7, height: 7)
                        .offset(y: -1)
                }
                Text(value)
                    .font(.callout)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var partSummaryContent: some View {
        switch selectedPart {
        case .key1:          voiceKeySummary
        case .key2, .key3, .key4: actionKeySummary
        case .oledDisplay:   oledSummary
        case .lightBar:      lightBarSummary
        case .toggleSwitch:  switchSummary
        }
    }

    @ViewBuilder
    private var voiceKeySummary: some View {
        let key = currentSelectedKey
        let preset = key.voicePreset ?? .custom
        summaryRow("입력 방식", value: preset.title)
        summaryRow("단축키", value: key.displaySummary)
        if preset.isMacOSNativeFamily {
            summaryRow("트리거 방식", value: "짧게 누르기 + 길게 누르기")
            let permCount = [nativeSpeech.microphoneGranted, nativeSpeech.speechRecognitionGranted,
                             nativeSpeech.siriEnabled, nativeSpeech.dictationEnabled].filter { $0 }.count
            summaryRow("전사 권한", value: "\(permCount)/4 승인됨",
                       dot: permCount == 4 ? .green : .orange)
        }
        summaryRow("음성 브리지", value: voiceRelay.isListening ? "실행 중" : "권한 대기 중",
                   dot: voiceRelay.isListening ? .green : .orange)
        summaryRow("키 설명", value: key.description.isEmpty ? "—" : key.description)
    }

    @ViewBuilder
    private var actionKeySummary: some View {
        let key = currentSelectedKey
        summaryRow("바인딩", value: key.displaySummary)
        summaryRow("유형", value: key.usesMacro ? "펌웨어 매크로(\(key.macro.count) 단계)" : "단일 키 / 조합 키")
        summaryRow("키 설명", value: key.description.isEmpty ? "—" : key.description)
    }

    @ViewBuilder
    private var oledSummary: some View {
        let oled = currentModeDraft.oled
        summaryRow("애니메이션", value: oled.localAssetPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "기본 애니메이션")
        summaryRow("재생 속도", value: "\(oled.framesPerSecond) FPS")
        summaryRow("상태 줄", value: oled.statusLine.isEmpty ? "—" : String(oled.statusLine.prefix(32)))
    }

    @ViewBuilder
    private var lightBarSummary: some View {
        let lb = currentModeDraft.lightBar
        ForEach(IDEState.allCases) { state in
            summaryRow(state.shortLabel, value: lb.effect(for: state).title)
        }
        summaryRow("밝기", value: "\(lb.brightness)%")
    }

    @ViewBuilder
    private var switchSummary: some View {
        let agentReady = agentManager.isInstalled && agentManager.isRunning && agentManager.hooksInstalled
        summaryRow("현재 단계", value: currentSwitchTitle,
                   dot: currentSwitchTitle == "자동 승인" ? .green : .indigo)
        summaryRow("Agent", value: agentReady ? "준비됨" : "준비 안 됨",
                   dot: agentReady ? .green : .orange)
        summaryRow("적용 범위", value: "Claude · Cursor · Codex · Kimi")
    }

    // MARK: - Inspector Level 2 Detail

    private var keyInspector: some View {
        let key = currentSelectedKey
        return VStack(alignment: .leading, spacing: 16) {
            GroupBox("키 설명") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("예: Record / Accept / Reject / Backspace", text: selectedKeyDescriptionBinding)
                        .textFieldStyle(.roundedBorder)
                    if currentSelectedKey.description.containsNonASCII {
                        Text("기기 LCD는 ASCII만 안정적으로 지원합니다. 한글·한자, emoji, 전각 문자는 기록할 때 자동으로 걸러져 깨진 문자를 막습니다.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("기기에 실제로 기록되는 값: \(currentSelectedKeySanitizedDescription.isEmpty ? "비어 있음" : currentSelectedKeySanitizedDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("키보드에 동기화한 뒤 실물 키를 짧게 눌러 모드를 바꾸면, LCD가 여기 입력한 설명을 잠시 표시한 다음 해당 모드 애니메이션으로 돌아갑니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if selectedMode == .mode0 {
                        Text("Mode 1 기본 문구: Record / Accept / Reject / Backspace")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }

            if key.role == .voice {
                GroupBox("음성 입력 방식") {
                    VStack(alignment: .leading, spacing: 12) {
                        VoicePresetPicker(
                            selectedPreset: key.voicePreset ?? .custom,
                            onSelect: applyVoicePreset
                        )
                        if (key.voicePreset ?? .custom).isMacOSNativeFamily {
                            Text("AhaKey Studio가 백그라운드에서 실행 중이면, Mode 1 공장 설정 음성 키가 보내는 F18을 Apple 기본 전사가 바로 인수합니다. 이제 시스템 받아쓰기 단축키에 의존하지 않습니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("음성 키의 입력 방식은 현재 Mode와 무관하며, 어떤 Mode에서도 동일한 음성 입력 설정을 사용할 수 있습니다.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                }
            } else {
                GroupBox("키 역할") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(key.role.manualText)
                            .font(.callout)
                        Text("현재 단축키와 키 설명을 함께 키보드에 기록합니다. 모드를 바꾸면 기기가 설명을 먼저 표시한 뒤 해당 모드의 LCD 애니메이션으로 돌아갑니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // ── 트리거 방식(짧게 누르기 / 길게 누르기 Tab)──────────────────────────────
            GroupBox("트리거 방식") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: $selectedTriggerTab) {
                        Text("짧게 누르기").tag(0)
                        Text("길게 누르기").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Divider()

                    if key.role == .voice {
                        // ── 음성 키 트리거 방식 ──────────────────────────────
                        if selectedTriggerTab == 0 {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("한 번 눌러 시작, 다시 눌러 종료", systemImage: "hand.tap.fill")
                                    .font(.callout.weight(.semibold))
                                Text("녹음이 끝나면 아래 스위치에 따라 AhaType 정리를 거칠지 결정한 뒤 커서 위치에 입력합니다.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Toggle(isOn: $nativeSpeech.shortPressAhaTypeEnabled) {
                                    HStack(spacing: 6) {
                                        Text("AhaType 정리 사용")
                                            .font(.callout)
                                        if !ahaType.isEnabled {
                                            Text("(AhaType 전체 스위치가 꺼져 있습니다)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.switch)
                                .disabled(!ahaType.isEnabled)

                                Divider()

                                // 바인딩 요약(짧게 누르기 = 음성 키 HID 바인딩)
                                HStack {
                                    Text(key.displaySummary)
                                        .font(.system(.callout, design: .rounded).weight(.semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(key.usesMacro ? "펌웨어 매크로" : "하위 레벨 HID")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Picker("", selection: selectedKeyBindingModeBinding) {
                                    Text("단일 키 / 조합 키").tag(KeyBindingMode.shortcut)
                                    Text("매크로").tag(KeyBindingMode.macro)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .disabled((key.voicePreset ?? .custom) != .custom)
                                if key.usesMacro {
                                    macroEditor(for: key)
                                } else {
                                    ShortcutBindingEditor(shortcut: selectedKeyShortcutBinding)
                                }
                                Text(voicePresetDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if (key.voicePreset ?? .custom) != .custom {
                                    Text("음성 키 프리셋은 단일 키 바인딩을 고정으로 사용합니다. 매크로를 기록하려면 먼저 프리셋을 사용자 지정 단축키로 바꿔 주세요.")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        } else {
                            // 길게 누르기 Tab(음성 키) — 항상 켜져 있으며, AhaType과 임계값만 설정한다
                            VStack(alignment: .leading, spacing: 10) {
                                Label("누른 채 녹음, 손을 떼면 전송", systemImage: "hand.draw.fill")
                                    .font(.callout.weight(.semibold))
                                Text("키보드 녹음 키를 누른 채 유지하면 녹음이 시작되고, 손을 떼면 ASR 결과를 바로 입력해 더 빠르게 반응합니다.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Toggle(isOn: $nativeSpeech.longPressAhaTypeEnabled) {
                                    HStack(spacing: 6) {
                                        Text("AhaType 정리 사용")
                                            .font(.callout)
                                        if !ahaType.isEnabled {
                                            Text("(AhaType 전체 스위치가 꺼져 있습니다)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.switch)
                                .disabled(!ahaType.isEnabled)
                                HStack(spacing: 10) {
                                    Text("트리거 임계값")
                                        .font(.callout)
                                    Slider(
                                        value: Binding(
                                            get: { Double(nativeSpeech.longPressThresholdMs) },
                                            set: { nativeSpeech.longPressThresholdMs = Int($0) }
                                        ),
                                        in: 200...1000,
                                        step: 50
                                    )
                                    Text("\(nativeSpeech.longPressThresholdMs) ms")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 58, alignment: .trailing)
                                }
                            }
                        }
                    } else {
                        // ── 일반 키 트리거 방식 ──────────────────────────────
                        if selectedTriggerTab == 0 {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(key.displaySummary)
                                        .font(.system(.callout, design: .rounded).weight(.semibold))
                                        .lineLimit(2)
                                    Spacer()
                                    Text(key.usesMacro ? "펌웨어 매크로" : "하위 레벨 HID")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Picker("", selection: selectedKeyBindingModeBinding) {
                                    Text("단일 키 / 조합 키").tag(KeyBindingMode.shortcut)
                                    Text("매크로").tag(KeyBindingMode.macro)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                if key.usesMacro {
                                    macroEditor(for: key)
                                } else {
                                    ShortcutBindingEditor(shortcut: selectedKeyShortcutBinding)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("펌웨어 v2 이상 필요", systemImage: "exclamationmark.triangle")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.orange)
                                Text("길게 누르기에 다른 단축키를 바인딩하는 기능은 펌웨어 업그레이드 후에 적용되며, 현재는 짧게 누르기 바인딩만 기기에 기록됩니다.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .onChange(of: selectedPart) { _ in selectedTriggerTab = 0 }

        }
    }

    // MARK: - 매크로 편집기 뷰

    @ViewBuilder
    private func macroEditor(for key: AhaKeyKeyDraft) -> some View {
        let stepCount = key.macro.count
        let byteCount = stepCount * 2
        let overLimit = byteCount > 98 // 펌웨어 payload 상한

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("단계(순차 실행)")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(stepCount) 단계 · \(byteCount) / 98 바이트")
                    .font(.caption)
                    .foregroundStyle(overLimit ? .red : .secondary)
            }

            if key.macro.isEmpty {
                Text("빈 매크로입니다. 아래 「단계 추가」를 눌러 기록을 시작하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(key.macro.enumerated()), id: \.element.id) { index, step in
                        macroStepRow(
                            index: index,
                            step: step,
                            totalCount: key.macro.count
                        )
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    appendMacroStep()
                } label: {
                    Label("단계 추가", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(overLimit)

                Button(role: .destructive) {
                    updateSelectedKey { $0.macro = [] }
                } label: {
                    Label("모두 지우기", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(key.macro.isEmpty)
            }

            if overLimit {
                Text("펌웨어 단일 키 매크로 상한인 98바이트 / 49단계를 넘어, 동기화할 때 거부됩니다.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("펌웨어는 순서대로 직렬 전송합니다. 지연 단위는 3ms(최대 765ms)입니다. 더 긴 지연이 필요하면 지연 단계를 여러 개 겹쳐 주세요.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !key.macro.isEmpty {
                Text("미리보기: \(key.macro.displaySummary)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func macroStepRow(index: Int, step: MacroStep, totalCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Picker("", selection: macroStepActionBinding(id: step.id)) {
                ForEach(MacroAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 96)

            if step.action.takesKeycodeParam {
                Picker("", selection: macroStepKeycodeBinding(id: step.id)) {
                    Text("설정 안 함").tag(UInt8(0))
                    ForEach(HIDUsage.allOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minWidth: 96)
            } else if step.action.takesDelayParam {
                // 제목이 있는 Stepper에 labelsHidden()을 쓰지 말 것. 「15 ms」까지 함께 숨겨진다.
                HStack(spacing: 8) {
                    Text("\(max(1, Int(step.param)) * 3) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(minWidth: 44, alignment: .trailing)
                    Stepper(
                        "",
                        value: macroStepDelayBinding(id: step.id),
                        in: 1...255
                    )
                    .labelsHidden()
                }
                .frame(minWidth: 120)
            } else {
                Color.clear.frame(minWidth: 96, maxHeight: 1)
            }

            Spacer(minLength: 0)

            Button {
                moveMacroStep(from: index, by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)

            Button {
                moveMacroStep(from: index, by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(index >= totalCount - 1)

            Button(role: .destructive) {
                removeMacroStep(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    private func macroStepActionBinding(id: UUID) -> Binding<MacroAction> {
        Binding(
            get: {
                currentSelectedKey.macro.first { $0.id == id }?.action ?? .noOp
            },
            set: { newAction in
                updateMacroStep(id: id) { step in
                    let previous = step.action
                    step.action = newAction
                    // 동작 분류가 바뀌면 param을 0으로 초기화해, "Enter의 HID 코드 0x28"을 지연 값 ×3ms로 해석하는 일을 막는다.
                    if previous.takesKeycodeParam != newAction.takesKeycodeParam
                        || previous.takesDelayParam != newAction.takesDelayParam
                    {
                        switch newAction {
                        case .delay:
                            step.param = 5 // 기본 15ms, 비교적 범용적이다
                        case .downKey, .upKey:
                            step.param = HIDUsage.enter
                        case .noOp, .upAllKeys:
                            step.param = 0
                        }
                    }
                }
            }
        )
    }

    private func macroStepKeycodeBinding(id: UUID) -> Binding<UInt8> {
        Binding(
            get: {
                currentSelectedKey.macro.first { $0.id == id }?.param ?? 0
            },
            set: { newValue in
                updateMacroStep(id: id) { $0.param = newValue }
            }
        )
    }

    private func macroStepDelayBinding(id: UUID) -> Binding<UInt8> {
        Binding(
            get: {
                currentSelectedKey.macro.first { $0.id == id }?.param ?? 0
            },
            set: { newValue in
                updateMacroStep(id: id) { $0.param = newValue }
            }
        )
    }

    private var oledInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("현재 모드의 LCD 애니메이션") {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.9))
                            .frame(height: 140)

                        if let image = currentOLEDPreviewImage {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 112)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "photo.artframe")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white.opacity(0.8))
                                Text("현재는 애니메이션만 지원합니다")
                                    .foregroundStyle(.white.opacity(0.85))
                                Text("텍스트, token, 모델 상태 표시는 개발 중입니다")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button("GIF 또는 이미지 선택") {
                            selectOLEDGIF()
                        }
                        .buttonStyle(.bordered)

                        Button("애니메이션 미리보기") {
                            showsOLEDPlaybackPreview = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(currentModeDraft.oled.localAssetPath == nil)

                        Button("비우기") {
                            clearCurrentOLED()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Text("현재 대상: \(selectedMode.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Stepper(value: oledFramesPerSecondBinding, in: 1 ... 30) {
                        Text("재생 속도 \(currentModeDraft.oled.framesPerSecond) FPS")
                    }

                    Text("고정 제한: 원본 파일 ≤ 2 MB, FPS 1–30, 모드당 최대 70프레임. Mode 1/2/3/4는 slot 10/80/150/220에 고정 기록됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(currentModeDraft.oled.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            GroupBox("표시 로직") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("현재 모드로 전환하면 LCD가 해당 모드의 키 설명을 먼저 표시하고, 약 1초 뒤 해당 모드 애니메이션으로 돌아갑니다.")
                    Text("앞으로 텍스트 상태, token 사용량, 모델 환경 등의 정보 표시 기능을 계속 추가할 예정입니다.")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var lightBarInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("상태 조명 효과 매핑") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(IDEState.workflowOrder) { state in
                        HStack {
                            Text(state.shortLabel)
                                .font(.callout.weight(.medium))
                                .frame(width: 80, alignment: .leading)
                            Picker("", selection: lightEffectBinding(for: state)) {
                                ForEach(LightEffectStyle.allCases) { effect in
                                    Text(effect.title).tag(effect)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("밝기") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Slider(value: brightnessBinding, in: 1...100, step: 1)
                        Text("\(currentModeDraft.lightBar.brightness)%")
                            .font(.callout.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("상태 미리보기") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(lightBarPreview.shortLabel)
                        .font(.system(.title3, design: .rounded).weight(.semibold))

                    Text("캔버스 미리보기: \(currentModeDraft.lightBar.effect(for: lightBarPreview).title)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("상태를 클릭하면 가상 키보드에서 미리보고, 0x91로 기기에 임시 미리보기를 보냅니다. 저장은 아래쪽 공통 버튼을 사용하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                        ForEach(IDEState.workflowOrder) { state in
                            Button {
                                lightBarPreview = state
                                previewLightEffect(for: state)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(state.shortLabel)
                                        .font(.caption.weight(.semibold))
                                    Text(currentModeDraft.lightBar.effect(for: state).title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(state == lightBarPreview ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(state == lightBarPreview ? Color.accentColor : Color.black.opacity(0.08), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var switchInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("실시간 단계") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(currentSwitchTitle)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                        Spacer()
                        Circle()
                            .fill(currentSwitchTitle == "자동 승인" ? Color.green : Color.indigo)
                            .frame(width: 10, height: 10)
                    }
                    Text("레버는 물리적 단계이며 순간적인 누름이 아닙니다. 0단은 「자동 승인」, 1단은 「수동 승인」으로 표시됩니다. 여기서는 키보드가 보고한 위치만 읽고, 물리적 조작을 시뮬레이션하지 않습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            switchEffectivenessBox

            if bleManager.switchState == 0 {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("자동 승인은 에이전트와 훅에 의존하며, 블루투스를 에이전트가 점유해야 합니다", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout.weight(.semibold))
                        Text("Claude: PermissionRequest allow. Cursor: preToolUse 등과 cli-config. Codex: PermissionRequest allow. Kimi: AhaKey Kimi Hooks를 설치했다면 **레버가 현재 세션의 자동 승인을 바로 인수합니다**. 방금 설치했거나 kimi-cli를 업그레이드했다면 **kimi를 완전히 종료한 뒤 다시 열어 주세요**. 훅 stdout은 **`permissionDecision: deny`** 에만 특수한 차단 의미가 있습니다. 에이전트가 실행 중이어야 하고 블루투스도 에이전트가 점유해야 합니다.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            GroupBox("이 부품 이해하기") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("레버는 Claude / Cursor / Codex / Kimi에 **동시에 적용**되며, 키보드가 현재 어떤 Mode에 있는지와 무관합니다. 에이전트가 백그라운드에서 모든 IDE의 훅을 함께 감시하므로, 레버를 움직이면 네 IDE의 승인 동작이 즉시 전환됩니다.")
                    Divider()
                    Text("자동 승인: **Claude / Codex PermissionRequest**, **Cursor preToolUse**(cli-config 포함). **Kimi**: AhaKey Kimi Hooks를 설치했다면 레버가 **현재 세션**의 자동 승인을 바로 인수합니다. 방금 설치했거나 kimi-cli를 업그레이드했다면 kimi를 한 번 다시 열면 됩니다.")
                    Text("수동 승인: 사용자/터미널 확인으로 넘깁니다. Cursor, Codex 또는 Kimi에서 여전히 팝업이 뜨면 diagnostics의 ide와 diagnostic 필드를 확인하세요.")
                    Text("여전히 수동으로 동작하면 「기기 정보」에서 「도구 승인 진단」을 열어 permission-request.log(ide, hookEvent, diagnostic 등 포함)를 확인하세요.")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var switchEffectivenessBox: some View {
        let agentReady = agentManager.isInstalled && agentManager.isRunning && agentManager.hooksInstalled
        let hasAnyMissing = !agentManager.isInstalled || !agentManager.isRunning || !agentManager.hooksInstalled
        GroupBox(agentReady ? "적용됨" : "적용되지 않음") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: agentReady ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(agentReady ? .green : .orange)
                    Text(agentReady
                         ? "에이전트가 준비되면 Claude/Cursor/Codex의 승인이 레버에 따라 동작합니다. **Kimi**: AhaKey Kimi Hooks를 설치했다면 레버가 현재 세션을 바로 인수합니다. 방금 설치했거나 kimi-cli를 업그레이드했다면 kimi를 한 번 다시 열면 됩니다."
                         : "레버가 IDE에서 동작하려면 먼저 에이전트와 훅을 설치하고 블루투스를 에이전트에 넘겨야 합니다. 그러지 않으면 상태 표시로만 쓰입니다.")
                        .font(.callout)
                }

                if hasAnyMissing {
                    VStack(alignment: .leading, spacing: 4) {
                        agentChecklistRow(label: "LaunchAgent 설치됨", ok: agentManager.isInstalled)
                        agentChecklistRow(label: "에이전트가 블루투스에 연결됨", ok: agentManager.isRunning)
                        agentChecklistRow(label: "Claude / Cursor / Codex / Kimi 훅 설정됨", ok: agentManager.hooksInstalled)
                    }
                    .padding(.leading, 4)

                    HStack(spacing: 8) {
                        if !agentManager.isInstalled {
                            Button("에이전트 + 훅 설치") {
                                agentManager.install()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        } else if !agentManager.isRunning {
                            // 「기기 정보 · 에이전트」와 동일: launchd에서 데몬을 load + start 한다.
                            // 현재 이 App이 블루투스를 점유하고 있다면, 기기 정보에서 「블루투스 연결」을 에이전트로 먼저 넘기도록 안내해야 한다. 그렇지 않으면 둘 중 하나만 가능한 메인 흐름과 충돌한다(그래서 DeviceInfo와 마찬가지로 직접 시작을 비활성화한다).
                            Button("에이전트 시작") {
                                agentManager.start()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(agentManager.bluetoothConnectionOwner == .ahaKeyStudio)
                            .help(
                                agentManager.bluetoothConnectionOwner == .ahaKeyStudio
                                ? "현재 이 App이 블루투스를 점유하고 있습니다. 아래 「기기 정보…」를 열고 「블루투스 연결」에서 「에이전트가 점유」를 선택한 뒤 에이전트를 시작하세요. 기기 정보의 「시작」 버튼과 같은 규칙입니다."
                                : "「기기 정보 · 에이전트」의 시작과 동일하며, launchd가 ahakeyconfig-agent를 로드해 실행합니다."
                            )
                        }
                        Button("기기 정보(블루투스 / 에이전트 시작·정지)…") {
                            showsDeviceInfo = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func agentChecklistRow(label: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.caption)
            Text(label)
                .font(.caption)
                .foregroundStyle(ok ? .primary : .secondary)
        }
    }


    private var statusBar: some View {
        HStack(spacing: 16) {
            Label("\(selectedPart.title) · \(selectedMode.title)", systemImage: selectedPart.systemImage)
                .font(.callout)
            Divider()
                .frame(height: 14)
            Text("미동기화 변경 \(dirtyCount)")
                .font(.callout)
            Divider()
                .frame(height: 14)
            Text(syncStatusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let lastSyncDate {
                Text("최근 동기화 \(Self.timeFormatter.string(from: lastSyncDate))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("권한 진단") {
                showsDiagnostics = true
            }
            .buttonStyle(.borderless)
            .help("음성 권한 상태와 진단 로그를 확인합니다")
            .sheet(isPresented: $showsDiagnostics) {
                diagnosticsSheet
            }

            Button("초기 설정 안내") {
                voiceRelay.showsPermissionOnboarding = false
                unifiedOnboardingCompleted = false
            }
            .buttonStyle(.borderless)
            .help("AhaKey Studio 초기 설정 안내를 다시 엽니다")

            Button("도움말 센터") {
                showsHelpCenter = true
            }
            .buttonStyle(.borderless)
            .help("내장 도움말 센터를 엽니다")
            .sheet(isPresented: $showsHelpCenter) {
                HelpCenterSheet(
                    studioDraft: studioDraft,
                    selectedMode: selectedMode,
                    bleManager: bleManager
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(chromeBarBackground)
    }

    private var chromeBarBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private var currentModeDraft: AhaKeyModeDraft {
        studioDraft.draft(for: selectedMode)
    }

    private var currentSelectedKey: AhaKeyKeyDraft {
        let role = selectedPart.keyRole ?? .voice
        return currentModeDraft.key(for: role)
    }

    private var currentSwitchTitle: String {
        // 통합된 liveKeyboardSwitchState를 사용한다: 메인 App이 BLE를 직접 점유하면 bleManager.switchState,
        // 그렇지 않으면 agent 공유 파일의 값(사용자 레버 오버라이드 포함)을 쓴다. 그러지 않으면 캔버스 레버를 눌러도
        // bleManager.switchState가 계속 초기값 0이어서 캔버스가 「자동 승인」에 머문다.
        liveKeyboardSwitchState == 0 ? "자동 승인" : "수동 승인"
    }

    /// 키보드의 현재 실시간 상태 (lightMode/switchState/workMode)를 가져온다:
    /// - 메인 App이 BLE에 직접 연결됨(설정 편집 중) → 메인 App 자신의 BLE 값을 사용
    /// - 메인 App은 연결되지 않았지만 agent가 여전히 BLE를 점유하고 공유 파일을 쓰는 중 → agent가 발행한 캐시를 읽음
    /// - 둘 다 없음 → nil(캔버스는 시뮬레이션으로 되돌아간다)
    private var liveKeyboardLightMode: Int? {
        if bleManager.isConnected { return bleManager.lightMode }
        return bleManager.agentLightMode
    }
    private var liveKeyboardSwitchState: Int {
        // 사용자가 가상 레버를 방금 눌렀지만 agent / BLE가 아직 새 값을 보고하지 않았을 때는 낙관적 값을 우선해, 누르는 즉시 보이게 한다
        if let opt = bleManager.optimisticSwitchOverride { return opt }
        if bleManager.isConnected { return bleManager.switchState }
        return bleManager.agentSwitchState ?? 1
    }
    private var liveKeyboardWorkMode: Int? {
        if bleManager.isConnected { return bleManager.workMode }
        return bleManager.agentWorkMode
    }
    private var liveCanvasLightMode: Int? {
        guard let workMode = liveKeyboardWorkMode, selectedMode.rawValue == workMode else { return nil }
        return liveKeyboardLightMode
    }
    private var liveCanvasIDEStateValue: Int? {
        guard let workMode = liveKeyboardWorkMode, selectedMode.rawValue == workMode else { return nil }
        return bleManager.liveIDEStateValue
    }
    private var liveCanvasSwitchState: Int { liveKeyboardSwitchState }

    private func cycleModeForward() {
        let all = AhaKeyModeSlot.allCases
        let next = all[(all.firstIndex(of: selectedMode)! + 1) % all.count]
        selectedMode = next
    }

    /// 사용자가 가상 레버를 클릭할 때: 현재 effective switchState를 기준으로 0↔1 토글하고,
    /// 소프트웨어 오버라이드만 설정한다. 최신 펌웨어에서 0x91은 조명 효과 미리보기이며 더 이상 sw_state에 쓰이지 않는다.
    private func toggleVirtualSwitch() {
        let current = liveKeyboardSwitchState
        let next: UInt8 = current == 0 ? 1 : 0
        // 1) 즉시 낙관적 값을 설정 → 캔버스 버튼이 바로 토글된다
        bleManager.applyOptimisticSwitchOverride(next)
        // 2) 호출 진입점은 남겨 두지만, BLEManager는 예전 0x91을 더는 보내지 않고 진단 로그만 남긴다
        if bleManager.isConnected {
            bleManager.setSwitchStateViaBLE(next)
        }
        // 3) agent가 소프트 오버라이드를 설정하게 한다
        AgentManager.shared.sendSwitchOverride(next)
        // 4) 짧은 지연 뒤 공유 파일을 강제로 다시 읽어 실제 값이 맞춰졌는지 확인한다(agent의 파일 쓰기는 보통 < 100ms)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak bleManager] in
            bleManager?.refreshAgentStateFromFileNow()
        }
        syncStatusMessage = next == 0
            ? "가상 레버 → 자동 승인(훅이 자동 허용합니다. 조명 효과가 바뀌지 않으면 0x91을 지원하는 펌웨어를 먼저 설치하세요)"
            : "가상 레버 → 수동 승인(훅이 터미널 확인으로 넘깁니다)"
    }

    private var currentOLEDPreviewImage: NSImage? {
        guard let path = currentModeDraft.oled.localAssetPath else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private var currentOLEDAssetURL: URL? {
        guard let path = currentModeDraft.oled.localAssetPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var currentLightEffect: LightEffectStyle {
        currentModeDraft.lightBar.effect(for: lightBarPreview)
    }

    private var isEditingConfiguration: Bool {
        agentManager.bluetoothConnectionOwner == .ahaKeyStudio
    }

    // AhaKeyStudio 직접 연결, 에이전트가 키보드에 연결된 상태, 또는 블루투스를 반환하는 전환 구간 중 하나라도 만족하면 기기가 연결된 것으로 본다.
    private var isEffectivelyConnected: Bool {
        bleManager.isConnected || agentManager.isAgentBLEConnected || isTransitioningToKeyboardControl
    }

    private var shouldShowTopBarInstallStartButton: Bool {
        !agentManager.isInstalled || !agentManager.hooksInstalled
    }

    private var configurationModeDetail: String {
        if isEditingConfiguration {
            if bleManager.isConnected {
                return "AhaKey Studio가 키보드를 설정하는 중"
            }
            return bleManager.isScanning ? "AhaKey Studio가 키보드에 연결하는 중" : "AhaKey Studio가 키보드 연결을 기다리는 중"
        }
        // 블루투스를 에이전트에 넘김: 상단 바에 여전히 「설치 후 시작」이 보이면 훅/에이전트가 갖춰지지 않은 상태이므로, 왼쪽 「연결됨」과 합쳐 「제어 가능」으로 읽히게 하지 말 것.
        if !isEditingConfiguration && shouldShowTopBarInstallStartButton && isEffectivelyConnected {
            if agentManager.isRunning && agentManager.isAgentBLEConnected {
                return "에이전트가 키보드를 제어하는 중"
            }
            return "설치 후 시작해야 키보드를 제어할 수 있습니다"
        }
        // 블루투스를 에이전트에 넘긴 경우: 왼쪽 infoPill의 「연결됨」과 기준을 일치시켜(isEffectivelyConnected) 「연결됨」+「키보드 대기」처럼 서로 모순되는 문구가 나오지 않게 한다.
        if isEffectivelyConnected {
            if agentManager.isRunning && agentManager.isAgentBLEConnected {
                return "에이전트가 키보드를 제어하는 중"
            }
            if agentManager.isRunning {
                return "키보드가 연결됨. 에이전트 연결 상태를 동기화하는 중"
            }
            return "키보드가 연결됨"
        }
        if agentManager.isRunning {
            return "에이전트 실행 중, 키보드 연결을 기다리는 중"
        }
        if agentManager.isInstalled {
            return "에이전트가 설치됨, 제어를 준비하는 중"
        }
        return "에이전트를 설치해야 키보드를 제어할 수 있습니다"
    }

    private var configurationModeButtonTitle: String {
        if isSyncing {
            return "동기화 중…"
        }
        if isEditingConfiguration {
            return "설정 저장"
        }
        return "설정 편집"
    }

    private var configurationModeButtonHelp: String {
        if isEditingConfiguration {
            if hasUnsyncedChanges {
                return "현재 초안을 키보드에 동기화한 뒤 블루투스를 에이전트에 반환합니다."
            }
            return "동기화하지 않은 변경이 없어 블루투스를 바로 에이전트에 반환합니다."
        }
        return "AhaKey Studio가 블루투스를 임시로 인수해 키 변경, LCD, 동기화, 로컬 조명 효과 테스트에 사용합니다."
    }

    private var voicePresetDetail: String {
        let preset = currentSelectedKey.voicePreset ?? .custom
        return preset.detail
    }

    private func permissionBadge(title: String, granted: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(granted ? "켜짐" : "꺼짐")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 999)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var currentSelectedKeySanitizedDescription: String {
        currentSelectedKey.description.sanitizedASCII(maxLength: 20)
    }

    private var selectedKeyDescriptionBinding: Binding<String> {
        Binding(
            get: { currentSelectedKey.description },
            set: { newValue in
                updateSelectedKey { key in
                    key.description = String(newValue.prefix(20))
                }
            }
        )
    }

    private var selectedKeyShortcutBinding: Binding<ShortcutBinding> {
        Binding(
            get: { currentSelectedKey.shortcut },
            set: { newValue in
                updateSelectedKey { $0.shortcut = newValue }
            }
        )
    }

    private var oledFramesPerSecondBinding: Binding<Int> {
        Binding(
            get: { currentModeDraft.oled.framesPerSecond },
            set: { newValue in
                updateCurrentMode { mode in
                    mode.oled.framesPerSecond = min(30, max(1, newValue))
                }
            }
        )
    }

    private var hasUnsyncedChanges: Bool {
        dirtyCount > 0
    }

    private var dirtyCount: Int {
        AhaKeyModeSlot.allCases.reduce(into: 0) { count, mode in
            let current = studioDraft.draft(for: mode)
            let baseline = lastSyncedDraft.draft(for: mode)
            for role in AhaKeyKeyRole.allCases where current.key(for: role) != baseline.key(for: role) {
                count += 1
            }
            if current.oled != baseline.oled {
                count += 1
            }
            if current.lightBar != baseline.lightBar {
                count += 1
            }
        }
    }

    private func restoreCurrentModeDefaults() {
        let restored = AhaKeyModeDraft.default(for: selectedMode)
        var next = studioDraft
        next.updateMode(restored)
        studioDraft = next
        syncStatusMessage = "\(selectedMode.title) 기본값으로 복원했습니다. 동기화를 기다립니다."
    }

    private func clearCurrentOLED() {
        updateCurrentMode { mode in
            mode.oled.localAssetPath = nil
            mode.oled.statusLine = AhaKeyOLEDDraft.default(for: selectedMode).statusLine
        }
    }

    private func applyVoicePreset(_ preset: VoicePreset) {
        updateSelectedKey { key in
            key.voicePreset = preset
            if preset != .custom {
                key.shortcut = preset.defaultBinding
            }
            if key.description.isEmpty {
                key.description = key.role.defaultDescription
            }
        }
    }

    // MARK: - 매크로 편집

    /// 키가 현재 "매크로" 입력 모드인지 "단축키" 입력 모드인지.
    /// 상태는 `macro`가 비어 있는지로만 유도해, 별도 flag를 두지 않는다.
    private enum KeyBindingMode {
        case shortcut
        case macro
    }

    private var selectedKeyBindingModeBinding: Binding<KeyBindingMode> {
        Binding(
            get: { currentSelectedKey.usesMacro ? .macro : .shortcut },
            set: { newValue in
                switch newValue {
                case .shortcut:
                    updateSelectedKey { key in
                        key.macro = []
                    }
                case .macro:
                    updateSelectedKey { key in
                        guard key.macro.isEmpty else { return }
                        // Mode 0의 「No」 키는 shortcut을 의도적으로 비워 두고, 실제 바인딩은 펌웨어 매크로 ↓↓⏎다. 여기서도 「빈 shortcut → Enter 시드」를 쓰면
                        // 「단일 키」에서 「매크로」로 되돌릴 때 Enter만 누르도록 잘못 채워져, 사용자가 방금 설정한 3키 매크로를 덮어쓴다.
                        if selectedMode == .mode0, key.role == .reject {
                            key.macro = AhaKeyModeDraft.claudeNoMacroSteps.map { step in
                                MacroStep(action: step.action, param: step.param)
                            }
                            return
                        }
                        // 다른 키: 현재 shortcut의 주 키를 시드로 사용한다(설정이 없으면 Enter). 빈 매크로 목록이 나오지 않게 한다.
                        let seed: UInt8 = key.shortcut.keyCode == 0 ? HIDUsage.enter : key.shortcut.keyCode
                        key.macro = [
                            MacroStep(action: .downKey, param: seed),
                            MacroStep(action: .upKey, param: seed),
                        ]
                    }
                }
            }
        )
    }

    private func appendMacroStep() {
        updateSelectedKey { key in
            // 기본으로 "Enter 누르기"를 추가한다 —— 대부분 단계를 추가할 때 키를 누르려는 의도이며, 지연/떼기는 나중에 바꿀 수 있다.
            key.macro.append(MacroStep(action: .downKey, param: HIDUsage.enter))
        }
    }

    private func removeMacroStep(at index: Int) {
        updateSelectedKey { key in
            guard key.macro.indices.contains(index) else { return }
            key.macro.remove(at: index)
        }
    }

    private func moveMacroStep(from index: Int, by offset: Int) {
        updateSelectedKey { key in
            let target = index + offset
            guard key.macro.indices.contains(index), key.macro.indices.contains(target) else { return }
            key.macro.swapAt(index, target)
        }
    }

    private func updateMacroStep(id: UUID, transform: (inout MacroStep) -> Void) {
        updateSelectedKey { key in
            guard let idx = key.macro.firstIndex(where: { $0.id == id }) else { return }
            transform(&key.macro[idx])
        }
    }

    private func updateSelectedKey(_ transform: (inout AhaKeyKeyDraft) -> Void) {
        guard let role = selectedPart.keyRole else { return }
        updateCurrentMode { mode in
            var key = mode.key(for: role)
            transform(&key)
            mode.updateKey(key)
        }
    }

    private func updateCurrentMode(_ transform: (inout AhaKeyModeDraft) -> Void) {
        updateMode(selectedMode, transform)
    }

    private func updateMode(_ modeSlot: AhaKeyModeSlot, _ transform: (inout AhaKeyModeDraft) -> Void) {
        var next = studioDraft
        var mode = next.draft(for: modeSlot)
        transform(&mode)
        next.updateMode(mode)
        studioDraft = next
    }

    private func partIsDirty(_ part: AhaKeyStudioPart) -> Bool {
        let current = studioDraft.draft(for: selectedMode)
        let baseline = lastSyncedDraft.draft(for: selectedMode)
        switch part {
        case .key1, .key2, .key3, .key4:
            guard let role = part.keyRole else { return false }
            return current.key(for: role) != baseline.key(for: role)
        case .oledDisplay:
            return current.oled != baseline.oled
        case .lightBar:
            return current.lightBar != baseline.lightBar
        case .toggleSwitch:
            return false
        }
    }

    private func dirtyPartsForCurrentMode() -> Set<AhaKeyStudioPart> {
        Set(AhaKeyStudioPart.allCases.filter(partIsDirty(_:)))
    }

    private func selectOLEDGIF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try OLEDFrameEncoder.validateGIFSourceFileSize(at: url)
                try OLEDFrameEncoder.validateFrameCount(at: url)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "이미지 파일이 업로드 제한을 충족하지 않습니다."
                syncStatusMessage = msg
                updateCurrentMode { mode in
                    mode.oled.statusLine = msg
                }
                return
            }
            let frameCount = OLEDFrameEncoder.frameCount(at: url)
            updateCurrentMode { mode in
                mode.oled.localAssetPath = url.path
                mode.oled.statusLine = "\(max(frameCount, 1)) 프레임 이미지 미리보기를 선택했습니다. 기록할 때 \(selectedMode.title) 고정 파티션에 업로드됩니다."
            }
            syncStatusMessage = "\(selectedMode.title)의 LCD 미리보기를 업데이트했습니다. 기기에 기록하려면 아래쪽 공통 버튼을 사용하세요."
        }
    }

    private func handleConfigurationModeButton() {
        if isEditingConfiguration {
            finishEditingConfiguration()
        } else {
            enterEditingConfiguration()
        }
    }

    private func installStartAgentFromTopBar() {
        if agentManager.bluetoothConnectionOwner != .agentDaemon {
            agentManager.setBluetoothConnectionOwner(.agentDaemon, bleManager: bleManager)
        }
        if !agentManager.isInstalled || !agentManager.hooksInstalled {
            agentManager.install()
        } else {
            agentManager.start()
        }
    }

    private func enterEditingConfiguration() {
        isTransitioningToKeyboardControl = false
        agentManager.setBluetoothConnectionOwner(.ahaKeyStudio, bleManager: bleManager)
        syncStatusMessage = "설정 편집에 들어갔습니다. AhaKey Studio가 블루투스를 임시로 인수합니다."
    }

    private func finishEditingConfiguration() {
        guard hasUnsyncedChanges else {
            returnToKeyboardControl()
            return
        }

        if bleManager.isConnected && bleManager.commandCharReady {
            syncAllModesToDevice(returnToKeyboardControlWhenDone: true)
        } else {
            syncStatusMessage = "기기에 연결 중입니다. 연결되면 자동으로 동기화한 뒤 제어 모드로 돌아갑니다…"
            bleManager.userInitiatedConnect()
            waitForConnectionThenSync()
        }
    }

    private func writeToKeyboard() {
        performUnifiedDeviceWrite(returnToKeyboardControlWhenDone: false, showResultAlert: true)
    }

    private func completeEditingAfterSuccessfulWrite() {
        commitModeNameEdit()
        withAnimation(.easeInOut(duration: 0.18)) {
            isEditingInspector = false
        }
        returnToKeyboardControl()
    }

    // BLE 연결과 명령 채널 준비를 폴링으로 기다린다(최대 10초). 연결되면 자동으로 동기화하고 키보드 제어로 돌아간다.
    private func waitForConnectionThenSync() {
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if bleManager.isConnected && bleManager.commandCharReady {
                    syncAllModesToDevice(returnToKeyboardControlWhenDone: true)
                    return
                }
            }
            syncStatusMessage = "연결 시간이 초과되어 이번에는 키보드에 기록하지 않았습니다. 블루투스를 에이전트에 반환했으니, 다시 편집에 들어가 저장을 재시도할 수 있습니다."
            returnToKeyboardControl()
        }
    }

    private func returnToKeyboardControl() {
        isTransitioningToKeyboardControl = true
        agentManager.setBluetoothConnectionOwner(.agentDaemon, bleManager: bleManager)
        syncStatusMessage = "키보드 제어를 복구하는 중입니다. 에이전트가 키보드에 연결하고 있습니다…"
        monitorAgentReconnect()
    }

    // 키보드 제어로 돌아간 뒤 2초마다 에이전트 BLE 상태를 폴링한다(비동기 socket 조회가 끝난 뒤 값을 읽는다).
    // 최대 20초까지 기다리고, 시간이 초과되면 에이전트 재시작을 시도한다. 전환 구간이 끝나면 isTransitioningToKeyboardControl을 해제한다.
    private func monitorAgentReconnect() {
        Task { @MainActor in
            for i in 0..<10 {
                // 첫 번째는 조금 짧게 기다려 에이전트가 시작할 시간을 준다
                let waitMs: UInt64 = i == 0 ? 1_500_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: waitMs)
                agentManager.refresh()
                // refresh() 내부의 비동기 socket 조회 결과가 메인 스레드로 돌아오기를 기다린다(최대 2.5s timeout)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if agentManager.isAgentBLEConnected {
                    syncStatusMessage = "키보드 제어로 돌아왔습니다. 에이전트가 블루투스를 인수합니다."
                    isTransitioningToKeyboardControl = false
                    return
                }
                // 약 10초가 지나도 에이전트가 연결되지 않으면 재시작을 시도한다
                if i == 2, !agentManager.isAgentBLEConnected {
                    agentManager.start()
                }
            }
            syncStatusMessage = "키보드 제어로 돌아왔습니다. 에이전트가 블루투스를 인수합니다."
            isTransitioningToKeyboardControl = false
        }
    }

    private func syncAllModesToDevice(returnToKeyboardControlWhenDone: Bool = false) {
        performUnifiedDeviceWrite(returnToKeyboardControlWhenDone: returnToKeyboardControlWhenDone, showResultAlert: false)
    }

    private func performUnifiedDeviceWrite(returnToKeyboardControlWhenDone: Bool, showResultAlert: Bool) {
        guard bleManager.isConnected && bleManager.commandCharReady else {
            let message = showResultAlert ? "기기가 연결되지 않았습니다. 키보드를 먼저 연결한 뒤 다시 시도하세요." : "기기가 연결되지 않았거나 명령 채널이 준비되지 않아, 지금은 로컬 초안만 저장합니다."
            syncStatusMessage = message
            if showResultAlert {
                writeResultAlertMessage = message
                showsWriteResultAlert = true
            }
            return
        }

        applyCursorRejectMacroSelfHealIfNeeded()
        isSyncing = true
        syncStatusMessage = "기기에 기록할 준비를 하는 중…"
        let returnAgent = returnToKeyboardControlWhenDone

        Task { @MainActor in
            do {
                let uploadedOLEDCount = try await uploadChangedOLEDsToDevice()
                var commands = commandsForModes(AhaKeyModeSlot.allCases)
                commands.append((data: AhaKeyCommand.saveConfig(), label: "전체 설정을 기기에 저장"))

                let total = commands.count
                if uploadedOLEDCount > 0 {
                    self.syncStatusMessage = "LCD 애니메이션 \(uploadedOLEDCount)개를 업로드했습니다. 조명 효과와 키 매핑 설정을 기록하는 중(약 \(total)건)…"
                } else {
                    self.syncStatusMessage = "조명 효과와 키 매핑 설정을 기록하는 중(약 \(total)건)…"
                }
                self.bleManager.writeCommandsSequentially(commands) {
                    Task { @MainActor in
                        // 큐와 50ms 간격으로 순서는 보장된다. 펌웨어가 마지막 프레임을 아직 처리하지 못한 상태를 피하려고 조금 기다린 뒤 블루투스를 반환한다.
                        try? await Task.sleep(nanoseconds: UInt64(250) * 1_000_000)
                        self.lastSyncedDraft = self.studioDraft
                        self.lastSyncDate = Date()
                        self.isSyncing = false
                        self.syncStatusMessage = "모두 기기에 기록하고 저장했습니다."
                        if showResultAlert {
                            self.writeResultAlertMessage = "설정을 키보드에 성공적으로 기록했습니다."
                            self.showsWriteResultAlert = true
                        }
                        if returnAgent {
                            self.returnToKeyboardControl()
                        }
                    }
                }
            } catch {
                let message = "키보드에 기록하지 못했습니다: \(error.localizedDescription)"
                self.isSyncing = false
                self.syncStatusMessage = message
                if showResultAlert {
                    self.writeResultAlertMessage = message
                    self.showsWriteResultAlert = true
                }
            }
        }
    }

    private func uploadChangedOLEDsToDevice() async throws -> Int {
        var uploadCount = 0

        for mode in AhaKeyModeSlot.allCases {
            let draft = studioDraft.draft(for: mode)
            guard let assetPath = draft.oled.localAssetPath else { continue }

            let baseline = lastSyncedDraft.draft(for: mode).oled
            let deviceFrameCount = bleManager.keyboardPictureStates[mode.rawValue]?.frameCount ?? 0
            guard draft.oled != baseline || deviceFrameCount == 0 else { continue }

            let assetURL = URL(fileURLWithPath: assetPath)
            try OLEDFrameEncoder.validateGIFSourceFileSize(at: assetURL)
            let frames = try OLEDFrameEncoder.frames(fromGIFAt: assetURL)

            updateMode(mode) { modeDraft in
                modeDraft.oled.statusLine = "\(mode.title)에 애니메이션을 업로드하는 중…"
            }
            syncStatusMessage = "\(mode.title)의 LCD 애니메이션을 업로드하는 중…"

            let startIndex = try await resolveOLEDUploadStartIndex(for: mode, frameCount: frames.count)
            try await bleManager.uploadOLEDFrames(
                frames,
                fps: draft.oled.framesPerSecond,
                mode: UInt8(mode.rawValue),
                startIndex: UInt16(startIndex)
            )

            updateMode(mode) { modeDraft in
                modeDraft.oled.statusLine = "\(frames.count) 프레임을 기기에 업로드했습니다. 슬롯 시작 위치 \(startIndex). 모드를 바꾸면 설명을 먼저 표시한 뒤 현재 모드 애니메이션으로 돌아갑니다."
            }
            uploadCount += 1
        }

        return uploadCount
    }

    private func resendCurrentModeToDevice() {
        guard bleManager.isConnected && bleManager.commandCharReady else {
            syncStatusMessage = "기기가 연결되지 않았거나 명령 채널이 준비되지 않아, 지금은 로컬 초안만 저장합니다."
            return
        }

        applyCursorRejectMacroSelfHealIfNeeded()
        var commands = commandsForModes([selectedMode])
        commands.append((data: AhaKeyCommand.saveConfig(), label: "\(selectedMode.title) 현재 설정 저장"))

        isSyncing = true
        syncStatusMessage = "\(selectedMode.title) 기록 중…"
        bleManager.writeCommandsSequentially(commands) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(150) * 1_000_000)
                self.lastSyncDate = Date()
                self.isSyncing = false
                self.syncStatusMessage = "\(self.selectedMode.title) 현재 모드를 다시 전송했습니다."
            }
        }
    }

    /// Cursor 단계의 「취소 키」가 기본값 ⌫ 인데도 매크로가 남아 있으면 동기화가 단일 키가 아니라 0x74로 흐른다. 잘못 남은 매크로를 지워 마이그레이션 로직과 일치시킨다.
    private func applyCursorRejectMacroSelfHealIfNeeded() {
        var next = studioDraft
        var m1 = next.draft(for: .mode1)
        var reject = m1.key(for: .reject)
        let defaultR = AhaKeyModeDraft.default(for: .mode1).key(for: .reject)
        guard !reject.macro.isEmpty, reject.shortcut == defaultR.shortcut else { return }
        reject.macro = []
        m1.updateKey(reject)
        next.updateMode(m1)
        studioDraft = next
    }

    private func commandsForModes(_ modes: [AhaKeyModeSlot]) -> [(data: Data, label: String)] {
        var commands: [(data: Data, label: String)] = []

        for mode in modes {
            let draft = studioDraft.draft(for: mode)
            for role in AhaKeyKeyRole.allCases {
                let key = draft.key(for: role)
                let keyIndex = UInt8(role.rawValue)
                let modeByte = UInt8(mode.rawValue)

                if key.usesMacro {
                    // 펌웨어는 0x73 단축키와 0x74 매크로를 계층으로 나눠 저장한다. 「단축키」에서 「매크로」로 바꿀 때는 옛 단축키를 먼저 지워야 잔여물이 남지 않는다.
                    commands.append((
                        data: AhaKeyCommand.setKeyMapping(
                            mode: modeByte,
                            keyIndex: keyIndex,
                            hidCodes: []
                        ),
                        label: "\(mode.title) \(key.title) 단축키 계층 삭제(매크로를 기록할 예정)"
                    ))
                    commands.append((
                        data: AhaKeyCommand.setKeyMacro(
                            mode: modeByte,
                            keyIndex: keyIndex,
                            macroData: key.macro.flattenedBytes
                        ),
                        label: "\(mode.title) \(key.title) 매크로 기록: \(key.macro.displaySummary)"
                    ))
                } else {
                    // 「매크로」에서 「단축키 / 없음」으로 바꿀 때는 빈 0x74를 먼저 보내야 한다. 그러지 않으면 기기가 여전히 옛 매크로를 따를 수 있다(Cursor 및 다른 mode에서 키 변경이 적용되지 않는 것으로 나타난다).
                    commands.append((
                        data: AhaKeyCommand.setKeyMacro(
                            mode: modeByte,
                            keyIndex: keyIndex,
                            macroData: []
                        ),
                        label: "\(mode.title) \(key.title) 매크로 계층 삭제(단축키를 기록할 예정)"
                    ))
                    if !key.shortcut.hidCodes.isEmpty {
                        commands.append((
                            data: AhaKeyCommand.setKeyMapping(
                                mode: modeByte,
                                keyIndex: keyIndex,
                                hidCodes: key.shortcut.hidCodes
                            ),
                            label: "\(mode.title) \(key.title) 단축키 기록: \(key.shortcut.displayLabel)"
                        ))
                    } else {
                        commands.append((
                            data: AhaKeyCommand.setKeyMapping(
                                mode: modeByte,
                                keyIndex: keyIndex,
                                hidCodes: []
                            ),
                            label: "\(mode.title) \(key.title) 단축키 삭제"
                        ))
                    }
                }

                let sanitizedDescription = key.description.sanitizedASCII(maxLength: 20)
                commands.append((
                    data: AhaKeyCommand.setKeyDescription(
                        mode: UInt8(mode.rawValue),
                        keyIndex: keyIndex,
                        text: key.description
                    ),
                    label: "\(mode.title) \(key.title) 설명 기록: \(sanitizedDescription.isEmpty ? "비어 있음" : sanitizedDescription)"
                ))
            }
        }

        for mode in modes {
            let lb = studioDraft.draft(for: mode).lightBar
            let effects = IDEState.allCases.map { lb.effect(for: $0).firmwareIndex }
            commands.append((
                AhaKeyCommand.setLightMapping(mode: UInt8(mode.rawValue), stateEffects: effects),
                "조명 효과 매핑 \(mode.title)"
            ))
        }

        let brightness = UInt8(studioDraft.draft(for: modes[0]).lightBar.brightness)
        commands.append((AhaKeyCommand.setBrightness(brightness), "밝기 \(brightness)%"))

        return commands
    }

    /// 키보드에 처음 연결한 뒤, 업로드되지 않은 mode slot에 bundle 기본 GIF를 자동으로 밀어 넣는다.
    /// 트리거 시점: bleManager.keyboardPictureStates의 네 mode 조회가 모두 돌아온 뒤
    /// (.onChange(of: bleManager.keyboardPictureStates)에서 스케줄링).
    /// 가드:
    /// - picLength==0(slot이 완전히 비어 있음)인 mode만 업로드한다. 0이 아니면 사용자가 이미 지정했거나 펌웨어 공장 이미지로 본다
    /// - draft의 localAssetPath가 여전히 bundle 기본값을 가리킬 때(사용자가 직접 바꾸지 않았을 때)만 업로드한다
    /// - 연결마다 한 번만 실행한다(oledAutoSyncDoneForConnection 플래그는 .onChange(isConnected)에서 초기화된다)
    private func autoSyncDefaultOLEDsIfNeeded() async {
        guard bleManager.isConnected else { return }
        // 네 mode의 0x83 조회가 모두 돌아온 뒤에 진행해, 절반만 판단해 이미 업로드된 slot을 비어 있다고 보는 일을 막는다
        guard bleManager.keyboardPictureStates.count == AhaKeyModeSlot.allCases.count else { return }

        for mode in AhaKeyModeSlot.allCases {
            guard let state = bleManager.keyboardPictureStates[mode.rawValue] else { continue }
            guard state.frameCount == 0 else { continue }
            guard let bundledPath = DefaultOLEDAssets.bundledAssetPath(for: mode) else { continue }
            let draft = studioDraft.draft(for: mode)
            guard let drafPath = draft.oled.localAssetPath,
                  DefaultOLEDAssets.isBundledPath(drafPath) else { continue }

            let assetURL = URL(fileURLWithPath: bundledPath)
            do {
                try OLEDFrameEncoder.validateGIFSourceFileSize(at: assetURL)
                let frames = try OLEDFrameEncoder.frames(fromGIFAt: assetURL)
                let startIndex = try await resolveOLEDUploadStartIndex(for: mode, frameCount: frames.count)
                try await bleManager.uploadOLEDFrames(
                    frames,
                    fps: draft.oled.framesPerSecond,
                    mode: UInt8(mode.rawValue),
                    startIndex: UInt16(startIndex)
                )
                updateMode(mode) { m in
                    m.oled.statusLine = "기본 애니메이션을 자동 동기화했습니다(\(frames.count) 프레임)."
                }
            } catch {
                syncStatusMessage = "\(mode.title) 기본 애니메이션 자동 동기화 실패: \(error.localizedDescription)"
            }
        }
    }

    private func resolveOLEDUploadStartIndex(for targetMode: AhaKeyModeSlot, frameCount: Int) async throws -> Int {
        guard frameCount <= AhaKeyCommand.oledMaxFramesPerMode else {
            throw OLEDUploadError.tooManyFrames(max: AhaKeyCommand.oledMaxFramesPerMode)
        }

        _ = try? await bleManager.readPictureState(mode: UInt8(targetMode.rawValue))
        return Int(AhaKeyCommand.oledStartIndex(forMode: UInt8(targetMode.rawValue)))
    }

    private func canPlacePictureRange(
        start: Int,
        count: Int,
        occupiedRegions: [(start: Int, end: Int)],
        maxCapacity: Int
    ) -> Bool {
        let end = start + count
        guard start >= 0, end <= maxCapacity else { return false }
        return occupiedRegions.allSatisfy { region in
            end <= region.start || start >= region.end
        }
    }

    private func findFreePictureSpace(
        occupiedRegions: [(start: Int, end: Int)],
        neededCount: Int,
        maxCapacity: Int
    ) -> Int? {
        guard !occupiedRegions.isEmpty else { return 0 }

        if occupiedRegions[0].start >= neededCount {
            return 0
        }

        for index in 0 ..< (occupiedRegions.count - 1) {
            let gapStart = occupiedRegions[index].end
            let gapEnd = occupiedRegions[index + 1].start
            if gapEnd - gapStart >= neededCount {
                return gapStart
            }
        }

        let lastEnd = occupiedRegions.last?.end ?? 0
        if lastEnd + neededCount <= maxCapacity {
            return lastEnd
        }

        return nil
    }

    private func lightEffectBinding(for state: IDEState) -> Binding<LightEffectStyle> {
        Binding(
            get: { currentModeDraft.lightBar.effect(for: state) },
            set: { newEffect in
                var draft = studioDraft
                var mode = draft.draft(for: selectedMode)
                if let idx = mode.lightBar.stateMappings.firstIndex(where: { $0.state == state }) {
                    mode.lightBar.stateMappings[idx].effect = newEffect
                }
                draft.updateMode(mode)
                studioDraft = draft
                AhaKeyStudioStore.save(studioDraft)
                lightBarPreview = state
                previewLightEffect(newEffect)
            }
        )
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { Double(currentModeDraft.lightBar.brightness) },
            set: { newValue in
                var draft = studioDraft
                var mode = draft.draft(for: selectedMode)
                mode.lightBar.brightness = Int(newValue)
                draft.updateMode(mode)
                studioDraft = draft
                AhaKeyStudioStore.save(studioDraft)
                previewBrightness(Int(newValue))
            }
        )
    }

    private func previewLightEffect(for state: IDEState) {
        previewLightEffect(currentModeDraft.lightBar.effect(for: state))
    }

    private func previewLightEffect(_ effect: LightEffectStyle) {
        guard bleManager.isConnected && bleManager.commandCharReady else {
            syncStatusMessage = "가상 조명 효과 미리보기를 업데이트했습니다. 키보드를 연결하면 기기에서 미리볼 수 있습니다."
            return
        }
        bleManager.previewLightEffect(effect.firmwareIndex)
        syncStatusMessage = "조명 효과 미리보기 중: \(effect.title)."
    }

    private func previewBrightness(_ value: Int) {
        guard bleManager.isConnected && bleManager.commandCharReady else {
            syncStatusMessage = "밝기를 \(value)%로 업데이트했습니다. 키보드를 연결하면 기기에서 미리볼 수 있습니다."
            return
        }
        bleManager.setBrightness(UInt8(max(1, min(100, value))))
        syncStatusMessage = "조명 세기 미리보기 중: \(value)%."
    }

    private func infoPill(title: String, subtitle: String, accent: Color, width: CGFloat = 86) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text(subtitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func manualCallout(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.callout)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func openNativeSpeechPrivacySettings() {
        openNativeSpeechPrivacySettingsURL()
    }

    private var nativeSpeechPermissionsReady: Bool {
        nativeSpeech.microphoneGranted &&
            nativeSpeech.speechRecognitionGranted &&
            nativeSpeech.siriEnabled &&
            nativeSpeech.dictationEnabled
    }

    private var startupPermissionsReady: Bool {
        bleManager.bluetoothPermissionGranted &&
            bleManager.bluetoothPoweredOn &&
            voiceRelay.inputMonitoringGranted &&
            voiceRelay.accessibilityGranted &&
            nativeSpeech.microphoneGranted &&
            nativeSpeech.speechRecognitionGranted &&
            nativeSpeech.siriEnabled &&
            nativeSpeech.dictationEnabled
    }

    private func scheduleStartupPermissionOnboarding() {
        voiceRelay.showsPermissionOnboarding = false
        bleManager.refreshBluetoothAuthorization()
        voiceRelay.refreshPermissions(deferredTCCRequery: true)
        nativeSpeech.refreshPermissions(deferredTCCRequery: true)
    }

    private func refreshStartupPermissionOnboarding() {
        voiceRelay.showsPermissionOnboarding = false
    }
}

private struct VoicePermissionOnboardingSheet: View {
    @ObservedObject var bleManager: AhaKeyBLEManager
    @ObservedObject var voiceRelay: VoiceRelayService
    @ObservedObject var nativeSpeech: NativeSpeechTranscriptionService
    @Environment(\.dismiss) private var dismiss

    @State private var fixInProgress = false
    @State private var fixAlertTitle = ""
    @State private var fixAlertMessage = ""
    @State private var fixAlertIsSuccess = false
    @State private var showFixAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("초기 권한 설정 안내")
                .font(.system(size: 24, weight: .semibold))

            Text("AhaKey Studio를 처음 사용할 때는 몇 가지 시스템 권한이 필요합니다. 키보드 연결에는 블루투스, 백그라운드에서 음성 키를 인수하려면 입력 모니터링과 손쉬운 사용, macOS 기본 음성에는 마이크·음성 전사·Siri·받아쓰기가 필요합니다.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                permissionRow(title: "블루투스", granted: bleManager.bluetoothPermissionGranted && bleManager.bluetoothPoweredOn, detail: bleManager.bluetoothPermissionGranted ? "시스템 블루투스를 켜면 AhaKey 키보드를 검색, 연결, 동기화할 수 있습니다." : "「개인정보 보호 및 보안 > 블루투스」에서 AhaKey Studio의 블루투스 사용을 허용하세요.")
                permissionRow(title: "마이크", granted: nativeSpeech.microphoneGranted, detail: "AhaKey Studio가 Apple 기본 음성 수집을 사용하도록 허용합니다.")
                permissionRow(title: "음성 전사", granted: nativeSpeech.speechRecognitionGranted, detail: "AhaKey Studio가 Apple 기본 음성 인식을 사용하도록 허용합니다.")
                permissionRow(title: "Siri", granted: nativeSpeech.siriEnabled, detail: "「시스템 설정 > Siri 및 Spotlight」에서 Siri를 켜면 macOS 기본 음성 기능에 사용됩니다.")
                permissionRow(title: "받아쓰기", granted: nativeSpeech.dictationEnabled, detail: "「시스템 설정 > 키보드 > 받아쓰기」에서 받아쓰기를 켜면 시스템 음성 구성 요소를 온전히 사용할 수 있습니다.")
                permissionRow(title: "손쉬운 사용", granted: voiceRelay.accessibilityGranted, detail: "AhaKey Studio가 음성 키를 Apple 기본 전사 또는 Fn/Globe로 변환하도록 허용합니다.")
                permissionRow(title: "입력 모니터링", granted: voiceRelay.inputMonitoringGranted, detail: "AhaKey Studio가 백그라운드에서 실물 음성 키를 감시하도록 허용합니다. 설정 후에는 보통 앱을 종료하고 다시 열어야 합니다.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("권한 설정 단계")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("1. 「지금 권한 요청」을 누르고, 시스템 팝업에서 블루투스, 마이크, 음성 전사를 허용합니다.")
                Text("2. 시스템 설정이 자동으로 열리면 Siri, 받아쓰기, 손쉬운 사용을 차례로 켭니다.")
                Text("3. 마지막으로 입력 모니터링을 켭니다. 시스템이 재시작을 안내하면 앱을 종료하고 다시 엽니다.")
                Text("4. 여기로 돌아와 「완료했습니다, 다시 확인」을 눌러 입력을 이어서 사용합니다.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("시스템에서 허용을 체크했는데도 이 앱에 꺼짐으로 표시되는 경우: AhaKey Studio를 완전히 종료한 뒤 다시 실행하세요. 입력 모니터링, 손쉬운 사용 등은 프로세스 단위로 적용되므로 「다시 확인」만 누르거나 백그라운드에서 전환해 오면 옛 상태가 읽힐 수 있고, 재시작하면 시스템 설정과 일치합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("배포판 / DMG / Xcode: 기본 정식 빌드는 시스템 「개인정보 보호 및 보안」에 「AhaKey Studio」로 표시되고, Xcode에서 이 프로젝트를 Debug로 실행하면 「AhaKey Studio(디버그)」로 표시되므로 이름별로 각각 권한을 부여하세요. 경로나 서명이 다르면 시스템은 다른 App으로 인식합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("블루투스 \(bleManager.bluetoothPermissionGranted ? (bleManager.bluetoothPoweredOn ? "켜짐" : "승인됨, 블루투스 꺼짐") : "승인 안 됨")")
                Text(voiceRelay.lastPermissionCheckSummary)
                Text(nativeSpeech.lastPermissionCheckSummary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("지금 권한 요청") {
                    requestPermissionsThenOpenPrivacySettingsIfNeeded(
                        bleManager: bleManager,
                        voiceRelay: voiceRelay,
                        nativeSpeech: nativeSpeech
                    )
                }
                .buttonStyle(.borderedProminent)

                Button("완료했습니다, 다시 확인") {
                    bleManager.refreshBluetoothAuthorization()
                    voiceRelay.refreshPermissions(deferredTCCRequery: true)
                    nativeSpeech.refreshPermissions(deferredTCCRequery: true)
                }
                .buttonStyle(.bordered)

                RestartToApplyPermissionsButton(title: "종료 후 다시 열기")

                if !allPermissionsReady {
                    Button("시스템 설정 열기") {
                        openCombinedVoicePrivacySettingsURL()
                    }
                    .buttonStyle(.bordered)
                }

                if DebugSigningFixer.isAvailable {
                    Button(fixInProgress ? "초기화 중…" : "⚙️ 개발 환경 서명 초기화(보통 필요 없음)") {
                        runDebugSigningFix()
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                    .disabled(fixInProgress)
                    .help("예외 상황에서만 사용하세요. 인증서 만료 / Mac 교체 / Team ID 변경 / 키체인 손상으로 권한이 무효해졌을 때 누르면 app을 다시 서명하고 TCC 승인을 초기화합니다. 정식 배포판(소스 디렉터리 없음)에서는 이 버튼이 보이지 않습니다.")
                }

                Spacer()

                Button("나중에 하기") {
                    voiceRelay.dismissPermissionOnboarding()
                    dismiss()
                }
                .buttonStyle(.borderless)
            }

            if allPermissionsReady {
                Text("초기 권한이 모두 갖춰졌습니다. 이 창을 닫으면 AhaKey Studio가 키보드에 연결하고 백그라운드에서 음성 키를 감시하며, macOS 기본 음성도 정상적으로 사용할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("아직 켜지지 않은 권한이 있습니다. 위 상태를 항목별로 처리해 모두 초록색이 된 뒤 창을 닫아 주세요.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onChange(of: voiceRelay.inputMonitoringGranted) { _ in
            closeIfReady()
        }
        .onChange(of: voiceRelay.accessibilityGranted) { _ in
            closeIfReady()
        }
        .onChange(of: bleManager.bluetoothPermissionGranted) { _ in
            closeIfReady()
        }
        .onChange(of: bleManager.bluetoothPoweredOn) { _ in
            closeIfReady()
        }
        .alert(fixAlertTitle, isPresented: $showFixAlert) {
            if fixAlertIsSuccess {
                Button("App 즉시 종료") { NSApp.terminate(nil) }
                Button("나중에 종료", role: .cancel) {}
            } else {
                Button("확인", role: .cancel) {}
            }
        } message: {
            Text(fixAlertMessage)
        }
    }

    private func runDebugSigningFix() {
        fixInProgress = true
        DebugSigningFixer.run { result in
            fixInProgress = false
            fixAlertIsSuccess = result.success
            fixAlertTitle = result.success ? "복구 완료" : "복구 실패"
            fixAlertMessage = result.output
            showFixAlert = true
        }
    }

    private func closeIfReady() {
        guard allPermissionsReady else { return }
        voiceRelay.dismissPermissionOnboarding()
        dismiss()
    }

    private var allPermissionsReady: Bool {
        bleManager.bluetoothPermissionGranted &&
            bleManager.bluetoothPoweredOn &&
            voiceRelay.inputMonitoringGranted &&
            voiceRelay.accessibilityGranted &&
            nativeSpeech.microphoneGranted &&
            nativeSpeech.speechRecognitionGranted &&
            nativeSpeech.siriEnabled &&
            nativeSpeech.dictationEnabled
    }

    private func permissionRow(title: String, granted: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text(granted ? "켜짐" : "꺼짐")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct VoicePresetPicker: View {
    let selectedPreset: VoicePreset
    let onSelect: (VoicePreset) -> Void

    private let visiblePresets = VoicePreset.visibleCases
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(visiblePresets) { preset in
                Button {
                    if preset.availableInV1 {
                        onSelect(preset)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(preset.title)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            if !preset.availableInV1 {
                                Text("개발 중")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(preset.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(cardFill(for: preset))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(cardStroke(for: preset), lineWidth: preset == selectedPreset ? 1.5 : 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!preset.availableInV1)
            }
        }
    }

    private func cardFill(for preset: VoicePreset) -> Color {
        if preset == selectedPreset {
            return Color.accentColor.opacity(0.16)
        }
        if !preset.availableInV1 {
            return Color(nsColor: .controlBackgroundColor).opacity(0.65)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private func cardStroke(for preset: VoicePreset) -> Color {
        if preset == selectedPreset {
            return .accentColor
        }
        return Color.black.opacity(0.08)
    }
}

private struct ShortcutBindingEditor: View {
    @Binding var shortcut: ShortcutBinding
    @State private var isRecordingPrimaryKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("수정자 키")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(ShortcutModifier.allCases) { modifier in
                        Toggle(isOn: modifierBinding(modifier)) {
                            Text(modifier.symbol)
                                .font(.system(.headline, design: .rounded))
                        }
                        .toggleStyle(.button)
                        .help(modifier.title)
                    }
                    if !shortcut.modifiers.isEmpty {
                        Button("수정자 키 지우기") {
                            var next = shortcut
                            next.modifiers = []
                            shortcut = next
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("주 키")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PrimaryKeyInputField(
                    shortcut: $shortcut,
                    isRecording: $isRecordingPrimaryKey
                )
            }

            if !shortcut.modifiers.isEmpty {
                Text("현재 조합 키입니다(\(shortcut.displayLabel)). 단일 키 Enter만 보내려면 ⌘/⌃ 등을 켜지 말고, 또는 「수정자 키 지우기」를 누른 뒤 Enter를 선택하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modifierBinding(_ modifier: ShortcutModifier) -> Binding<Bool> {
        Binding(
            get: { shortcut.modifiers.contains(modifier) },
            set: { on in
                var next = shortcut
                next.setModifier(modifier, enabled: on)
                shortcut = next
            }
        )
    }

}

private struct PrimaryKeyInputField: View {
    @Binding var shortcut: ShortcutBinding
    @Binding var isRecording: Bool

    private var displayText: String {
        shortcut.keyCode == 0 ? "키보드 단축키를 바로 누르세요" : HIDUsage.name(for: shortcut.keyCode)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isRecording ? Color.accentColor : Color.black.opacity(0.12), lineWidth: isRecording ? 1.5 : 1)
                )

            KeyCaptureOverlay(
                shortcut: $shortcut,
                isRecording: $isRecording,
                onActivate: {
                    isRecording = true
                }
            )
            .padding(.trailing, 38)

            HStack(spacing: 8) {
                Image(systemName: isRecording ? "keyboard.badge.ellipsis" : "keyboard")
                    .foregroundStyle(isRecording ? Color.accentColor : Color.secondary)
                Text(displayText)
                    .font(.callout)
                    .foregroundStyle(shortcut.keyCode == 0 && !isRecording ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Spacer()

                Menu {
                    Button("키보드 단축키를 바로 누르세요") {
                        shortcut = ShortcutBinding()
                        isRecording = false
                    }
                    Divider()
                    ForEach(HIDUsage.allOptions, id: \.code) { option in
                        Button(option.name) {
                            var next = shortcut
                            next.keyCode = option.code
                            shortcut = next
                            isRecording = false
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("드롭다운 목록 펼치기")
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 36)
        .contentShape(Rectangle())
        .help("키를 바로 눌러 주 키를 설정하고, 화살표를 클릭하면 드롭다운 목록이 열립니다.")
    }
}

private struct KeyCaptureOverlay: NSViewRepresentable {
    @Binding var shortcut: ShortcutBinding
    @Binding var isRecording: Bool
    let onActivate: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        configure(nsView)
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    private func configure(_ view: KeyCaptureNSView) {
        view.onBeginRecording = {
            onActivate()
            isRecording = true
        }
        view.onCapture = { event in
            guard let hidCode = HIDUsage.hidCode(forMacKeyCode: event.keyCode) else {
                NSSound.beep()
                isRecording = false
                return
            }
            shortcut = ShortcutBinding(
                modifiers: shortcutModifiers(from: event.modifierFlags),
                keyCode: hidCode
            )
            isRecording = false
        }
        view.onCaptureModifier = { keyCode in
            guard let hidCode = HIDUsage.hidCode(forMacKeyCode: keyCode) else {
                NSSound.beep()
                isRecording = false
                return
            }
            shortcut = ShortcutBinding(modifiers: [], keyCode: hidCode)
            isRecording = false
        }
    }

    final class KeyCaptureNSView: NSView {
        var onBeginRecording: (() -> Void)?
        var onCapture: ((NSEvent) -> Void)?
        var onCaptureModifier: ((UInt16) -> Void)?
        private var pendingModifierCapture: DispatchWorkItem?

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onBeginRecording?()
        }

        override func keyDown(with event: NSEvent) {
            pendingModifierCapture?.cancel()
            pendingModifierCapture = nil
            onCapture?(event)
        }

        override func flagsChanged(with event: NSEvent) {
            onBeginRecording?()
            pendingModifierCapture?.cancel()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.control)
                || flags.contains(.option)
                || flags.contains(.shift)
                || flags.contains(.command)
                || flags.contains(.capsLock)
                || flags.contains(.function)
            else {
                return
            }

            let workItem = DispatchWorkItem { [weak self] in
                self?.onCaptureModifier?(event.keyCode)
                self?.pendingModifierCapture = nil
            }
            pendingModifierCapture = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
        }
    }
}

private func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> [ShortcutModifier] {
    var modifiers: [ShortcutModifier] = []
    if flags.contains(.control) { modifiers.append(.control) }
    if flags.contains(.option) { modifiers.append(.option) }
    if flags.contains(.shift) { modifiers.append(.shift) }
    if flags.contains(.command) { modifiers.append(.command) }
    return modifiers
}

private struct CanvasKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.12, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

private struct AhaKeyKeyboardCanvasView: View {
    let modeDraft: AhaKeyModeDraft
    let selectedPart: AhaKeyStudioPart
    let lightBarPreview: IDEState
    let switchTitle: String
    let dirtyParts: Set<AhaKeyStudioPart>
    let onSelect: (AhaKeyStudioPart) -> Void
    let onModeSwitch: () -> Void
    var onSwitchToggle: (() -> Void)? = nil
    var liveLightMode: Int? = nil
    var liveIDEStateValue: Int? = nil
    var switchState: Int = 1   // 0=auto, 1=manual; firmware uses for color/effect overrides
    /// 0x83 조회로 얻은 현재 mode의 flash 프레임 수: nil=아직 조회하지 않음/연결 안 됨, 0=사용자가 업로드하지 않음, >0=N 프레임 업로드됨
    var keyboardPictureFrameCount: Int? = nil

    @State private var modeSwitchPressed = false
    @State private var leverPressed = false

    private let baseWidth: CGFloat = 109
    private let baseHeight: CGFloat = 54

    var body: some View {
        GeometryReader { proxy in
            let drawingWidth = min(proxy.size.width, proxy.size.height * (baseWidth / baseHeight))
            let drawingHeight = drawingWidth * (baseHeight / baseWidth)

            ZStack {
                keyboardFrame(width: drawingWidth, height: drawingHeight)
            }
            .frame(width: drawingWidth, height: drawingHeight)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    @ViewBuilder
    private func keyboardFrame(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.95), Color(red: 0.92, green: 0.95, blue: 0.98)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.1), lineWidth: 1.2)
                )
                .shadow(color: .black.opacity(0.08), radius: 18, y: 14)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                .padding(12)

            VStack {
                Spacer()
            }

            // 나사를 진짜 "모서리 안쪽"으로 옮기고 지름을 4.8 → 3.6으로 줄였다:
            // 예전 위치 (8,8)/(8,46)은 키 회색 배경 사각형과 라이트바/Key1 경계선에 스치거나 겹쳤다.
            // 새 위치는 각 나사가 라이트바/키 회색 배경/Key 경계로부터 기준 단위 3개 이상 여유를 둔다.
            ForEach(Array([CGPoint(x: 5.5, y: 5.5), CGPoint(x: 103.5, y: 5.5), CGPoint(x: 5.5, y: 48.5), CGPoint(x: 103.5, y: 48.5)].enumerated()), id: \.offset) { _, point in
                Circle()
                    .stroke(Color.black.opacity(0.14), lineWidth: 1.2)
                    .background(Circle().fill(Color.white.opacity(0.4)))
                    .frame(width: scaled(3.6, in: width), height: scaled(3.6, in: width))
                    .position(position(point.x, point.y, width: width, height: height))
            }

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                .frame(width: scaled(4.2, in: width), height: scaled(12, in: width))
                .position(position(3.8, 28, width: width, height: height))

            // 키 회색 배경: 크기를 조금 줄여 라이트바 선택 상태 그림자의 영향 범위보다 확실히 낮게 둔다(기준 단위 5개 이상)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.035))
                .frame(width: scaled(67, in: width), height: scaled(21, in: width))
                .position(position(43.8, 38.5, width: width, height: height))

            ledBarButton(width: width, height: height)
            oledButton(width: width, height: height)
            keyButton(for: .voice, width: width, height: height)
            keyButton(for: .approve, width: width, height: height)
            keyButton(for: .reject, width: width, height: height)
            keyButton(for: .submit, width: width, height: height)
            modeSwitchKey(width: width, height: height)
            switchButton(width: width, height: height)
        }
    }

    // 펌웨어 ws2812_mode_e (psk_ws2812.h) → Swift 조명 효과 스타일
    private func lightModeToEffect(_ mode: Int) -> LightEffectStyle {
        switch mode {
        case 1: return .singleMove
        case 2: return .rainbowMove
        case 3: return .rainbowWave
        case 4: return .rainbowWaveSlow
        case 5: return .breathing
        case 6: return .middleLight
        default: return .off
        }
    }

    private static let firmwareRed = Color(red: 240 / 255, green: 32 / 255, blue: 41 / 255)
    private static let firmwareBlue = Color(red: 32 / 255, green: 80 / 255, blue: 255 / 255)

    private func firmwareLEDState(ideState: IDEState?, modeData: Int, switchState: Int) -> (LightEffectStyle, Color) {
        guard let s = ideState else {
            return (.off, Self.firmwareRed)
        }
        let effect = modeDraft.lightBar.effect(for: s)
        let color: Color = s == .preToolUse && switchState != 0 ? Self.firmwareBlue : Self.firmwareRed
        return (effect, color)
    }

    private func ledBarButton(width: CGFloat, height: CGFloat) -> some View {
        let part = AhaKeyStudioPart.lightBar
        // 살짝 위로, 폭은 안쪽으로 줄인다: 선택 상태 그림자(radius 10pt)가 키보드 내부 외곽선, 키 회색 배경, LCD와 기준 단위 5개 이상 여유를 갖게 한다
        let rect = frame(13.0, 4.5, 53.5, 8.6, width: width, height: height)
        let modeData = modeDraft.mode.rawValue
        let effect: LightEffectStyle
        let baseColor: Color
        if let live = liveLightMode {
            // BLE가 연결되고 mode 탭과 물리 workMode가 일치: 펌웨어가 보고한 ws2812_mode + claude_state를 그대로 신뢰한다
            effect = lightModeToEffect(live)
            let liveIDE: IDEState? = liveIDEStateValue.flatMap { IDEState(rawValue: UInt8($0)) }
            // 색: preToolUse + manual만 파랑이고 나머지는 모두 빨강(펌웨어 ws2812_single_color 설정과 동일)
            if let s = liveIDE, s == .preToolUse, switchState != 0 {
                baseColor = Self.firmwareBlue
            } else {
                baseColor = Self.firmwareRed
            }
        } else {
            // 오프라인/물리 단계가 아닌 상태 보기: 펌웨어 로직대로 update_claude_ws2812()를 시뮬레이션한다
            let previewIDE = lightBarPreview
            (effect, baseColor) = firmwareLEDState(ideState: previewIDE, modeData: modeData, switchState: switchState)
        }
        return Button {
            onSelect(part)
        } label: {
            VStack(spacing: rect.height * 0.12) {
                Text("라이트바")
                    .font(.system(size: max(rect.height * 0.18, 10), weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .center)

                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let colors = ledColors(effect: effect, time: context.date.timeIntervalSince1970, count: 10, baseColor: baseColor)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.12))
                        HStack(spacing: rect.width * 0.026) {
                            ForEach(0..<10, id: \.self) { index in
                                Capsule()
                                    .fill(colors[index])
                                    .frame(width: rect.width * 0.072, height: rect.height * 0.26)
                                    .shadow(color: colors[index].opacity(0.65), radius: 2.5)
                            }
                        }
                        .padding(.horizontal, rect.width * 0.04)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: rect.height * 0.48)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .modifier(HotspotChrome(part: part, selectedPart: selectedPart, dirtyParts: dirtyParts))
        }
        .buttonStyle(.plain)
        .position(x: rect.midX, y: rect.midY)
    }

    private func oledButton(width: CGFloat, height: CGFloat) -> some View {
        let part = AhaKeyStudioPart.oledDisplay
        let rect = frame(71.2, 7.7, 24.2, 13.4, width: width, height: height)
        return Button {
            onSelect(part)
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.92))
                    oledInnerContent(rect: rect)
                }
                // 오른쪽 위 배지: 키보드 flash의 실제 상태를 반영한다
                pictureStateBadge(rect: rect)
            }
            .frame(width: rect.width, height: rect.height)
            .modifier(HotspotChrome(part: part, selectedPart: selectedPart, dirtyParts: dirtyParts))
        }
        .buttonStyle(.plain)
        .position(x: rect.midX, y: rect.midY)
    }

    @ViewBuilder
    private func pictureStateBadge(rect: CGRect) -> some View {
        if let count = keyboardPictureFrameCount {
            let isUploaded = count > 0
            let label = isUploaded ? "✓ \(count) 프레임 업로드됨" : "업로드 안 됨"
            Text(label)
                .font(.system(size: max(rect.height * 0.11, 8), weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, rect.width * 0.04)
                .padding(.vertical, rect.height * 0.02)
                .background(
                    Capsule()
                        .fill(isUploaded ? Color.green.opacity(0.85) : Color.gray.opacity(0.85))
                )
                .padding(rect.width * 0.025)
        }
    }

    /// 실제 LCD는 160×80(2:1)이다. slot 중앙에 2:1 비율의 "화면 영역"을 두어 내용을 렌더링하고,
    /// 주변에는 키보드 검은 케이스를 외곽으로 남긴다. 이미지 / 자리표시자 모두 화면 영역 안에서 .fit 되어 범위를 넘지 않고 잘리지도 않는다.
    private func screenInnerSize(for rect: CGRect) -> CGSize {
        let screenAspect: CGFloat = 2.0
        if rect.width / rect.height >= screenAspect {
            let h = rect.height * 0.86
            return CGSize(width: h * screenAspect, height: h)
        } else {
            let w = rect.width * 0.86
            return CGSize(width: w, height: w / screenAspect)
        }
    }

    private func oledInnerContent(rect: CGRect) -> some View {
        let size = screenInnerSize(for: rect)
        return ZStack {
            Color.clear
            screenBody(screenWidth: size.width, screenHeight: size.height)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func screenBody(screenWidth: CGFloat, screenHeight: CGFloat) -> some View {
        if let gifPath = modeDraft.oled.localAssetPath {
            // .id(gifPath)는 경로가 바뀔 때 SwiftUI가 뷰를 폐기하고 다시 만들도록 강제한다.
            // 그러지 않으면 예전 경로의 @State frames/currentFrame/timer가 새 경로와 어긋나,
            // Mode를 바꾸는 순간 캔버스가 이전 단계 GIF의 한 프레임을 렌더링한다(claude / cursor가 섞인다).
            AnimatedGIFView(path: gifPath, fps: modeDraft.oled.framesPerSecond)
                .id(gifPath)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.6), Color.black.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(alignment: .center, spacing: 2) {
                    if modeDraft.mode == .mode0 {
                        HStack(spacing: 4) {
                            Image(systemName: "cloud.fill")
                                .font(.system(size: screenHeight * 0.24, weight: .semibold))
                                .foregroundStyle(Color.orange.opacity(0.92))
                            Text(modeDraft.mode.title)
                                .font(.system(size: screenHeight * 0.20, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Text("기본 애니메이션")
                            .font(.system(size: screenHeight * 0.18))
                            .foregroundStyle(.white.opacity(0.55))
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: {
                                if #available(macOS 13, *) { "sparkles.rectangle.stack" } else { "rectangle.stack" }
                            }())
                                .font(.system(size: screenHeight * 0.22, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.78))
                            Text("업로드 안 됨")
                                .font(.system(size: screenHeight * 0.20, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Text("사용자 지정 대기 중")
                            .font(.system(size: screenHeight * 0.18))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(screenWidth * 0.04)
                .multilineTextAlignment(.center)
            }
        }
    }

    private func keyButton(for role: AhaKeyKeyRole, width: CGFloat, height: CGFloat) -> some View {
        let part = role.part
        let keyDraft = modeDraft.key(for: role)
        let specs: (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)
        switch role {
        case .voice:
            specs = (10.2, 29.2, 16.2, 16.8)
        case .approve:
            specs = (27.2, 29.2, 16.2, 16.8)
        case .reject:
            specs = (44.2, 29.2, 16.2, 16.8)
        case .submit:
            specs = (61.2, 29.2, 16.2, 16.8)
        }
        let rect = frame(specs.x, specs.y, specs.w, specs.h, width: width, height: height)
        return Button {
            onSelect(part)
        } label: {
            VStack(spacing: rect.height * 0.07) {
                ZStack {
                    RoundedRectangle(cornerRadius: rect.width * 0.18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color(red: 0.95, green: 0.96, blue: 0.98)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

                    keyIcon(for: role, size: rect.height * 0.28)
                }
                .frame(width: rect.width * 0.8, height: rect.height * 0.76)

                Text(keyDraft.description.isEmpty ? keyDraft.displaySummary : keyDraft.description)
                    .font(.system(size: rect.height * 0.11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: rect.width, height: rect.height)
            .modifier(HotspotChrome(part: part, selectedPart: selectedPart, dirtyParts: dirtyParts))
        }
        .buttonStyle(CanvasKeyButtonStyle())
        .position(x: rect.midX, y: rect.midY)
    }

    @ViewBuilder
    private func keyIcon(for role: AhaKeyKeyRole, size: CGFloat) -> some View {
        Image(systemName: role.systemImage)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(Color.black.opacity(0.88))
    }

    private func modeSwitchKey(width: CGFloat, height: CGFloat) -> some View {
        let rect = frame(78.9, 40.9, 8.0, 10.2, width: width, height: height)
        return Button {
            onModeSwitch()
        } label: {
            VStack(spacing: rect.height * 0.08) {
                ZStack {
                    RoundedRectangle(cornerRadius: rect.width * 0.2, style: .continuous)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: rect.width * 0.2, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: rect.height * 0.18, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.72))
                }
                .frame(width: rect.width * 0.78, height: rect.height * 0.5)

                Text("Mode")
                    .font(.system(size: rect.height * 0.1, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: rect.width, height: rect.height)
        }
        .buttonStyle(CanvasKeyButtonStyle())
        .position(x: rect.midX, y: rect.midY)
        .help("클릭해 Mode 전환(실물 키 시뮬레이션)")
    }

    private func switchButton(width: CGFloat, height: CGFloat) -> some View {
        let part = AhaKeyStudioPart.toggleSwitch
        let rect = frame(87.8, 35.6, 6.8, 10.6, width: width, height: height)
        return Button {
            onSelect(part)
            // 물리 레버가 고장 난 사용자를 위한 기능: 클릭하면 auto/manual이 토글된다.
            // 최신 펌웨어에서 0x91은 조명 효과 미리보기에 쓰이므로, 여기서는 훅 소프트웨어 오버라이드만 변경한다.
            onSwitchToggle?()
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: rect.width * 0.18, style: .continuous)
                        .fill(Color.black.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: rect.width * 0.18, style: .continuous)
                                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                        )
                    Capsule()
                        .fill(Color.white)
                        .frame(width: rect.width * 0.36, height: rect.height * 0.65)
                        .overlay(Circle().fill(Color.gray.opacity(0.24)).frame(width: rect.width * 0.28, height: rect.width * 0.28))
                        .offset(y: switchTitle == "자동 승인" ? -rect.height * 0.08 : rect.height * 0.12)
                }
                .frame(width: rect.width * 0.58, height: rect.height * 0.78)

                Text(switchTitle)
                    .font(.system(size: rect.height * 0.12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: rect.width, height: rect.height)
            .modifier(HotspotChrome(part: part, selectedPart: selectedPart, dirtyParts: dirtyParts))
        }
        .buttonStyle(CanvasKeyButtonStyle())
        .position(x: rect.midX, y: rect.midY)
    }

    private func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: x / baseWidth * width,
            y: y / baseHeight * height,
            width: w / baseWidth * width,
            height: h / baseHeight * height
        )
    }

    private func position(_ x: CGFloat, _ y: CGFloat, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: x / baseWidth * width, y: y / baseHeight * height)
    }

    private func scaled(_ value: CGFloat, in width: CGFloat) -> CGFloat {
        value / baseWidth * width
    }

    private func ledColors(effect: LightEffectStyle, time: TimeInterval, count: Int,
                           baseColor: Color = Self.firmwareRed) -> [Color] {
        switch effect {
        case .off:
            return Array(repeating: Color.gray.opacity(0.15), count: count)
        case .middleLight:
            let center = Double(count - 1) / 2.0
            return (0..<count).map { i in
                let dist = abs(Double(i) - center) / center
                let pulse = (sin(time * 1.5) + 1.0) / 2.0 * 0.15
                return baseColor.opacity(0.2 + (1.0 - dist) * 0.65 + pulse)
            }
        case .singleMove:
            let period = 2.4
            let t = time.truncatingRemainder(dividingBy: period) / period
            let pos = t < 0.5 ? t * 2.0 * Double(count - 1) : (1.0 - (t - 0.5) * 2.0) * Double(count - 1)
            return (0..<count).map { i in
                let dist = abs(Double(i) - pos)
                let brightness = max(0.0, 1.0 - dist * 0.75)
                return baseColor.opacity(0.12 + brightness * 0.82)
            }
        case .breathing:
            let breath = (sin(time * Double.pi * 0.9) + 1.0) / 2.0
            return Array(repeating: baseColor.opacity(0.12 + breath * 0.78), count: count)
        case .rainbowMove:
            let period = 2.4
            let t = time.truncatingRemainder(dividingBy: period) / period
            let pos = t < 0.5 ? t * 2.0 * Double(count - 1) : (1.0 - (t - 0.5) * 2.0) * Double(count - 1)
            return (0..<count).map { i in
                let dist = abs(Double(i) - pos)
                let brightness = max(0.0, 1.0 - dist * 0.7)
                let hue = (Double(i) / Double(count) + time * 0.25).truncatingRemainder(dividingBy: 1.0)
                return Color(hue: hue, saturation: 1.0, brightness: 0.15 + brightness * 0.85)
            }
        case .rainbowWave:
            return (0..<count).map { i in
                let hue = (Double(i) / Double(count) + time * 0.4).truncatingRemainder(dividingBy: 1.0)
                return Color(hue: hue, saturation: 1.0, brightness: 0.9)
            }
        case .rainbowWaveSlow:
            return (0..<count).map { i in
                let hue = (Double(i) / Double(count) + time * 0.14).truncatingRemainder(dividingBy: 1.0)
                return Color(hue: hue, saturation: 1.0, brightness: 0.9)
            }
        case .typingRipple:
            let center = Double(count - 1) / 2.0
            let phase = time.truncatingRemainder(dividingBy: 1.6) / 1.6
            let rippleRadius = phase * center * 1.8
            return (0..<count).map { i in
                let dist = abs(Double(i) - center)
                let wave = max(0, 1.0 - abs(dist - rippleRadius) * 0.8)
                return baseColor.opacity(0.1 + wave * 0.85)
            }
        case .comet:
            let period = 1.8
            let t = time.truncatingRemainder(dividingBy: period) / period
            let pos = t * Double(count + 3) - 1.5
            return (0..<count).map { i in
                let dist = Double(i) - pos
                let tail = dist >= 0 ? 0.0 : max(0, 1.0 + dist * 0.25)
                let head = dist >= 0 && dist < 1.5 ? max(0, 1.0 - dist * 0.65) : 0.0
                return baseColor.opacity(0.08 + max(tail, head) * 0.88)
            }
        case .scanBar:
            let period = 2.0
            let t = time.truncatingRemainder(dividingBy: period) / period
            let pos = t < 0.5 ? t * 2.0 * Double(count - 1) : (1.0 - (t - 0.5) * 2.0) * Double(count - 1)
            return (0..<count).map { i in
                let dist = abs(Double(i) - pos)
                let brightness = dist < 1.5 ? 1.0 - dist * 0.3 : 0.0
                return baseColor.opacity(0.08 + max(0, brightness) * 0.88)
            }
        case .pulseCenter:
            let center = Double(count - 1) / 2.0
            let pulse = (sin(time * Double.pi * 2.5) + 1.0) / 2.0
            return (0..<count).map { i in
                let dist = abs(Double(i) - center) / center
                let intensity = pulse * max(0, 1.0 - dist * 0.8)
                return baseColor.opacity(0.08 + intensity * 0.88)
            }
        case .warningBlink:
            let blink = sin(time * Double.pi * 4.0) > 0 ? 0.9 : 0.1
            let orange = Color(red: 1.0, green: 0.6, blue: 0.0)
            return Array(repeating: orange.opacity(blink), count: count)
        case .successSweep:
            let green = Color(red: 0.1, green: 0.85, blue: 0.3)
            let progress = time.truncatingRemainder(dividingBy: 2.0) / 2.0
            let fillPos = progress * Double(count + 2) - 1
            return (0..<count).map { i in
                let lit = Double(i) <= fillPos ? 1.0 : 0.0
                return green.opacity(0.08 + lit * 0.88)
            }
        case .blueThinking:
            let blue = Color(red: 0.2, green: 0.5, blue: 1.0)
            return (0..<count).map { i in
                let wave = (sin(time * Double.pi * 0.8 + Double(i) * 0.6) + 1.0) / 2.0
                return blue.opacity(0.15 + wave * 0.75)
            }
        case .lowBattery:
            let red = Color(red: 1.0, green: 0.15, blue: 0.1)
            let pulse = (sin(time * Double.pi * 0.5) + 1.0) / 2.0
            return Array(repeating: red.opacity(0.1 + pulse * 0.6), count: count)
        case .chargingFlow:
            let green = Color(red: 0.1, green: 0.85, blue: 0.3)
            let period = 3.0
            let progress = time.truncatingRemainder(dividingBy: period) / period
            let fillPos = progress * Double(count)
            return (0..<count).map { i in
                let lit = Double(i) < fillPos ? 0.85 : 0.08
                return green.opacity(lit)
            }
        case .approvalWait:
            let amber = Color(red: 1.0, green: 0.75, blue: 0.2)
            let center = Double(count - 1) / 2.0
            let breath = (sin(time * Double.pi * 1.2) + 1.0) / 2.0
            let centerBlink = sin(time * Double.pi * 3.0) > 0 ? 1.0 : 0.4
            return (0..<count).map { i in
                let dist = abs(Double(i) - center) / center
                let isCenter = dist < 0.2
                let intensity = isCenter ? centerBlink : breath * (1.0 - dist * 0.5)
                return amber.opacity(0.1 + intensity * 0.8)
            }
        }
    }

    private func openNativeSpeechPrivacySettings() {
        openNativeSpeechPrivacySettingsURL()
    }
}

private struct AnimatedGIFView: View {
    let path: String
    let fps: Int

    @State private var frames: [NSImage] = []
    @State private var currentFrame = 0
    @State private var gifTimer: Timer? = nil

    var body: some View {
        Group {
            if !frames.isEmpty, currentFrame >= 0, currentFrame < frames.count {
                Image(nsImage: frames[currentFrame])
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear { loadFrames() }
        .onDisappear {
            gifTimer?.invalidate()
            gifTimer = nil
        }
    }

    private func loadFrames() {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return }
        var images: [NSImage] = []
        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            images.append(NSImage(cgImage: cgImage, size: .zero))
        }
        frames = images
        currentFrame = 0
        guard count > 1 else { return }
        let interval = 1.0 / Double(max(fps, 1))
        gifTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            currentFrame = (currentFrame + 1) % max(1, frames.count)
        }
    }
}

private func openNativeSpeechPrivacySettingsURL() {
    let candidates = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
        "x-apple.systempreferences:com.apple.Siri-Settings.extension",
        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.security?Privacy"
    ]

    openFirstAvailableSystemSettingsURL(candidates)
}

/// 입력 모니터링 / 손쉬운 사용 / 마이크와 음성 전사: 시스템은 「거부됨」 상태이거나 일부 버전에서 권한 창을 더 이상 띄우지 않는다. 직접 요청한 뒤 「개인정보 보호 및 보안」 관련 페이지를 열어, 사용자가 조작할 수 있는 피드백을 보장한다.
@MainActor
private func openCombinedVoicePrivacySettingsURL() {
    // 문서화되지 않은 `x-apple.systemsettings` + `.extension` 같은 조합은 쓰지 말 것. 일부 시스템에서는 「문서」로 인식되어
    // 설정으로 들어가지 못하고 「App Store에서 검색… / 응용 프로그램 선택」이 계속 뜬다.
    let candidates = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
        "x-apple.systempreferences:com.apple.Siri-Settings.extension",
        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.security?Privacy",
    ]
    if openFirstAvailableSystemSettingsURL(candidates) { return }
    let appPaths = [
        "/System/Applications/System Settings.app",
        "/System/Library/CoreServices/Applications/System Settings.app",
        "/System/Applications/System Preferences.app",
    ]
    for path in appPaths where FileManager.default.fileExists(atPath: path) {
        if NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            return
        }
    }
}

@discardableResult
private func openFirstAvailableSystemSettingsURL(_ candidates: [String]) -> Bool {
    for candidate in candidates {
        guard let url = URL(string: candidate) else { continue }
        if NSWorkspace.shared.open(url) {
            return true
        }
    }
    return false
}

@MainActor
private func openFirstMissingVoicePermissionSettings(
    bleManager: AhaKeyBLEManager,
    voiceRelay: VoiceRelayService,
    nativeSpeech: NativeSpeechTranscriptionService
) {
    if !bleManager.bluetoothPermissionGranted || !bleManager.bluetoothPoweredOn {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"]) { return }
    }
    if !nativeSpeech.microphoneGranted {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]) { return }
    }
    if !nativeSpeech.speechRecognitionGranted {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"]) { return }
    }
    if !nativeSpeech.siriEnabled {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.Siri-Settings.extension"]) { return }
    }
    if !nativeSpeech.dictationEnabled {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.Keyboard-Settings.extension"]) { return }
    }
    if !voiceRelay.accessibilityGranted {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]) { return }
    }
    if !voiceRelay.inputMonitoringGranted {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]) { return }
    }
    openCombinedVoicePrivacySettingsURL()
}

/// 먼저 시스템 API로 요청하고, 이어서 데스크탑에서 「개인정보 보호 및 보안」 관련 페이지를 연다. 입력 모니터링 / 손쉬운 사용은 대부분의 macOS 버전에서 iOS처럼 팝업을 띄우지 **않고**, 마이크와 음성도 「이미 선택한 뒤」에는 팝업이 뜨지 않으므로 반드시 시스템 설정 화면과 함께 안내해야 한다.
@MainActor
private func requestPermissionsThenOpenPrivacySettingsIfNeeded(
    bleManager: AhaKeyBLEManager,
    voiceRelay: VoiceRelayService,
    nativeSpeech: NativeSpeechTranscriptionService,
    delay: TimeInterval = 0.45
) {
    bleManager.refreshBluetoothAuthorization()
    voiceRelay.refreshPermissions(requestIfNeeded: true)
    nativeSpeech.refreshPermissions(requestIfNeeded: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        bleManager.refreshBluetoothAuthorization()
        openFirstMissingVoicePermissionSettings(bleManager: bleManager, voiceRelay: voiceRelay, nativeSpeech: nativeSpeech)
    }
}

/// 먼저 지연 재실행 도우미를 띄우고 나서 현재 프로세스를 종료한다. 예전 프로세스가 아직 살아 있을 때 `open -n`을 쓰지 말 것:
/// AppDelegate에 단일 인스턴스 보호가 있어, 새 인스턴스는 예전 인스턴스가 남아 있음을 확인하고 즉시 종료되어 "새 프로그램은 튕기고 옛 프로그램은 닫히지 않는" 상황이 된다.
private func relaunchApplicationForPermissionRefresh() {
    let bundlePath = Bundle.main.bundleURL.path
    let script = "sleep 0.8; /usr/bin/open \(shellQuoted(bundlePath))"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    do {
        try process.run()
    } catch {
        // 자동 재실행 도우미가 시작에 실패해도 현재 프로세스는 정상적으로 종료해야 한다. 사용자가 직접 다시 열 수 있다.
    }

    NSApp.windows.forEach { $0.close() }
    NSApp.terminate(nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if NSApp.isRunning {
            exit(0)
        }
    }
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

@MainActor
private func activateAhaKeyWindowForTextInput() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.keyWindow?.makeKeyAndOrderFront(nil)
    NSApp.mainWindow?.makeKeyAndOrderFront(nil)
}

/// 시스템 「개인정보 보호 및 보안」에서 권한을 바꾼 뒤, 확인 창으로 사용자를 안내한다: 종료하면 `open -n`이 같은 .app을 자동으로 다시 띄운다.
private struct RestartToApplyPermissionsButton: View {
    var title: String = "종료 후 다시 열기…"
    @State private var showConfirm = false

    var body: some View {
        Button(title) { showConfirm = true }
            .buttonStyle(.bordered)
            .help("시스템 설정에서 권한을 바꾼 뒤에는 이 앱을 재시작해야 감지 결과가 시스템과 일치합니다.")
            .alert("권한을 새로 고치려면 재시작이 필요합니다", isPresented: $showConfirm) {
                Button("취소", role: .cancel) {}
                Button("즉시 재시작") { relaunchApplicationForPermissionRefresh() }
            } message: {
                Text("이 앱을 먼저 종료한 뒤 자동으로 다시 엽니다. 다시 열면 「권한 다시 확인」이 최신 시스템 상태를 읽습니다.")
            }
    }
}

private struct DeviceInfoSheetContainer: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var bleManager: AhaKeyBLEManager

    var body: some View {
        VStack(spacing: 0) {
            deviceInfoTitleChrome
            sheetScrollView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            activateAhaKeyWindowForTextInput()
        }
    }

    @ViewBuilder
    private var sheetScrollView: some View {
        if #available(macOS 13.0, *) {
            ScrollView {
                sheetFormContent
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                sheetFormContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sheetFormContent: some View {
        DeviceInfoView(bleManager: bleManager)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var deviceInfoTitleChrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text("기기 정보 · 에이전트")
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Label("닫기", systemImage: "xmark.circle.fill")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()
        }
        .layoutPriority(1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 48)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct CloudAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var account = CloudAccountManager.shared
    @StateObject private var optimizer = AhaTypeTextOptimizer.shared
    @FocusState private var focusedLoginField: LoginField?

    private enum LoginField {
        case phone
        case password
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("클라우드 계정 · AhaType")
                    .font(.headline)
                Spacer()
                Button("닫기") { dismiss() }
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if account.isLoggedIn {
                        profileSection
                    } else {
                        loginSection
                    }

                    Divider()

                    ahaTypeSection
                }
                .padding(18)
            }
        }
        .alert("클라우드 계정", isPresented: Binding(
            get: { account.alertMessage != nil },
            set: { if !$0 { account.alertMessage = nil } }
        )) {
            Button("확인", role: .cancel) { account.alertMessage = nil }
        } message: {
            Text(account.alertMessage ?? "")
        }
        .onAppear {
            activateAhaKeyWindowForTextInput()
            optimizer.refreshFromDisk()
            if account.isLoggedIn {
                account.refreshProfile()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    activateAhaKeyWindowForTextInput()
                    focusedLoginField = .phone
                }
            }
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("로그인하면 AhaType 클라우드 대형 모델 정리 기능을 사용할 수 있습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("휴대폰 번호", text: $account.phone)
                .textFieldStyle(.roundedBorder)
                .focused($focusedLoginField, equals: .phone)
                .onTapGesture {
                    activateAhaKeyWindowForTextInput()
                    focusedLoginField = .phone
                }
                .onSubmit { focusedLoginField = .password }

            SecureField("비밀번호", text: $account.password)
                .textFieldStyle(.roundedBorder)
                .focused($focusedLoginField, equals: .password)
                .onTapGesture {
                    activateAhaKeyWindowForTextInput()
                    focusedLoginField = .password
                }
                .onSubmit { account.login() }

            Toggle("비밀번호 기억", isOn: $account.rememberPassword)

            HStack(spacing: 10) {
                Button("로그인") { account.login() }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.isBusy)
                Button("회원가입") { account.register() }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
            }

            Text(account.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account.profileSummary)
                .font(.callout)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 8) {
                quotaRow(title: "일간", value: account.quotaText("daily"))
                quotaRow(title: "주간", value: account.quotaText("weekly"))
                quotaRow(title: "월간", value: account.quotaText("monthly"))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack(spacing: 10) {
                Button("새로 고침") { account.refreshProfile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.isBusy)
                Button("계정 전환") {
                    account.prepareForRelogin()
                    focusedLoginField = .phone
                }
                .buttonStyle(.bordered)
                .disabled(account.isBusy)
                Button("로그아웃") { account.logout() }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
            }

            rechargeSection

            HStack(spacing: 10) {
                TextField("무료 쿠폰 코드", text: $account.couponCode)
                    .textFieldStyle(.roundedBorder)
                Button("교환") { account.redeemCoupon() }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
            }

            Text(account.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rechargeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("충전 및 구독")
                .font(.callout.weight(.semibold))

            HStack(spacing: 8) {
                ForEach(CloudRechargePlan.allCases) { plan in
                    Button {
                        account.createWechatOrder(plan: plan)
                    } label: {
                        VStack(spacing: 3) {
                            Text(plan.title)
                                .font(.caption.weight(.semibold))
                            Text(account.priceText(for: plan))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(plan.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
                }
            }

            if let order = account.paymentOrder {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        if let image = makeQRCodeImage(from: order.paymentURL) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 132, height: 132)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(order.plan.title) · \(order.amountText)")
                                .font(.caption.weight(.semibold))
                            Text("위챗으로 QR 코드를 스캔해 결제하세요. 결제가 완료되면 사용량이 자동으로 갱신됩니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("주문: \(order.outTradeNo)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            Text("상태: \(order.status)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("결제 링크 복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(order.paymentURL, forType: .string)
                        }
                        .buttonStyle(.bordered)

                        Button("입금 확인") {
                            account.refreshCurrentPaymentOrder()
                        }
                        .buttonStyle(.bordered)
                        .disabled(account.isBusy)

                        Button("주문 닫기") {
                            account.clearPaymentOrder()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    private var ahaTypeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { optimizer.isEnabled },
                set: { optimizer.setEnabled($0) }
            )) {
                Text("AhaType 클라우드 정리 사용")
                    .font(.callout.weight(.semibold))
            }
            .toggleStyle(.switch)

            Text("사용하도록 설정하면 macOS 기본 음성 인식이 끝난 뒤 클라우드 정리를 먼저 요청하고, 정리된 텍스트를 붙여넣습니다. 로그인하지 않았거나 만료되었거나 네트워크에 실패하면 원본 인식 결과로 자동 대체합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(optimizer.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(optimizer.lastQuotaSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func quotaRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func makeQRCodeImage(from text: String) -> NSImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private struct HotspotChrome: ViewModifier {
    let part: AhaKeyStudioPart
    let selectedPart: AhaKeyStudioPart
    let dirtyParts: Set<AhaKeyStudioPart>

    func body(content: Content) -> some View {
        let isSelected = selectedPart == part
        content
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    // 선택되지 않았을 때는 거의 보이지 않게 한다. 모든 hotspot에 회색 선을 두르면 인접 요소와 시각적으로 충돌한다
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.black.opacity(0.015),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if dirtyParts.contains(part) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .padding(8)
                }
            }
            // 선택 상태의 그림자를 10에서 6으로 줄여, 인접 요소로 번지는 발광 반경을 축소한다
            .shadow(color: isSelected ? Color.accentColor.opacity(0.18) : .clear, radius: 6)
    }
}

private struct OLEDMotionPreviewSheet: View {
    let modeTitle: String
    let assetPath: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(modeTitle) 애니메이션 미리보기")
                        .font(.system(size: 20, weight: .semibold))
                    Text("방금 선택한 GIF 애니메이션 파일을 보여줍니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.92))

                if let assetPath {
                    DraggableAnimatedGIFPreview(path: assetPath)
                        .padding(12)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: {
                            if #available(macOS 14, *) { "film.stack" } else { "film" }
                        }())
                            .font(.system(size: 34, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text("선택한 애니메이션이 없습니다")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                        .frame(minWidth: 480, minHeight: 240)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 460)
            .clipped()
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 380)
    }
}

/// 마우스로 누른 채 드래그(상하좌우)해 큰 이미지를 볼 수 있다. 스크롤 휠만으로는 가로 방향 탐색이 불편하기 때문이다.
private struct DraggableAnimatedGIFPreview: View {
    let path: String
    @State private var imageSize = CGSize(width: 480, height: 240)
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            AnimatedGIFPreview(path: path)
                .frame(width: imageSize.width, height: imageSize.height)
                .position(
                    x: viewportSize.width / 2 + offset.width,
                    y: viewportSize.height / 2 + offset.height
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let proposed = CGSize(
                                width: dragStartOffset.width + value.translation.width,
                                height: dragStartOffset.height + value.translation.height
                            )
                            offset = clampOffset(proposed, imageSize: imageSize, viewportSize: viewportSize)
                        }
                        .onEnded { _ in
                            dragStartOffset = offset
                        }
                )
                .onAppear {
                    reloadImageSizeAndResetOffset()
                }
                .onChange(of: path) { _ in
                    reloadImageSizeAndResetOffset()
                }
        }
    }

    private func reloadImageSizeAndResetOffset() {
        if let image = NSImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 {
            imageSize = image.size
        } else {
            imageSize = CGSize(width: 480, height: 240)
        }
        offset = .zero
        dragStartOffset = .zero
    }

    private func clampOffset(_ proposed: CGSize, imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        let maxX = max(0, (imageSize.width - viewportSize.width) / 2)
        let maxY = max(0, (imageSize.height - viewportSize.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}

private struct AnimatedGIFPreview: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        imageView.imageAlignment = .alignCenter
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = NSImage(contentsOfFile: path)
    }
}

// MARK: - 도움말 센터(내장 팝업)

private enum HelpTopic: String, CaseIterable, Identifiable {
    case overview = "개요"
    case modes = "네 가지 Mode"
    case canvas = "캔버스와 키"
    case toggleSwitch = "가상 레버"
    case oled = "LCD 화면"
    case lightBar = "라이트바 색상"
    case voice = "음성 입력"
    case diagnostics = "권한 진단"
    case faq = "자주 묻는 질문"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .overview: return "sparkles"
        case .modes: return "square.grid.3x1.below.line.grid.1x2"
        case .canvas: return "keyboard"
        case .toggleSwitch: return "switch.2"
        case .oled: return "play.tv"
        case .lightBar: return "rainbow"
        case .voice: return "mic.circle"
        case .diagnostics: return "stethoscope"
        case .faq: return "questionmark.bubble"
        }
    }
}

private struct HelpCenterSheet: View {
    let studioDraft: AhaKeyStudioDraft
    let selectedMode: AhaKeyModeSlot
    @ObservedObject var bleManager: AhaKeyBLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var topic: HelpTopic = .overview

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("AhaKey Studio 도움말 센터")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("완료") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.thinMaterial)

            Divider()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 188)
                    .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                ScrollView {
                    contentForTopic
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(topic)
            }
        }
        .frame(width: 880, height: 620)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(HelpTopic.allCases) { t in
                Button {
                    topic = t
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.iconName)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                        Text(t.rawValue)
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(t == topic ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(t == topic ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    @ViewBuilder
    private var contentForTopic: some View {
        switch topic {
        case .overview:      OverviewTopicView()
        case .modes:         ModesTopicView(selectedMode: selectedMode)
        case .canvas:        CanvasTopicView()
        case .toggleSwitch:  ToggleSwitchTopicView(bleManager: bleManager)
        case .oled:          OLEDTopicView(studioDraft: studioDraft, bleManager: bleManager)
        case .lightBar:      LightBarTopicView()
        case .voice:         VoiceTopicView()
        case .diagnostics:   DiagnosticsTopicView()
        case .faq:           FAQTopicView()
        }
    }
}

// MARK: 도움말 센터 - 공통 레이아웃

private struct HelpTitle: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(title).font(.title2.weight(.semibold))
            }
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
    }
}

private struct HelpSection: View {
    let title: String
    let text: String

    init(title: String, body text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 14)
    }
}

private struct HelpNote: View {
    let icon: String
    let tint: Color
    let text: String

    init(_ icon: String, tint: Color = .orange, body text: String) {
        self.icon = icon
        self.tint = tint
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(tint.opacity(0.25), lineWidth: 1)
                )
        )
        .padding(.vertical, 6)
    }
}

private struct HelpSwatch: View {
    let color: Color
    let label: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: 도움말 센터 - 각 장

private struct OverviewTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "sparkles",
                title: "개요",
                subtitle: "AhaKey Studio는 AhaKey 키패드의 macOS 설정 센터입니다"
            )

            HelpSection(
                title: "세 요소가 협력하는 방식",
                body: """
                • 메인 App(지금 쓰고 있는 것) — 설정 확인, 키 매핑 변경, LCD 애니메이션 업로드, 진단 조회
                • Agent 데몬 — 백그라운드에 상주하며 IDE의 Hook(Claude / Cursor / Codex / Kimi)을 수신하고, 현재 AI 상태를 BLE로 키보드에 전달
                • 키보드 펌웨어 — BLE 상태를 받아 라이트바 색상, LCD 표시, 키 매핑을 구동
                """
            )

            HelpSection(
                title: "BLE 점유는 한 번에 하나만",
                body: """
                같은 시점에 키보드의 BLE 연결을 가질 수 있는 프로세스는 하나뿐입니다.
                • 기본은 Agent가 점유 → Hook 상태가 실시간으로 키보드에 전달되고 자동 승인 체인이 동작합니다
                • 캔버스에서 '수정'을 누르면 → 메인 App이 잠시 인수해 LCD 애니메이션 업로드, 키 매핑 변경, 이미지 메타 정보 읽기가 가능합니다
                • '돌아가기'를 누르면 → 메인 App이 놓아주고 Agent가 자동으로 다시 가져갑니다
                """
            )

            HelpNote("info.circle.fill", tint: .blue, body: "처음 연결할 때는 '권한 진단'을 열어 권한 항목을 한 번 훑어보세요. Hook이 동작하지 않는 문제는 대부분 권한 때문입니다.")
        }
    }
}

private struct ModesTopicView: View {
    let selectedMode: AhaKeyModeSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "square.grid.3x1.below.line.grid.1x2",
                title: "네 가지 Mode",
                subtitle: "하드웨어 물리 키코드와 소프트웨어 설정이 함께 전환됩니다"
            )

            ForEach(AhaKeyModeSlot.allCases) { mode in
                modeCard(mode)
            }

            HelpNote("hand.tap.fill", tint: .accentColor, body: "전환 방법은 키보드의 Mode 레버, 메인 App 상단의 Picker, 캔버스의 Mode 버튼 세 가지입니다. 어느 하나를 바꾸면 나머지 두 곳도 함께 반영됩니다.")
        }
    }

    @ViewBuilder
    private func modeCard(_ mode: AhaKeyModeSlot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(mode.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(modeChipColor(mode), in: Capsule())
                Text(mode.name).font(.headline)
                if mode == selectedMode {
                    Text("현재").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            Text(mode.subtitle).font(.callout).foregroundStyle(.secondary)
            Text(mode.guidance).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .padding(.bottom, 6)
    }

    private func modeChipColor(_ mode: AhaKeyModeSlot) -> Color {
        switch mode {
        case .mode0: return Color.orange
        case .mode1: return Color.purple
        case .mode2: return Color.green
        case .mode3: return Color.blue
        }
    }
}

private struct CanvasTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "keyboard",
                title: "캔버스와 키",
                subtitle: "가운데 키보드처럼 보이는 그림이 실제 키패드의 1:1 미러이며, 모든 요소를 클릭할 수 있습니다"
            )

            HelpSection(title: "여섯 개의 핫스팟", body: "라이트바, LCD 화면, Key1(음성), Key2, Key3, Key4, 레버입니다. 클릭한 요소의 설정이 오른쪽 Inspector에 표시됩니다.")

            VStack(alignment: .leading, spacing: 10) {
                hotspotRow("rainbow", "라이트바", "키보드 상단의 WS2812 LED 8개를 점등합니다. 색상과 효과는 IDE Hook 상태를 따릅니다.")
                hotspotRow("play.tv", "LCD 화면", "0.96\" IPS 디스플레이입니다. GIF 애니메이션(160×80, RGB565)을 업로드할 수 있습니다.")
                hotspotRow("mic", "Key 1 / 음성 키", "macOS 기본 음성은 F18을 사용하고, Typeless나 위챗의 Fn 트리거는 F19를 사용합니다.")
                hotspotRow("checkmark.circle", "Key 2 / 승인 키", "Mode별 기본값은 Y / ↵ / ↵입니다. 매크로 시퀀스로 바꿀 수 있습니다.")
                hotspotRow("xmark.circle", "Key 3 / 거부 키", "Mode별 기본값은 N / ⌫ / Esc입니다. 매크로 시퀀스로 바꿀 수 있습니다.")
                hotspotRow("delete.left", "Key 4 / 삭제 키", "기본값은 Backspace이며, 짧게 누르기와 길게 누르기를 자유롭게 바꿀 수 있습니다.")
                hotspotRow("switch.2", "레버", "auto 승인과 manual 승인을 전환합니다. 자세한 내용은 '가상 레버' 장을 참고하세요.")
            }

            HelpNote("hand.point.up.left", tint: .accentColor, body: """
                요소를 클릭하면 Inspector에 '수정' 버튼이 나타납니다. '수정'을 누르면 BLE를 인수해 편집 상태로 들어가고, 변경을 마친 뒤 '키보드에 쓰기'를 누르면 설정이 기록됩니다. '돌아가기'를 누르면 편집을 끝냅니다.
                """)
        }
    }

    private func hotspotRow(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(desc).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct ToggleSwitchTopicView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "switch.2",
                title: "가상 레버",
                subtitle: "물리 레버가 고장났거나 소프트웨어로 제어하고 싶을 때 참고하세요"
            )

            HelpSection(title: "두 단계가 각각 하는 일", body: """
                • 자동 승인(switchState=0): Hook이 도구 호출이나 명령 요청을 가로챌 때마다 곧바로 통과시킵니다
                • 수동 승인(switchState=1): Hook이 결정을 터미널로 되돌려 주고, 직접 Key2/Key3을 눌러 승인하거나 거부합니다
                """)

            VStack(alignment: .leading, spacing: 8) {
                Text("캔버스의 레버를 누르면 세 가지 일이 일어납니다(전부 적용되는 것은 아닙니다).").font(.subheadline.weight(.medium))
                triggerRow(
                    num: "1",
                    title: "캔버스 낙관적 업데이트",
                    desc: "캔버스의 레버 위치와 상단 상태 바를 즉시 전환합니다. 시각적 지연이 없습니다",
                    works: true
                )
                triggerRow(
                    num: "2",
                    title: "Agent에 userSwitchOverride 설정 알림",
                    desc: "Hook의 auto-approve가 선택한 단계로 곧바로 전환됩니다. UserDefaults에 저장되므로 agent를 재시작해도 유지됩니다",
                    works: true
                )
                triggerRow(
                    num: "3",
                    title: "레버 소프트웨어 덮어쓰기",
                    desc: "최신 펌웨어에서 0x91은 조명 효과 미리보기에 쓰입니다. 가상 레버는 Hook의 auto-approve에만 영향을 주고 키보드의 sw_state는 더 이상 쓰지 않습니다.",
                    works: false,
                    requiresPatch: false
                )
            }

            HelpNote("exclamationmark.triangle.fill", tint: .orange, body: "가상 레버는 최신 펌웨어의 조명 효과 미리보기 명령과 충돌하지 않도록 0x91을 더 이상 사용하지 않습니다.")

            VStack(alignment: .leading, spacing: 8) {
                Text("현재 상태 요약").font(.subheadline.weight(.medium))
                stateRow("현재 적용값", "\(bleManager.agentSwitchState ?? bleManager.switchState)")
                stateRow("Agent 측 덮어쓰기", bleManager.agentSwitchState != nil ? "\(bleManager.agentSwitchState!)(덮어쓰는 중)" : "설정되지 않음(키보드 실제 값 사용)")
                stateRow("낙관적 표시 중", bleManager.optimisticSwitchOverride != nil ? "예(동기화 대기)" : "아니요")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    private func triggerRow(num: String, title: String, desc: String, works: Bool, requiresPatch: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(num)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(works ? Color.green : Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.medium))
                    if requiresPatch {
                        Text("펌웨어 지원 필요").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                    }
                }
                Text(desc).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func stateRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced())
        }
    }
}

private struct OLEDTopicView: View {
    let studioDraft: AhaKeyStudioDraft
    @ObservedObject var bleManager: AhaKeyBLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "play.tv",
                title: "LCD 화면",
                subtitle: "0.96\" IPS · 160×80 · RGB565 · 프레임 저장용 16 Mbit Flash 내장"
            )

            HelpSection(title: "기본 애니메이션(연결하면 자동 동기화)", body: """
                Mode 1 → claude_0.gif(출고 시 내장)
                Mode 2 → cursor.gif
                Mode 3 → codex.gif
                Mode 4 → 예비/사용자 지정

                키보드를 처음 연결했을 때 어떤 Mode의 flash 슬롯이 비어 있으면, 메인 App이 해당 번들 GIF를 키보드로 자동 전송합니다.
                """)

            HelpSection(title: "직접 만든 GIF로 바꾸기", body: """
                1. 캔버스에서 LCD 화면을 클릭하면 Inspector에 '수정'이 표시됩니다
                2. '수정'을 눌러 편집 상태로 들어갑니다(BLE 인수)
                3. 원하는 .gif를 선택합니다(200프레임·2MB 이하 권장). 가상 화면에서 먼저 미리 볼 수 있습니다
                4. 확인한 뒤 아래쪽 '키보드에 쓰기'를 눌러 기기에 한꺼번에 기록합니다
                """)

            HelpSection(title: "LCD 배지의 의미", body: """
                • 초록색 '✓ N프레임 업로드됨': 키보드 flash에 실제로 N프레임이 있습니다(직접 올렸거나 자동 동기화된 것)
                • 회색 '업로드되지 않음': 키보드 flash가 비어 있어 펌웨어 기본값을 표시하거나 비어 있는 상태입니다
                • 배지가 없음: 아직 BLE를 점유해 조회하지 않았습니다('수정'을 한 번 누르면 표시됩니다)
                """)

            VStack(alignment: .leading, spacing: 6) {
                Text("현재 키보드 flash의 Mode별 상태").font(.subheadline.weight(.medium))
                ForEach(AhaKeyModeSlot.allCases) { mode in
                    HStack {
                        Text(mode.title + " · " + mode.name).font(.callout)
                        Spacer()
                        if let s = bleManager.keyboardPictureStates[mode.rawValue] {
                            if s.frameCount > 0 {
                                Label("\(s.frameCount)프레임", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.callout)
                            } else {
                                Label("비어 있음", systemImage: "tray").foregroundStyle(.secondary).font(.callout)
                            }
                        } else {
                            Text("아직 조회하지 않음").font(.callout).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))

            HelpNote("info.circle.fill", tint: .blue, body: "Mode를 전환하면 LCD가 현재 키의 description 텍스트를 잠깐 표시했다가(기계적인 느낌의 효과) 약 1초 뒤 해당 Mode의 애니메이션으로 돌아갑니다.")
        }
    }
}

private struct LightBarTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "rainbow",
                title: "라이트바 색상",
                subtitle: "WS2812B 8개이며, 색상은 펌웨어의 update_claude_ws2812()가 결정하고 캔버스에 1:1로 재현됩니다"
            )

            HelpSection(title: "색상 대조표", body: "아래는 Mode 1(Claude)에서 펌웨어가 IDE state에 따라 실제로 동작하는 방식입니다.")

            VStack(alignment: .leading, spacing: 8) {
                HelpSwatch(
                    color: Color(red: 240/255, green: 32/255, blue: 41/255),
                    label: "0xF02029 (빨강)",
                    detail: "SessionStart / Stop / PostToolUse / PermissionRequest / UserPromptSubmit"
                )
                HelpSwatch(
                    color: Color(red: 32/255, green: 80/255, blue: 255/255),
                    label: "0x2050FF (파랑)",
                    detail: "PreToolUse — 도구 실행 시작(manual 단계 전용)"
                )
                HelpSwatch(
                    color: Color.gray.opacity(0.3),
                    label: "OFF (소등)",
                    detail: "SessionEnd — Claude 세션 종료"
                )
            }

            HelpSection(title: "Auto 단계의 무지개 덮어쓰기", body: """
                레버가 auto (switchState=0)일 때 펌웨어는 일부 state를 무지개 효과로 강제 전환합니다.
                • PreToolUse / PermissionRequest → 전체 무지개 웨이브
                • PostToolUse / UserPromptSubmit → 한 점씩 흐르는 무지개
                'Cursor를 실행하면 라이트바가 무지개로 바뀐다'고 느끼는 이유가 이것입니다. Cursor 전용 동작이 아니라 auto 단계의 시각적 표시입니다.
                """)

            HelpNote("exclamationmark.triangle.fill", tint: .orange, body: "Mode 1 / Mode 2에서는 펌웨어의 update_claude_ws2812()가 곧바로 return하므로 **라이트바가 IDE state에 따라 변하지 않고** 마지막으로 설정된 색상에 머무릅니다. 펌웨어 설계이며 버그가 아닙니다.")
        }
    }
}

private struct VoiceTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "mic.circle",
                title: "음성 입력",
                subtitle: "macOS 기본 음성은 F18을 쓰고, Fn / Globe 트리거는 F19를 씁니다"
            )

            HelpSection(title: "프리셋별 차이", body: """
                • macOS 기본 전사: 현지 언어로 인식하고, 인식이 끝나면 ⌘V로 커서 위치에 입력합니다. 어떤 입력창에서도 쓸 수 있습니다
                • Fn/Globe: Typeless, 위챗 음성, 더우바오 입력기에 사용합니다. 해당 소프트웨어에서 단축키를 Fn/Globe로 설정하세요
                • 사용자 지정 단축키: 키보드에만 기록하고, 고정된 음성 프리셋으로 인수하지 않습니다
                • AhaType: 먼저 인식한 뒤 프롬프트를 다듬습니다(로그인 필요)
                """)

            HelpSection(title: "짧게 누르기와 길게 누르기", body: """
                • 짧게 누르기(Toggle): 처음 누르면 시작하고 다시 누르면 끝납니다. 긴 문장에 적합합니다
                • 길게 누르기(Hold-to-speak): 누르고 있는 동안 녹음하고 떼면 멈춥니다. 위챗이나 더우바오처럼 '누르고 있어야' 하는 입력기에 적합합니다

                두 방식은 Key 1 Inspector의 '트리거 방식' 탭에서 전환합니다.
                """)

            HelpNote("hand.raised.fill", tint: .red, body: "마이크, 입력 모니터링, 손쉬운 사용 세 가지 권한을 모두 허용해야 합니다. '권한 진단'을 열면 시스템 설정의 해당 페이지로 바로 이동할 수 있습니다.")
        }
    }
}

private struct DiagnosticsTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "stethoscope",
                title: "권한 진단",
                subtitle: "하단 바의 '권한 진단' 버튼으로 엽니다(이 페이지가 아닙니다)"
            )

            HelpSection(title: "권한 목록", body: """
                • 블루투스: 키보드 연결에 반드시 필요합니다
                • 마이크: Apple 기본 전사, AhaType, 누르고 말하기 등 모든 음성 기능에 필요합니다
                • 입력 모니터링: 음성 키의 누름/떼기 이벤트를 감지합니다
                • 손쉬운 사용: 키보드 입력을 시뮬레이션합니다(⌘V로 텍스트 입력, Fn/Globe 주입 등)
                • 음성 인식: Apple 기본 전사에 필요합니다
                • Siri 및 받아쓰기(macOS 13+): 기본 전사의 의존 항목입니다
                """)

            HelpSection(title: "Agent 상태 점검", body: """
                '권한 진단'을 열면 Agent 자체 점검 결과를 볼 수 있습니다.
                • LaunchAgent 등록됨: login item이 설치되어 있습니다
                • 프로세스 실행 중: launchd가 ahakeyconfig-agent를 띄웠습니다
                • Hook 설정됨: Claude/Cursor/Codex/Kimi의 .json 및 settings에 ahakey-hook 참조가 추가되어 있습니다
                """)

            HelpSection(title: "전사 테스트는 어디에 있나", body: "권한 진단 팝업 안에 있습니다. 키보드를 연결하지 않고도 macOS 기본 전사가 인식되는지 확인할 수 있습니다. 전사가 실패하면 대부분 마이크 권한 문제이거나 언어 모델이 설치되지 않은 것입니다(시스템 설정 → Siri 및 받아쓰기 → 받아쓰기 언어).")
        }
    }
}

private struct FAQTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "questionmark.bubble",
                title: "자주 묻는 질문",
                subtitle: "아래에 없는 문제라면 GitHub 저장소에 issue를 올려 주세요"
            )

            faq(
                q: "Hook이 막아 주지 않고 AI가 계속 멈춰서 물어봅니다",
                a: """
                다음 순서로 확인하세요.
                1. Agent가 실행 중인가요? '권한 진단'을 열어 확인하세요
                2. Agent가 블루투스를 점유하고 있나요? 캔버스 상단에 연결됨으로 표시되고 편집 상태가 아니어야 합니다
                3. 레버가 auto 단계인가요? 상단 상태 바를 확인하고, 아니라면 캔버스의 레버를 눌러 auto로 바꾸세요
                4. IDE의 Hook 파일이 설정되어 있나요? '권한 진단'에서 Claude/Cursor/Codex/Kimi별 Hook 설치 상태를 볼 수 있습니다
                5. 설치 후 IDE를 재시작했나요? 특히 Kimi는 설치나 업그레이드 뒤 완전히 종료하고 다시 열어야 합니다
                """
            )

            faq(
                q: "캔버스의 라이트바 색상이 바뀌지 않습니다",
                a: """
                • 오른쪽 위가 '연결됨'인지 확인하세요
                • 지금 사용 중인 Mode로 전환하세요
                • 도구 호출을 한 번 발생시켜 Hook이 실제로 0x90을 키보드에 보내게 하세요
                • 수동 승인 단계 + Mode 1이라면 preToolUse는 파란색이고 나머지 상태는 빨간색입니다
                """
            )

            faq(
                q: "LCD 자동 동기화가 실행되지 않습니다",
                a: """
                자동 동기화는 메인 App이 BLE를 점유한 상태에서만 이미지 메타 정보를 조회합니다. 절차는 다음과 같습니다.
                1. '수정'을 최소 한 번 눌러 메인 App이 BLE를 인수하게 합니다
                2. 네 개 Mode의 0x83 조회가 끝난 뒤에 실행됩니다
                3. flash가 비어 있는(picLength=0) Mode에만 적용됩니다
                4. Inspector의 'GIF 업로드' 경로를 직접 바꾼 적이 있으면 그 Mode는 건너뜁니다(선택한 값을 덮어쓰지 않습니다)
                """
            )

            faq(
                q: "레버를 눌렀는데 키보드 조명 효과가 바뀌지 않습니다",
                a: """
                최신 펌웨어에서 0x91은 조명 효과 미리보기에 쓰입니다. 가상 레버는 Hook의 소프트웨어 덮어쓰기로만 동작하고 키보드의 sw_state에는 기록하지 않습니다.
                """
            )

            faq(
                q: "OTA 업그레이드가 있나요?",
                a: """
                계획 중이며 다음 버전에서 지원할 예정입니다. 현재 모든 펌웨어 업그레이드는 USB-ISP가 필요합니다(기기를 분해해 BOOT를 단락시킨 뒤 wchisp 사용). 자세한 방법은 저장소의 docs에 있습니다.
                """
            )
        }
    }

    private func faq(q: String, a: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.tint)
                    .padding(.top, 1)
                Text(q).font(.callout.weight(.medium))
            }
            Text(a)
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(.leading, 26)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.leading, 26).padding(.top, 4)
        }
        .padding(.vertical, 8)
    }
}
