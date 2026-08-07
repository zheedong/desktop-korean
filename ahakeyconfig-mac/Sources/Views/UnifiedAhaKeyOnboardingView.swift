import SwiftUI

enum UnifiedOnboardingStorage {
    static let completedKey = "AhaKey.UnifiedOnboarding.v2.completed"
    static let micGrantedKey = "AhaKey.UnifiedOnboarding.v2.micPreGranted"
    static let pasteGrantedKey = "AhaKey.UnifiedOnboarding.v2.pastePreGranted"
    static let currentStepKey = "AhaKey.UnifiedOnboarding.v2.currentStep"
}

struct AhaKeyOnboardingPermissionState: Equatable {
    var bluetoothPermissionGranted: Bool
    var bluetoothPoweredOn: Bool
    var inputMonitoringGranted: Bool
    var accessibilityGranted: Bool
    var microphoneGranted: Bool
    var speechRecognitionGranted: Bool
    var siriEnabled: Bool
    var dictationEnabled: Bool
    var voiceSummary: String
    var speechSummary: String
    var isRecording: Bool
    var transcriptPreview: String
    var lastCommittedText: String
    var speechStatusMessage: String

    var bluetoothReady: Bool {
        bluetoothPermissionGranted && bluetoothPoweredOn
    }

    var backgroundPermissionsGranted: Bool {
        inputMonitoringGranted && accessibilityGranted
    }

    var nativeSpeechPermissionsGranted: Bool {
        microphoneGranted && speechRecognitionGranted && siriEnabled && dictationEnabled
    }

    var allPermissionsGranted: Bool {
        bluetoothReady && backgroundPermissionsGranted && nativeSpeechPermissionsGranted
    }

    var canTrySpeechInput: Bool {
        microphoneGranted && speechRecognitionGranted
    }
}

struct AhaKeyOnboardingActions {
    var requestPermissions: () -> Void
    var requestPermission: (AhaKeyOnboardingPermissionKind) -> Void
    var recheckPermissions: () -> Void
    var openSystemSettings: () -> Void
    var toggleTryExperience: () -> Void
}

enum AhaKeyOnboardingPermissionKind {
    case bluetooth
    case inputMonitoring
    case accessibility
    case microphone
    case speechRecognition
    case siri
    case dictation
}

struct UnifiedAhaKeyOnboardingView: View {
    var permissionState: AhaKeyOnboardingPermissionState
    var actions: AhaKeyOnboardingActions
    var onCompleted: (_ micGranted: Bool, _ pasteGranted: Bool) -> Void

    @State private var step: AhaKeyOnboardingStep = .restoredProgress
    @State private var didRunTryExperience = false
    @State private var tryInputFieldText = ""
    @FocusState private var tryInputFieldFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 980
            let contentMinHeight = max(420, geometry.size.height - 116)
            VStack(spacing: 0) {
                topBar
                Divider().opacity(0.45)
                if compact {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            mainPanel
                            guidePanel
                        }
                        .padding(24)
                        .padding(.bottom, 12)
                    }
                } else {
                    ScrollView {
                        HStack(alignment: .top, spacing: 0) {
                            mainPanel
                                .frame(width: max(500, geometry.size.width * 0.48), alignment: .topLeading)
                                .padding(.horizontal, 48)
                                .padding(.vertical, 34)
                                .background(Color(nsColor: .textBackgroundColor))

                            Divider().opacity(0.45)

                            guidePanel
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.horizontal, 46)
                                .padding(.vertical, 34)
                                .background(Color(nsColor: .windowBackgroundColor))
                        }
                        .frame(maxWidth: .infinity, minHeight: contentMinHeight, alignment: .topLeading)
                    }
                }
                Divider().opacity(0.45)
                bottomNavigationBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .onAppear {
            resumeProgressIfReady()
        }
        .onChange(of: step) { newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: UnifiedOnboardingStorage.currentStepKey)
        }
        .onChange(of: permissionState) { _ in
            resumeProgressIfReady()
        }
        .onChange(of: permissionState.transcriptPreview) { newValue in
            if !newValue.isEmpty {
                didRunTryExperience = true
            }
        }
        .onChange(of: permissionState.lastCommittedText) { newValue in
            if !newValue.isEmpty {
                didRunTryExperience = true
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 18) {
            Spacer(minLength: 0)
            stepper
            Spacer(minLength: 0)
            Button("건너뛰기") {
                finish()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 22)
        }
        .padding(.vertical, 12)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // 상단 단계 내비게이션, 모든 단계를 클릭해 이동할 수 있습니다
    private var stepper: some View {
        HStack(spacing: 12) {
            ForEach(AhaKeyOnboardingStep.allCases) { item in
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            moveToStep(item)
                        }
                    } label: {
                        Text(item.title)
                            .font(.system(size: 15, weight: step == item ? .semibold : .medium))
                            .foregroundStyle(step == item ? Color.primary : Color.secondary)
                            .frame(width: 78, height: 34)
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(step == item ? Color.primary : Color.clear)
                                    .frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)

                    if item != AhaKeyOnboardingStep.allCases.last {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Main Panel

    @ViewBuilder
    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .welcome:
                welcomePanel
            case .dialogPermissions:
                dialogPermissionsPanel
            case .settingsPermissions:
                settingsPermissionsPanel
            case .tryInput:
                tryInputPanel
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var welcomePanel: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text("이 Mac에서 AhaKey 설정하기")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("키보드 연결, 백그라운드 음성 키 제어, macOS 기본 음성 기능, 그리고 실제 입력 체험까지 완료하세요.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 14) {
                onboardingCard(systemImage: "keyboard", title: "연결 및 제어", detail: "블루투스를 켜면 AhaKey Studio가 기본 음성 키를 제어하고 현재 Mode를 동기화합니다.")
                onboardingCard(systemImage: "lock.shield", title: "단계별 권한 부여", detail: "먼저 블루투스, 마이크, 음성 변환 등 팝업 권한을 허용한 뒤 Siri, 받아쓰기, 손쉬운 사용을 차례로 켜고, 마지막으로 입력 모니터링을 설정하고 앱을 재시작하세요.")
                onboardingCard(systemImage: "mic", title: "입력 체험", detail: "마지막으로 한 문장을 직접 말해 보면서 인식과 입력 경로가 모두 준비되었는지 확인하세요.")
            }
        }
    }

    private var dialogPermissionsPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(
                title: "1단계: 팝업으로 권한 허용",
                detail: "아래 권한은 「요청」을 누르면 시스템 대화상자가 나타나므로 허용만 눌러 주세요."
            )

            VStack(spacing: 12) {
                PermissionStatusRow(
                    title: "블루투스",
                    detail: bluetoothDetail,
                    granted: permissionState.bluetoothReady,
                    actionTitle: permissionState.bluetoothReady ? nil : "요청",
                    action: { actions.requestPermission(.bluetooth) }
                )
                PermissionStatusRow(
                    title: "마이크",
                    detail: "AhaKey Studio가 Apple 기본 음성 수집 기능을 사용하도록 허용합니다.",
                    granted: permissionState.microphoneGranted,
                    actionTitle: permissionState.microphoneGranted ? nil : "요청",
                    action: { actions.requestPermission(.microphone) }
                )
                PermissionStatusRow(
                    title: "음성 변환",
                    detail: "AhaKey Studio가 Apple 기본 음성 인식 기능을 사용하도록 허용합니다.",
                    granted: permissionState.speechRecognitionGranted,
                    actionTitle: permissionState.speechRecognitionGranted ? nil : "요청",
                    action: { actions.requestPermission(.speechRecognition) }
                )
            }

            HStack(spacing: 10) {
                Button("다시 확인") {
                    actions.recheckPermissions()
                }
                .buttonStyle(OnboardingSecondaryButtonStyle())
            }

        }
    }

    private var settingsPermissionsPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(
                title: "2단계: 시스템 설정에서 권한 부여",
                detail: "아래 권한은 시스템 설정에서 직접 켜야 합니다. 「설정 열기」를 누른 뒤 시스템 설정에서 설정하세요."
            )

            VStack(spacing: 12) {
                PermissionStatusRow(
                    title: "Siri",
                    detail: "시스템 설정 > Siri 및 Spotlight에서 Siri를 켜세요.",
                    granted: permissionState.siriEnabled,
                    actionTitle: permissionState.siriEnabled ? nil : "설정 열기",
                    action: { actions.requestPermission(.siri) }
                )
                PermissionStatusRow(
                    title: "받아쓰기",
                    detail: "시스템 설정 > 키보드 > 받아쓰기에서 받아쓰기를 켜세요.",
                    granted: permissionState.dictationEnabled,
                    actionTitle: permissionState.dictationEnabled ? nil : "설정 열기",
                    action: { actions.requestPermission(.dictation) }
                )
                PermissionStatusRow(
                    title: "손쉬운 사용",
                    detail: "AhaKey Studio가 음성 키를 macOS 기본 받아쓰기 또는 Fn/Globe 키로 변환하도록 허용합니다.",
                    granted: permissionState.accessibilityGranted,
                    actionTitle: permissionState.accessibilityGranted ? nil : "설정 열기",
                    action: { actions.requestPermission(.accessibility) }
                )
                PermissionStatusRow(
                    title: "입력 모니터링",
                    detail: "AhaKey Studio가 백그라운드에서 실물 음성 키를 감지하도록 허용합니다. 설정을 마친 뒤에는 보통 앱을 종료하고 다시 실행해야 합니다.",
                    granted: permissionState.inputMonitoringGranted,
                    actionTitle: permissionState.inputMonitoringGranted ? nil : "설정 열기",
                    action: {
                        UserDefaults.standard.set(AhaKeyOnboardingStep.tryInput.rawValue, forKey: UnifiedOnboardingStorage.currentStepKey)
                        actions.requestPermission(.inputMonitoring)
                    }
                )
            }

            HStack(spacing: 10) {
                Button("다시 확인") {
                    actions.recheckPermissions()
                }
                .buttonStyle(OnboardingSecondaryButtonStyle())
            }

        }
    }

    private var tryInputPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(
                title: "3단계: 입력 체험",
                detail: "블루투스로 키패드를 연결한 뒤 커서를 여기에 두고 마이크 키를 눌러 말해 보세요."
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(permissionState.isRecording ? Color.red : (permissionState.canTrySpeechInput ? Color.green : Color.orange))
                        .frame(width: 10, height: 10)
                    Text(permissionState.isRecording ? "녹음 중" : (permissionState.canTrySpeechInput ? "음성 준비 완료" : "음성 권한이 아직 없음"))
                        .font(.system(size: 15, weight: .semibold))
                }

                ZStack(alignment: .topLeading) {
                    if tryInputFieldText.isEmpty {
                        Text("블루투스로 키패드를 연결한 뒤 커서를 여기에 두고 마이크 키를 눌러 말해 보세요")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                    }
                    TextEditor(text: $tryInputFieldText)
                        .font(.system(size: 18, weight: .medium))
                        .focused($tryInputFieldFocused)
                        .modifier(HideScrollContentBackgroundModifier())
                }
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .onAppear { tryInputFieldFocused = true }

                Text(permissionState.speechStatusMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(permissionState.isRecording ? "종료하고 입력" : "말하기 시작") {
                    didRunTryExperience = true
                    actions.toggleTryExperience()
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(!permissionState.canTrySpeechInput)

                Button("다시 확인") {
                    actions.recheckPermissions()
                }
                .buttonStyle(OnboardingSecondaryButtonStyle())
            }

        }
    }

    // MARK: - Guide Panel（오른쪽, 그룹 강조）

    private var guidePanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(step.guideTitle)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.primary)
            Text(step.guideDetail)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                PermissionGroupSection(
                    groupLabel: "팝업 권한",
                    isHighlighted: step == .dialogPermissions,
                    items: [
                        ("블루투스", permissionState.bluetoothReady),
                        ("마이크", permissionState.microphoneGranted),
                        ("음성 변환", permissionState.speechRecognitionGranted),
                    ]
                )

                PermissionGroupSection(
                    groupLabel: "시스템 설정 권한",
                    isHighlighted: step == .settingsPermissions || step == .tryInput,
                    items: [
                        ("Siri", permissionState.siriEnabled),
                        ("받아쓰기", permissionState.dictationEnabled),
                        ("손쉬운 사용", permissionState.accessibilityGranted),
                        ("입력 모니터링", permissionState.inputMonitoringGranted),
                    ]
                )
            }

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 8) {
                Text("현재 상태")
                    .font(.system(size: 15, weight: .semibold))
                Text(permissionState.voiceSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(permissionState.speechSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Bottom Navigation（텍스트 보조 버튼）

    private var bottomNavigationBar: some View {
        HStack(spacing: 0) {
            Spacer()

            if step != .welcome {
                Button("이전") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        moveToStep(step.previous)
                    }
                }
                .buttonStyle(OnboardingTextButtonStyle())
            }

            Button(bottomNextTitle) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    goForward()
                }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .padding(.leading, step == .welcome ? 0 : 8)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var bottomNextTitle: String {
        switch step {
        case .welcome: return "설정 시작"
        case .tryInput: return "작업 공간으로 이동"
        default: return "다음"
        }
    }

    // MARK: - Helpers

    private var bluetoothDetail: String {
        if !permissionState.bluetoothPermissionGranted {
            return "AhaKey Studio가 AhaKey 키보드를 검색하고 연결하도록 허용합니다."
        }
        if !permissionState.bluetoothPoweredOn {
            return "권한은 허용되었지만 시스템 블루투스가 꺼져 있습니다. 제어 센터나 시스템 설정에서 켜세요."
        }
        return "블루투스를 사용할 수 있습니다. 키보드를 검색하고 연결할 수 있습니다."
    }

    private var manualSettingsPermissionsGranted: Bool {
        permissionState.siriEnabled &&
            permissionState.dictationEnabled &&
            permissionState.accessibilityGranted &&
            permissionState.inputMonitoringGranted
    }

    private var tryPreviewText: String {
        if !permissionState.transcriptPreview.isEmpty {
            return permissionState.transcriptPreview
        }
        if !permissionState.lastCommittedText.isEmpty {
            return permissionState.lastCommittedText
        }
        return "실시간 인식 결과나 최근에 입력된 내용이 여기에 표시됩니다."
    }

    private func sectionHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func onboardingCard(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func moveToStep(_ next: AhaKeyOnboardingStep) {
        step = next
        UserDefaults.standard.set(next.rawValue, forKey: UnifiedOnboardingStorage.currentStepKey)
    }

    private func resumeProgressIfReady() {
        guard step == .settingsPermissions, manualSettingsPermissionsGranted else { return }
        moveToStep(.tryInput)
    }

    private func goForward() {
        if step == .tryInput {
            finish()
            return
        }
        moveToStep(AhaKeyOnboardingStep(rawValue: min(AhaKeyOnboardingStep.tryInput.rawValue, step.rawValue + 1)) ?? .tryInput)
    }

    private func finish() {
        UserDefaults.standard.set(permissionState.microphoneGranted, forKey: UnifiedOnboardingStorage.micGrantedKey)
        UserDefaults.standard.set(permissionState.backgroundPermissionsGranted, forKey: UnifiedOnboardingStorage.pasteGrantedKey)
        UserDefaults.standard.removeObject(forKey: UnifiedOnboardingStorage.currentStepKey)
        onCompleted(permissionState.microphoneGranted, permissionState.backgroundPermissionsGranted)
    }
}

// MARK: - Permission Group Section（오른쪽 그룹 패널）

private struct PermissionGroupSection: View {
    var groupLabel: String
    var isHighlighted: Bool
    var items: [(String, Bool)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(groupLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.0) { title, granted in
                    summaryRow(title: title, granted: granted)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHighlighted ? Color.accentColor.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isHighlighted ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1.5)
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isHighlighted)
    }

    private func summaryRow(title: String, granted: Bool) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            Text(title)
                .font(.system(size: 14, weight: .medium))
            Spacer()
            Text(granted ? "켜짐" : "켜야 함")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Permission Status Row

private struct PermissionStatusRow: View {
    var title: String
    var detail: String
    var granted: Bool
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                    Text(granted ? "켜짐" : "켜야 함")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(granted ? Color.green : Color.orange)
                }
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                if granted {
                    Button(actionTitle) {
                        action()
                    }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                    .disabled(true)
                    .padding(.top, 1)
                } else {
                    Button(actionTitle) {
                        action()
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .padding(.top, 1)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Onboarding Steps

private enum AhaKeyOnboardingStep: Int, CaseIterable, Identifiable {
    static var restoredProgress: AhaKeyOnboardingStep {
        let rawValue = UserDefaults.standard.integer(forKey: UnifiedOnboardingStorage.currentStepKey)
        return AhaKeyOnboardingStep(rawValue: rawValue) ?? .welcome
    }

    case welcome
    case dialogPermissions
    case settingsPermissions
    case tryInput

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "환영"
        case .dialogPermissions: return "팝업 권한"
        case .settingsPermissions: return "시스템 설정"
        case .tryInput: return "체험 시작"
        }
    }

    var previous: AhaKeyOnboardingStep {
        AhaKeyOnboardingStep(rawValue: max(0, rawValue - 1)) ?? .welcome
    }

    var guideTitle: String {
        switch self {
        case .welcome: return "설정 경로"
        case .dialogPermissions: return "먼저 팝업으로 확인하는 권한부터 완료하세요"
        case .settingsPermissions: return "이어서 시스템 설정에서 켜세요"
        case .tryInput: return "마지막으로 실제 입력을 한 번 시도해 보세요"
        }
    }

    var guideDetail: String {
        switch self {
        case .welcome:
            return "온보딩은 권한 부여를 두 단계로 나눕니다. 먼저 시스템 팝업으로 확인하는 권한을 완료하고, 이어서 시스템 설정에서 나머지 권한을 켠 다음 마지막으로 입력을 체험합니다."
        case .dialogPermissions:
            return "블루투스, 마이크, 음성 변환은 팝업에서 바로 확인할 수 있습니다. 「요청」을 누른 뒤 팝업에서 허용하면 됩니다."
        case .settingsPermissions:
            return "Siri, 받아쓰기, 손쉬운 사용을 차례로 켜고 마지막으로 입력 모니터링을 켜세요. 입력 모니터링을 설정한 뒤에는 보통 앱을 종료하고 다시 실행해야 하며, 이 온보딩은 진행 상황을 기억합니다."
        case .tryInput:
            return "여기서는 앱 내부와 동일한 음성 처리 경로로 테스트하므로, 단순히 권한 상태만 보여 주지 않습니다."
        }
    }
}

// MARK: - Button Styles

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1.0), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor).opacity(configuration.isPressed ? 0.7 : 1.0), in: RoundedRectangle(cornerRadius: 7))
    }
}

// 보조 텍스트 버튼（하단 내비게이션 "이전"에 사용）
private struct OnboardingTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Color.secondary : Color.primary)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
    }
}

private struct HideScrollContentBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}
