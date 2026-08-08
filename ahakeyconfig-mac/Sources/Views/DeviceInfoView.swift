import SwiftUI

struct DeviceInfoView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager
    @StateObject private var agentManager = AgentManager.shared
    @State private var isEditingName = false
    @State private var editableName = ""
    @State private var showAgentLog = false
    @State private var agentLogPanel = 0
    @State private var logPanelContentTick = 0
    @State private var showAgentRequiredForAgentBLE = false

    var body: some View {
        Form {
            // MARK: - 기기 정보
            Section {
                HStack(spacing: 0) {
                    // 배터리와 펌웨어는 이 App이 직접 연결했을 때만 채워진다. 점유 주체가 에이전트이거나
                    // 아직 연결 전이면 초기값 0이 그대로 「0%」/「v0.0」로 보이므로 메인 화면과 같이 「—」로 표시한다.
                    infoCell("배터리", value: bleManager.isConnected ? "\(bleManager.batteryLevel)%" : "—")
                    Divider()
                    infoCell("펌웨어", value: bleManager.isConnected ? "v\(bleManager.firmwareMainVersion).\(bleManager.firmwareSubVersion)" : "—")
                    Divider()
                    infoCell("기기 이름", value: bleManager.deviceName ?? "—")
                }
                .frame(height: 50)

                HStack(spacing: 0) {
                    infoCell("작동 모드", value: workModeName(bleManager.workMode))
                    Divider()
                    infoCell("조명", value: lightModeName(bleManager.lightMode))
                    Divider()
                    infoCell("신호", value: "\(bleManager.signalStrength) dBm")
                }
                .frame(height: 50)
            } header: {
                Text("기기 정보")
            }

            // MARK: - 블루투스 연결(App과 Agent 중 하나 선택)
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("같은 시점에는 이 App 또는 Agent 중 하나만 키보드에 연결할 수 있습니다. 여기에서 전환하세요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(BluetoothConnectionOwner.allCases) { owner in
                            let selected = agentManager.bluetoothConnectionOwner == owner
                            let disableAgent = owner == .agentDaemon && !agentManager.isInstalled
                            Button {
                                if owner == .agentDaemon && !agentManager.isInstalled {
                                    showAgentRequiredForAgentBLE = true
                                } else {
                                    agentManager.setBluetoothConnectionOwner(owner, bleManager: bleManager)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(owner.title)
                                        .fontWeight(selected ? .semibold : .regular)
                                    Text(owner == .ahaKeyStudio
                                         ? "키 변경, LCD, 동기화, 로컬 조명 효과 테스트(macOS는 아직 USB 유선 설정을 지원하지 않습니다)"
                                         : "Claude/Cursor/Codex/Kimi Hook, 라이트 바 상태, 레버 조회")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(disableAgent)
                        }
                    }
                    CompatLabeledContent("현재") {
                        HStack(spacing: 6) {
                            Text(bleManager.isConnected ? "이 App이 블루투스에 연결됨" : "이 App이 연결되지 않음")
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(agentBluetoothStatusText())
                        }
                        .font(.callout)
                    }
                }
            } header: {
                Text("블루투스 연결")
            }
            .alert("먼저 Agent를 설치해야 합니다", isPresented: $showAgentRequiredForAgentBLE) {
                Button("확인", role: .cancel) {}
            } message: {
                Text("블루투스를 `ahakeyconfig-agent`에 넘기기 전에, 아래에서 「설치 후 활성화」를 완료해 LaunchAgent를 생성하세요.")
            }

            // MARK: - 레버 상태
            Section {
                HStack {
                    Text("레버 단계")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bleManager.switchState == 0 ? Color.green : Color.indigo)
                            .frame(width: 10, height: 10)
                            .animation(.easeInOut(duration: 0.1), value: bleManager.switchState)
                        Text(switchStateLabel(bleManager.switchState))
                    }
                }
            } header: {
                Text("레버 단계")
            }

            // MARK: - LED 상태 동기화
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(agentManager.isRunning ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text("LED가 IDE 상태를 따름")
                            Text(agentBluetoothShortLabel())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            hookBadge("Claude", installed: agentManager.claudeHooksInstalled)
                            hookBadge("Cursor", installed: agentManager.cursorHooksInstalled)
                            hookBadge("Codex", installed: agentManager.codexHooksInstalled)
                            hookBadge("Kimi", installed: agentManager.kimiHooksInstalled)
                        }
                        .font(.caption)
                    }
                    Spacer()
                    if agentManager.isInstalled {
                        Button(agentManager.isRunning ? "중지" : "시작") {
                            if agentManager.isRunning {
                                agentManager.stop()
                            } else {
                                agentManager.start()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(agentManager.bluetoothConnectionOwner == .ahaKeyStudio)
                        .help(agentManager.bluetoothConnectionOwner == .ahaKeyStudio
                              ? "현재 이 App이 블루투스를 사용 중이므로 Agent는 로드되지 않은 상태여야 합니다. 「블루투스 연결」에서 Agent를 선택한 뒤 데몬을 시작하거나 중지하세요."
                              : "launchd에서 Agent 프로세스를 로드해 시작하거나, 언로드해 중지합니다.")

                        Button("제거", role: .destructive) {
                            agentManager.uninstall(bleManager: bleManager)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        HStack(spacing: 8) {
                            if agentManager.isAgentOperationInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Button("설치 후 활성화") {
                                agentManager.install()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(agentManager.isAgentOperationInProgress)
                        }
                    }
                }

                if agentManager.isInstalled {
                    HStack(spacing: 10) {
                        Button("로그 보기") {
                            showAgentLog.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)

                        Spacer()

                        if agentManager.claudeHooksInstalled {
                            Button("Claude Hooks 제거") { agentManager.removeClaudeHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        } else {
                            Button("Claude Hooks 설치") { agentManager.installClaudeHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        if agentManager.cursorHooksInstalled {
                            Button("Cursor Hooks 제거") { agentManager.removeCursorHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        } else {
                            Button("Cursor Hooks 설치") { agentManager.installCursorHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        if agentManager.codexHooksInstalled {
                            Button("Codex Hooks 제거") { agentManager.removeCodexHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        } else {
                            Button("Codex Hooks 설치") { agentManager.installCodexHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        if agentManager.kimiHooksInstalled {
                            Button("Kimi Hooks 제거") { agentManager.removeKimiHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        } else {
                            Button("Kimi Hooks 설치") { agentManager.installKimiHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
            } header: {
                Text("LED 상태 동기화 · Hook 연동")
            } footer: {
                if !agentManager.isAgentBinaryPresentInBundle {
                    Text("배포 패키지에 ahakeyconfig-agent가 포함되어 있지 않아 데몬을 사용할 수 없습니다. 전체 「AhaKey Studio.app」을 사용하거나 개발자에게 문의하세요.")
                        .foregroundStyle(.orange)
                } else if agentManager.isInstalled, agentManager.bluetoothConnectionOwner == .ahaKeyStudio, !agentManager.isRunning {
                    Text("이 App이 블루투스를 사용 중입니다. Agent가 인계하도록 하려면 「블루투스 연결」에서 ahakeyconfig-agent를 선택하세요.")
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showAgentLog) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("진단 로그")
                            .font(.headline)
                        Spacer()
                        Button("닫기") { showAgentLog = false }
                    }
                    Picker("내용", selection: $agentLogPanel) {
                        Text("ahakeyconfig-agent 메인 로그").tag(0)
                        Text("도구 승인(permission-request.log)").tag(1)
                        Text("~/.cursor/hooks.json").tag(2)
                        Text("~/.cursor/cli-config.json").tag(3)
                        Text("~/.codex/config.toml").tag(4)
                        Text("Codex Hook(codex-hook.log)").tag(5)
                        Text("~/.kimi/config.toml").tag(6)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    HStack {
                        Button("이 페이지 새로 고침") {
                            logPanelContentTick += 1
                            agentManager.refresh()
                        }
                        if agentLogPanel == 3 {
                            Button("CLI + IDE 터미널 허용 목록 병합") {
                                let a = agentManager.mergeUserCursorCliConfigForShellAutoApprove()
                                let b = agentManager.mergeUserCursorPermissionsJsonForAgentTUI()
                                agentManager.agentUserAlert = a + "\n\n——\n\n" + b
                            }
                            .help("cli-config(CLI)와 permissions.json의 terminalAllowlist(Agent TUI 「Not in allowlist」 계층)에 기록합니다. 각각 공식 문서를 참고하세요. 모두 먼저 .ahakey.bak으로 백업합니다.")
                        }
                        Spacer()
                    }
                    .font(.caption)
                    ScrollView {
                        logPanelContent
                            .id(logPanelContentTick)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .frame(width: 540, height: 380)
            }

            // MARK: - LED 테스트
            if bleManager.isConnected {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        ForEach(Array(IDEState.allCases.enumerated()), id: \.offset) { _, state in
                            Button {
                                bleManager.updateIDEState(state)
                            } label: {
                                Text(state.label)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("LED 테스트")
                } footer: {
                    Text("버튼을 누르면 해당 상태를 키보드로 보내 LED 변화를 확인할 수 있습니다.")
                }
            }

            // MARK: - BLE 연결 상태
            Section {
                CompatLabeledContent("연결") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bleManager.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(bleManager.bleConnectionStatus)
                    }
                }
                CompatLabeledContent("기기 이름") {
                    if isEditingName {
                        HStack(spacing: 4) {
                            TextField("최대 15바이트", text: $editableName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                                .onSubmit { submitNameChange() }
                            Button("저장") { submitNameChange() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("취소") { isEditingName = false }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(bleManager.deviceName ?? "—")
                                .textSelection(.enabled)
                            if bleManager.isConnected {
                                Button {
                                    editableName = bleManager.deviceName ?? ""
                                    isEditingName = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                CompatLabeledContent("UUID") {
                    Text(bleManager.bleDeviceUUID)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack {
                    CompatLabeledContent("특성") {
                        HStack(spacing: 8) {
                            charBadge("DATA", ready: bleManager.dataCharReady)
                            charBadge("CMD", ready: bleManager.commandCharReady)
                            charBadge("NOTIFY", ready: bleManager.notifyCharReady)
                        }
                    }
                }
            } header: {
                Text("BLE 연결 상태")
            }

            // MARK: - 동작
            Section {
                HStack {
                    if !bleManager.isConnected {
                        Button(bleManager.isScanning ? "스캔 중…" : "기기 연결") {
                            bleManager.userInitiatedConnect()
                        }
                        .buttonStyle(.bordered)
                        .disabled(bleManager.isScanning || agentManager.bluetoothConnectionOwner == .agentDaemon)
                        .help(agentManager.bluetoothConnectionOwner == .agentDaemon
                              ? "현재 ahakeyconfig-agent가 블루투스를 사용하도록 선택되어 있습니다. 위쪽 「블루투스 연결」에서 AhaKey Studio로 전환하거나, 상단 바의 「기기 정보 · Agent」를 눌러 전환하세요."
                              : "이 App이 직접 키보드에 연결합니다.")
                    } else {
                        Button("상태 조회") {
                            bleManager.queryDeviceStatus()
                        }
                        .buttonStyle(.bordered)
                        .help("AA BB 00 CC DD를 보내 기기 상태를 조회합니다")

                        Button("프로토콜 탐지") {
                            bleManager.sendProbeCommands()
                        }
                        .buttonStyle(.bordered)
                        .help("기기에 탐지 명령을 보내 통신 로그의 응답을 확인합니다")

                        Spacer()

                        Button("연결 해제", role: .destructive) {
                            bleManager.disconnect()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            // MARK: - 통신 로그
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(bleManager.commLog) { entry in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(entry.formattedTime)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 80, alignment: .leading)
                                        Text(entry.message)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(entry.isError ? .red : .secondary)
                                            .textSelection(.enabled)
                                    }
                                    .id(entry.id)
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 150)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onChange(of: bleManager.commLog.count) { _ in
                            if let last = bleManager.commLog.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("전체 복사") {
                            let text = bleManager.commLog.map { "[\($0.formattedTime)] \($0.message)" }.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        Button("비우기") {
                            bleManager.clearLog()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.top, 4)
                }
            } header: {
                Text("통신 로그")
            }
        }
        // 「기기 정보」를 sheet로 표시할 때 상위 뷰의 `.alert`가 최상단에 표시되지 않아, Hooks 설치나 오류가 「반응 없음」처럼 보이는 경우가 있습니다. 여기에서 다시 바인딩해 확실히 표시되도록 합니다.
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

    }

    // MARK: - Components

    private func infoCell(_ label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    private func hookBadge(_ label: String, installed: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(installed ? .green : .secondary)
            Text("\(label) Hooks")
                .foregroundStyle(installed ? .primary : .secondary)
        }
    }

    private func charBadge(_ label: String, ready: Bool) -> some View {
        Text(label)
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(ready ? Color.green.opacity(0.15) : Color.gray.opacity(0.1))
            )
            .foregroundStyle(ready ? Color.green : Color.secondary)
    }

    private func switchStateLabel(_ state: Int) -> String {
        state == 0 ? "자동 승인" : "수동 승인"
    }

    private func agentBluetoothStatusText() -> String {
        if agentManager.isRunning && agentManager.isAgentBLEConnected { return "Agent가 블루투스에 연결됨" }
        if agentManager.isRunning { return "Agent 실행 중(BLE 미연결)" }
        if agentManager.isInstalled { return "Agent 실행되지 않음" }
        return "Agent 설치되지 않음"
    }

    private func agentBluetoothShortLabel() -> String {
        if agentManager.isRunning && agentManager.isAgentBLEConnected { return "블루투스 연결됨" }
        if agentManager.isRunning { return "BLE 미연결" }
        if agentManager.isInstalled { return "실행 안 됨" }
        return "Agent 미설치"
    }

    private func workModeName(_ mode: Int) -> String {
        switch mode {
        case 0: return "Mode 1 / Claude"
        case 1: return "Mode 2 / Cursor"
        case 2: return "Mode 3 / Codex"
        case 3: return "Mode 4 / custom"
        default: return "Mode \(mode)"
        }
    }

    private func lightModeName(_ mode: Int) -> String {
        switch mode {
        case 0: return "꺼짐"
        case 1: return "상시 점등"
        case 2: return "호흡"
        default: return "\(mode)"
        }
    }

    @ViewBuilder
    private var logPanelContent: some View {
        switch agentLogPanel {
        case 0:
            Text(agentManager.readLog())
        case 1:
            Text(agentManager.readPermissionRequestLog())
        case 2:
            Text(agentManager.readUserCursorHooksJsonForDisplay())
        case 3:
            Text(agentManager.readUserCursorCliConfigForDisplay())
        case 4:
            Text(agentManager.readUserCodexConfigForDisplay())
        case 5:
            Text(agentManager.readCodexHookLog())
        case 6:
            Text(agentManager.readUserKimiConfigForDisplay())
        default:
            Text("")
        }
    }

    private func submitNameChange() {
        let name = editableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        bleManager.changeDeviceName(name)
        isEditingName = false
    }
}
