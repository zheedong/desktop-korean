import Foundation
import os.log

private let log = Logger(subsystem: "lab.jawa.ahakeyconfig", category: "AgentManager")

// MARK: - 블루투스 점유 주체 (AhaKey Studio와 에이전트는 서로 독립된 프로세스이므로, 같은 시점에 키보드와 GATT 연결을 유지하는 쪽은 하나여야 한다)

/// 키보드와의 BLE 연결을 누가 점유하는지.
/// - `ahaKeyStudio`: 메인 앱이 연결하며, 키 리매핑·LCD·로컬 LED 테스트 등에 사용한다.
/// - `agentDaemon`: `ahakeyconfig-agent`만 실행하며(훅 → Unix 소켓 → 0x90 상태 쓰기, 레버 읽기), LaunchAgent가 실행한다.
enum BluetoothConnectionOwner: String, CaseIterable, Identifiable {
    case ahaKeyStudio
    case agentDaemon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ahaKeyStudio: return "AhaKey Studio"
        case .agentDaemon: return "ahakeyconfig-agent"
        }
    }

    var shortDetail: String {
        switch self {
        case .ahaKeyStudio: return "이 앱이 블루투스에 연결해 설정과 동기화에 사용합니다. 점유 주체가 앱일 때는 에이전트의 LaunchJob이 로드되지 않아 연결 충돌을 막습니다."
        case .agentDaemon: return "에이전트만 블루투스에 연결합니다. Claude/Cursor/Codex/Kimi Code CLI 훅이 라이트바와 레버 조회를 구동할 수 있으며, 이 앱에서는 키보드로 BLE 명령을 보낼 수 없습니다."
        }
    }
}

/// ahakeyconfig-agent 데몬 프로세스의 설치, 시작·정지, 상태 조회를 관리한다
@MainActor
final class AgentManager: ObservableObject {
    static let shared = AgentManager()

    private static let bluetoothOwnerKey = "lab.jawa.ahakeyconfig.bluetoothConnectionOwner"
    private static var didApplyLaunchBluetoothPreference = false

    @Published private(set) var isInstalled = false
    @Published private(set) var isRunning = false
    @Published private(set) var isAgentBLEConnected = false   // 에이전트의 BLE가 실제로 키보드에 연결되었는지
    @Published private(set) var hooksInstalled = false        // Claude / Cursor / Codex / Kimi 훅 중 하나라도 설치되었는지
    @Published private(set) var claudeHooksInstalled = false
    @Published private(set) var cursorHooksInstalled = false
    @Published private(set) var codexHooksInstalled = false
    @Published private(set) var kimiHooksInstalled = false

    /// 사용자가 선택한 블루투스 점유 주체 (UserDefaults에 저장하고 시작 시 한 번 적용)
    @Published var bluetoothConnectionOwner: BluetoothConnectionOwner = .agentDaemon

    /// 에이전트 설치 / 시작·정지, 훅 쓰기 등 작업의 결과 설명. 팝업을 닫으면 UI가 `nil`로 되돌린다.
    @Published var agentUserAlert: String?

    /// 설치 또는 launchctl 시작·정지를 실행 중임을 나타낸다. 화면에 진행 상태를 표시해 '눌렀는데 반응이 없다'는 상황을 막는다.
    @Published private(set) var isAgentOperationInProgress = false

    private let label = "lab.jawa.ahakeyconfig.agent"
    private let socketPath = "/tmp/ahakey.sock"

    private var launchAgentsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var plistPath: String {
        launchAgentsDirectoryURL.appendingPathComponent("\(label).plist").path
    }

    /// `~/Library/LaunchAgents`는 새로 만든 시스템 사용자에게는 아직 없을 수 있다. 먼저 생성한 뒤 plist를 써야 하며, 그렇지 않으면 'folder doesn't exist' 류의 오류가 난다.
    private func ensureLaunchAgentsDirectory() throws {
        try FileManager.default.createDirectory(at: launchAgentsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    private var agentBinaryPath: String {
        // 배포판에서는 앱 번들 내부의 에이전트를 우선 사용한다. `swift run AhaKeyConfig`는 번들 없는 실행 파일이므로,
        // 개발 중에는 같은 SwiftPM 빌드 디렉터리에 있는 형제 에이전트로 폴백해 소스에서 LaunchAgent를 설치하기 쉽게 한다.
        let bundled = "\(Bundle.main.bundlePath)/Contents/MacOS/ahakeyconfig-agent"
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        if Bundle.main.bundleURL.pathExtension != "app",
           let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            let development = executableDirectory.appendingPathComponent("ahakeyconfig-agent").path
            if FileManager.default.isExecutableFile(atPath: development) {
                return development
            }
        }
        return bundled
    }

    /// 화면 판단용: 번들에 에이전트 실행 파일이 들어 있는지 (배포 시 복사가 빠지면 LaunchAgent가 실제로 실행되지 않는다).
    var isAgentBinaryPresentInBundle: Bool {
        FileManager.default.isExecutableFile(atPath: agentBinaryPath)
    }

    /// 호환성: 구버전은 셸 스크립트로 전달했지만 이제는 에이전트 바이너리를 직접 호출한다. 제거 시 정리용으로 경로를 남겨 둔다.
    private var legacyHookScriptPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/hooks/ahakey-state.sh").path
    }

    private var claudeSettingsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json").path
    }

    private var cursorHooksPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cursor/hooks.json").path
    }

    private var codexConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml").path
    }

    private var codexAppCliPath: String {
        "/Applications/Codex.app/Contents/Resources/codex"
    }

    private var kimiConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi/config.toml").path
    }

    private var kimiCliFallbackRoot: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/uv/tools/kimi-cli").path
    }

    private var localBinDirectoryPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true).path
    }

    private var localCodexCliPath: String {
        (localBinDirectoryPath as NSString).appendingPathComponent("codex")
    }

    private var zshrcPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zshrc").path
    }

    /// `~/.cursor/cli-config.json`: Cursor **CLI**의 `permissions`(`Shell(...)` 등)와 `approvalMode`.
    private var cursorCliConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/cli-config.json").path
    }

    /// `~/.cursor/permissions.json`: IDE 안 **에이전트 터미널 TUI**의 `terminalAllowlist` (cli-config와 별개, 공식 문서 참고).
    private var cursorPermissionsJsonPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/permissions.json").path
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.bluetoothOwnerKey),
           let stored = BluetoothConnectionOwner(rawValue: raw) {
            bluetoothConnectionOwner = stored
        } else {
            bluetoothConnectionOwner = .agentDaemon
            UserDefaults.standard.set(BluetoothConnectionOwner.agentDaemon.rawValue, forKey: Self.bluetoothOwnerKey)
        }
        refresh()
    }

    // MARK: - 상태 갱신

    func refresh() {
        isInstalled = FileManager.default.fileExists(atPath: plistPath)
        isRunning = checkRunning()
        claudeHooksInstalled = detectClaudeHooksInstalled()
        cursorHooksInstalled = detectCursorHooksInstalled()
        codexHooksInstalled = detectCodexHooksInstalled()
        kimiHooksInstalled = detectKimiHooksInstalled()
        hooksInstalled = claudeHooksInstalled || cursorHooksInstalled || codexHooksInstalled || kimiHooksInstalled
        if isRunning {
            let socketPath = socketPath
            DispatchQueue.global(qos: .utility).async { [weak self, socketPath] in
                let bleConnected = Self.querySocketBLEConnected(socketPath: socketPath)
                DispatchQueue.main.async { self?.isAgentBLEConnected = bleConnected }
            }
        } else {
            isAgentBLEConnected = false
        }
    }

    /// 에이전트에 가상 레버 오버라이드 설정/해제를 알린다. fire-and-forget이며, 에이전트는:
    /// 1) UserDefaults에 저장해 유지한다
    /// 2) 공유 파일에 기록해 메인 앱이 즉시 확인할 수 있게 한다
    /// 3) 더 이상 구형 0x91을 보내지 않는다. 최신 펌웨어의 0x91은 조명 효과 미리보기에 쓰인다
    /// value=nil은 오버라이드 해제를 뜻한다 (실제 GPIO 값 읽기로 복귀).
    func sendSwitchOverride(_ value: UInt8?) {
        DispatchQueue.global(qos: .userInitiated).async { [socketPath] in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            socketPath.withCString { src in
                withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                    _ = strcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src)
                }
            }
            let ok = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard ok == 0 else { return }
            let valuePart: String = value.map { "\($0)" } ?? "null"
            let payload = "{\"cmd\":\"set_switch_override\",\"value\":\(valuePart)}\n"
            guard let data = payload.data(using: .utf8) else { return }
            _ = data.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return write(fd, base, ptr.count)
            }
            var buf = [UInt8](repeating: 0, count: 256)
            _ = read(fd, &buf, buf.count) // 응답을 받은 뒤 fd를 닫아, 에이전트가 처리하기 전에 reset되는 것을 막는다
        }
    }

    /// 에이전트 소켓에 status 명령을 보낸다. switchState가 null이 아니면 BLE가 키보드에 연결된 것이다.
    /// 동기로 실행되므로 백그라운드 스레드에서 호출해야 한다.
    nonisolated private static func querySocketBLEConnected(socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src)
            }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return false }

        guard let payload = "{\"cmd\":\"status\"}\n".data(using: .utf8) else { return false }
        let wrote = payload.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return write(fd, base, ptr.count)
        }
        guard wrote > 0 else { return false }

        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return false }

        guard let json = try? JSONSerialization.jsonObject(with: Data(buf[0..<n])) as? [String: Any] else {
            return false
        }
        return !(json["switchState"] is NSNull) && json["switchState"] != nil
    }

    // MARK: - 블루투스 점유 주체 (앱 ↔ 에이전트 중 하나)

    /// 메인 윈도우를 시작할 때 한 번 호출한다. 사용자의 지난 선택에 따라 앱이 키보드에 연결하거나 에이전트에 넘긴다 (앱을 자동으로 연결하지는 않는다).
    func applyStoredBluetoothPreferenceOnLaunch(bleManager: AhaKeyBLEManager) {
        guard !Self.didApplyLaunchBluetoothPreference else { return }
        Self.didApplyLaunchBluetoothPreference = true
        applyBluetoothOwner(bluetoothConnectionOwner, bleManager: bleManager, isLaunch: true)
    }

    /// 사용자가 '기기 정보'에서 점유 주체를 바꿀 때 호출한다.
    func setBluetoothConnectionOwner(_ owner: BluetoothConnectionOwner, bleManager: AhaKeyBLEManager) {
        guard owner != bluetoothConnectionOwner else { return }
        bluetoothConnectionOwner = owner
        UserDefaults.standard.set(owner.rawValue, forKey: Self.bluetoothOwnerKey)
        applyBluetoothOwner(owner, bleManager: bleManager, isLaunch: false)
    }

    private func applyBluetoothOwner(_ owner: BluetoothConnectionOwner, bleManager: AhaKeyBLEManager, isLaunch: Bool) {
        switch owner {
        case .ahaKeyStudio:
            bleManager.setSuppressedForAgentOwningKeyboard(false)
            unloadAgentLaunchJobRemovingSocket()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(isLaunch ? 700 : 600) * 1_000_000)
                guard !bleManager.isConnected, !bleManager.isScanning else { return }
                bleManager.connectAutomatically()
            }
        case .agentDaemon:
            bleManager.setSuppressedForAgentOwningKeyboard(true)
            bleManager.disconnect()
            guard isInstalled else {
                log.info("LaunchAgent가 설치되지 않아 블루투스를 에이전트에 넘길 수 없어, 임시로 앱 연결을 허용합니다")
                bleManager.setSuppressedForAgentOwningKeyboard(false)
                if !isLaunch {
                    agentUserAlert = "에이전트가 아직 설치되지 않아 '키보드 제어 중'으로 되돌릴 수 없습니다. '더 보기 → 기기 정보 · Agent'에서 에이전트를 먼저 설치하고 활성화하세요."
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(500) * 1_000_000)
                    if !bleManager.isConnected, !bleManager.isScanning {
                        bleManager.connectAutomatically()
                    }
                }
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(isLaunch ? 500 : 550) * 1_000_000)
                _ = runLaunchctlQuiet(["load", plistPath])
                _ = runLaunchctlQuiet(["start", label])
                self.refresh()
            }
        }
        if !isLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                self?.refresh()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.refresh()
            }
        }
    }

    /// launchd에서 에이전트를 언로드한다 (`stop`보다 확실하다. `KeepAlive`가 켜져 있으면 stop 후 프로세스가 곧바로 재시작되어 블루투스를 계속 점유한다).
    private func unloadAgentLaunchJobRemovingSocket() {
        guard FileManager.default.fileExists(atPath: plistPath) else {
            removeStaleSocketIfNeeded()
            return
        }
        _ = runLaunchctlQuiet(["unload", plistPath])
        removeStaleSocketIfNeeded()
    }

    private func removeStaleSocketIfNeeded() {
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    private func detectClaudeHooksInstalled() -> Bool {
        guard let settings = loadClaudeSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let eventHooks = value as? [[String: Any]] else { continue }
            for entry in eventHooks {
                let cmds = entry["hooks"] as? [[String: Any]] ?? []
                if cmds.contains(where: { isAhakeyHookCommand(($0["command"] as? String) ?? "") }) {
                    return true
                }
            }
        }
        return false
    }

    private func detectCursorHooksInstalled() -> Bool {
        guard let settings = loadCursorSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            if entries.contains(where: { isAhakeyHookCommand(($0["command"] as? String) ?? "") }) {
                return true
            }
        }
        return false
    }

    private func detectCodexHooksInstalled() -> Bool {
        guard let text = try? String(contentsOfFile: codexConfigPath, encoding: .utf8) else {
            return false
        }
        // AhaKey가 기록한 BEGIN/END 블록만으로 판정한다 (파일에서 ahakeyconfig-agent 리터럴이 여전히 매칭되는지에 의존하지 않아, 경로 별칭이나 앱 재설치로 경로가 바뀌었을 때 미설치로 오판하는 것을 막는다)
        if text.contains(codexHookBlockStart), text.contains(codexHookBlockEnd) {
            return true
        }
        return isAhakeyHookCommand(text)
            && (text.contains("hook Codex") || text.contains("CodexPermissionRequest"))
    }

    private func detectKimiHooksInstalled() -> Bool {
        guard let text = try? String(contentsOfFile: kimiConfigPath, encoding: .utf8) else {
            return false
        }
        return text.contains(kimiHookBlockStart)
            && text.contains(kimiHookBlockEnd)
            && isAhakeyHookCommand(text)
    }

    private func isAhakeyHookCommand(_ command: String) -> Bool {
        command.contains("ahakeyconfig-agent") || command.contains("ahakey-state")
    }

    private func checkRunning() -> Bool {
        // 소켓이 존재하는지 확인한다 (에이전트가 실행되면 생성된다)
        var statBuf = stat()
        return stat(socketPath, &statBuf) == 0 && (statBuf.st_mode & S_IFSOCK) != 0
    }

    // MARK: - LaunchAgent 설치/제거

    private func launchAgentPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(agentBinaryPath)</string>
                <string>--socket</string>
                <string>\(socketPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logFilePath)</string>
            <key>StandardErrorPath</key>
            <string>\(logFilePath)</string>
        </dict>
        </plist>
        """
    }

    @discardableResult
    private func writeLaunchAgentPlist() -> Bool {
        do {
            try ensureLaunchAgentsDirectory()
            try launchAgentPlist().write(toFile: plistPath, atomically: true, encoding: .utf8)
            log.info("LaunchAgent 설치 완료: \(self.plistPath)")
            return true
        } catch {
            log.error("LaunchAgent 설치 실패: \(error)")
            agentUserAlert = "LaunchAgent 설정 파일을 쓸 수 없습니다: \(error.localizedDescription)\n\n쓰려는 위치: \(plistPath)\n디렉터리 생성을 시도했습니다: \(launchAgentsDirectoryURL.path)\n계속 실패한다면 '~/Library'에 쓰기 권한이 있는지, 또는 이 기기의 관리 정책이 사용자 LaunchAgents를 금지하는지 확인하세요."
            return false
        }
    }

    private func installedAgentBinaryPath() -> String? {
        guard let plist = NSDictionary(contentsOfFile: plistPath),
              let args = plist["ProgramArguments"] as? [String],
              let first = args.first else { return nil }
        return first
    }

    private func launchAgentNeedsRewrite() -> Bool {
        installedAgentBinaryPath() != agentBinaryPath
    }

    func install() {
        agentUserAlert = nil
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }

        guard isAgentBinaryPresentInBundle else {
            agentUserAlert = "앱 번들에 실행 가능한 ahakeyconfig-agent가 없습니다(경로: …/Contents/MacOS/ahakeyconfig-agent). 배포 스크립트가 이 바이너리를 .app에 함께 포함했는지 확인하세요. 메인 프로그램만 있으면 데몬 프로세스를 설치할 수 없습니다."
            return
        }

        // 1. 먼저 기존 job을 언로드한 뒤 plist를 쓴다. 그러지 않으면 같은 Label이 이미 로드된 상태에서 launchd가 이전 ProgramArguments를 계속 붙들 수 있다.
        unloadAgentLaunchJobRemovingSocket()
        guard writeLaunchAgentPlist() else { return }

        // 2. 사용자가 에이전트에 블루투스를 맡기려는 경우에만 load한다 (그 외에는 plist만 써서, 설치 직후 GATT를 가로채지 않게 한다)
        var loadFailed = false
        if bluetoothConnectionOwner == .agentDaemon {
            let load = runLaunchctlDetailed(["load", plistPath])
            if !load.ok && !isBenignLaunchctlLoadMessage(load.mergedOutput) {
                loadFailed = true
                log.error("launchctl load failed: \(load.mergedOutput)")
                let out = load.mergedOutput.isEmpty ? "(출력 없음, 종료 코드가 0이 아님)" : load.mergedOutput
                agentUserAlert = "LaunchAgent의 plist는 저장되었지만 launchctl load가 실패해 데몬 프로세스가 로드되지 않았습니다.\n\nlaunchctl 출력:\n\(out)\n\n흔한 원인: 같은 Label이 이미 존재함, plist가 유효하지 않음, ~/Library/LaunchAgents에 쓰기 권한이 없음. '제거'를 먼저 누른 뒤 다시 설치하거나, '콘솔'에서 \(label)을 검색해 보세요."
            }
        }

        // 3. Claude / Cursor / Codex / Kimi 훅 설치 (에이전트 바이너리의 hook 하위 명령을 직접 가리킨다)
        let claudeLine = installClaudeHooks()
        let cursorLine = installCursorHooks()
        let codexLine = installCodexHooks()
        let kimiLine = installKimiHooks()

        refresh()

        var lines: [String] = []
        if bluetoothConnectionOwner == .agentDaemon, !loadFailed {
            lines.append("launchctl load를 실행했습니다. 몇 초 뒤에도 '실행 중'으로 표시되지 않으면 '로그 보기'를 누르세요.")
        }
        if !claudeLine.isEmpty { lines.append(claudeLine) }
        if !cursorLine.isEmpty { lines.append(cursorLine) }
        if !codexLine.isEmpty { lines.append(codexLine) }
        if !kimiLine.isEmpty { lines.append(kimiLine) }
        let tail = lines.joined(separator: "\n\n")
        if let err = agentUserAlert {
            agentUserAlert = err + (tail.isEmpty ? "" : "\n\n——\n\n" + tail)
        } else {
            agentUserAlert = tail.isEmpty ? "설치가 완료되었습니다." : tail
        }
    }

    func uninstall(bleManager: AhaKeyBLEManager? = nil) {
        // 1. LaunchAgent 제거
        _ = runLaunchctlQuiet(["unload", plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)

        // 2. 구버전 셸 훅 스크립트 정리 (있는 경우)
        try? FileManager.default.removeItem(atPath: legacyHookScriptPath)

        // 3. Claude / Cursor / Codex / Kimi 훅에서 ahakey 항목 제거 (구 셸 스크립트와 새 바이너리 명령을 모두 포함)
        removeClaudeHooks()
        removeCursorHooks()
        removeCodexHooks()
        _ = removeKimiHooks()

        // 4. 소켓 정리
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        bluetoothConnectionOwner = .ahaKeyStudio
        UserDefaults.standard.set(BluetoothConnectionOwner.ahaKeyStudio.rawValue, forKey: Self.bluetoothOwnerKey)
        bleManager?.setSuppressedForAgentOwningKeyboard(false)

        log.info("에이전트 + 훅 제거 완료")
        refresh()
    }

    /// 에이전트 데몬 프로세스를 시작한다 (먼저 Job이 load되었는지 확인한 뒤 start. '설치되었지만 실행되지 않음' 상태에 적합).
    func start() {
        guard isInstalled else {
            agentUserAlert = "LaunchAgent가 아직 설치되지 않았습니다. 먼저 '설치 후 활성화'를 누르세요."
            return
        }
        if launchAgentNeedsRewrite() {
            unloadAgentLaunchJobRemovingSocket()
            guard writeLaunchAgentPlist() else { return }
        }
        isAgentOperationInProgress = true
        let loadRes = runLaunchctlDetailed(["load", plistPath])
        let startRes = runLaunchctlDetailed(["start", label])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in
            guard let self else { return }
            self.isAgentOperationInProgress = false
            self.refresh()
            if !self.isRunning {
                var m = "launchctl load / start를 실행했지만 에이전트가 실행 중인 것으로 감지되지 않았습니다(/tmp/ahakey.sock이 생기지 않음).\n\n"
                if !loadRes.ok && !isBenignLaunchctlLoadMessage(loadRes.mergedOutput) {
                    m += "load:\n\(loadRes.mergedOutput.isEmpty ? "(출력 없음)" : loadRes.mergedOutput)\n\n"
                }
                if !startRes.ok {
                    m += "start:\n\(startRes.mergedOutput.isEmpty ? "(출력 없음)" : startRes.mergedOutput)\n\n"
                }
                m += "'로그 보기'를 눌러 \(self.logFilePath)를 확인하세요. 또한 시스템 '개인정보 보호 및 보안'에서 이 앱의 블루투스 사용을 허용했는지 확인하세요. LaunchAgent로 에이전트 하위 프로세스를 실행하는 경우에도 같은 서명의 바이너리에 권한을 부여해야 합니다."
                self.agentUserAlert = m
            } else if (!loadRes.ok && !isBenignLaunchctlLoadMessage(loadRes.mergedOutput)) || !startRes.ok {
                self.agentUserAlert = "에이전트가 실행 중입니다. 참고: launchctl 출력 — load: \(loadRes.mergedOutput) start: \(startRes.mergedOutput)"
            }
        }
    }

    /// 에이전트를 정지하고 launchd에서 **unload**한다. 그러지 않으면 `KeepAlive` 때문에 프로세스가 곧바로 재시작되어 블루투스를 계속 점유한다.
    func stop() {
        unloadAgentLaunchJobRemovingSocket()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Log

    var logFilePath: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AhaKeyConfig/diagnostics")
        try? FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent.log").path
    }

    /// 훅 하위 프로세스가 Claude `PermissionRequest`마다 JSON 줄을 덧붙인다. `HookClient`의 diagnostics 경로와 동일하다.
    var permissionRequestLogPath: String {
        URL(fileURLWithPath: logFilePath).deletingLastPathComponent()
            .appendingPathComponent("permission-request.log")
            .path
    }

    /// Codex의 모든 AhaKey 훅 트리거 기록: 상태 훅과 PermissionRequest 모두 JSON 줄을 덧붙인다.
    var codexHookLogPath: String {
        URL(fileURLWithPath: logFilePath).deletingLastPathComponent()
            .appendingPathComponent("codex-hook.log")
            .path
    }

    func readLog() -> String {
        (try? String(contentsOfFile: logFilePath, encoding: .utf8)) ?? "(로그 없음)"
    }

    // MARK: - Cursor 사용자 수준 파일 (표시·병합 가능. 훅 하위 프로세스가 관리하지 않는다)

    /// 'Cursor Hooks 설치'가 쓰는 경로와 동일하며, UI에서 표시하거나 대조하기 쉽다.
    var userCursorHooksJsonFilePath: String { cursorHooksPath }

    /// Codex 0.125는 `~/.codex/config.toml`의 인라인 `[[hooks.Event]]`를 사용한다.
    var userCodexConfigFilePath: String { codexConfigPath }

    /// Kimi Code CLI(베타)는 `~/.kimi/config.toml`의 `[[hooks]]`를 사용한다.
    var userKimiConfigFilePath: String { kimiConfigPath }

    /// Cursor CLI / 에이전트의 전역 `permissions` 등 (Shell 등이 여전히 확인 창을 띄우는지를 제어하며, `hooks.json`과는 별개).
    var userCursorCliConfigFilePath: String { cursorCliConfigPath }

    /// `~/.cursor/hooks.json`을 읽기 쉬운(pretty) 형태로 읽어 온다. 파일이 없으면 설명을 반환한다.
    func readUserCursorHooksJsonForDisplay() -> String {
        let path = cursorHooksPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "(파일이 없습니다: \(path))\n\n'Cursor Hooks 설치'를 눌러 생성하거나 병합할 수 있습니다. **프로젝트 내** `.cursor/hooks.json`만 사용한다면 이 경로는 비어 있을 수 있습니다."
        }
        return Self.prettyJsonString(atPath: path) ?? "(파일은 있지만 JSON으로 파싱할 수 없습니다: \(path))"
    }

    /// `~/.cursor/cli-config.json`을 읽기 쉬운(pretty) 형태로 읽어 온다. 파일이 없으면 안내한다.
    func readUserCursorCliConfigForDisplay() -> String {
        let path = cursorCliConfigPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "(파일이 없습니다: \(path))\n\n진단 패널에서 'Shell 허용 목록 병합 + approvalMode=auto'를 눌러 새로 만들 수 있습니다. 또는 문서를 참고해 `permissions`를 직접 설정하세요."
        }
        return Self.prettyJsonString(atPath: path) ?? "(파일은 있지만 JSON으로 파싱할 수 없습니다: \(path))"
    }

    /// `~/.codex/config.toml`을 그대로 읽어 온다. Codex 훅은 JSON이 아니라 TOML이다.
    func readUserCodexConfigForDisplay() -> String {
        let path = codexConfigPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "(파일이 없습니다: \(path))\n\n'Codex Hooks 설치'를 눌러 `[features].hooks`와 AhaKey hook block을 생성하고 병합할 수 있습니다."
        }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? "(파일은 있지만 읽을 수 없습니다: \(path))"
    }

    /// `~/.kimi/config.toml`을 그대로 읽어 온다 (Kimi Hooks 설정은 텍스트 TOML이다).
    func readUserKimiConfigForDisplay() -> String {
        let path = kimiConfigPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "(파일이 없습니다: \(path))\n\n'Kimi Hooks 설치'를 눌러 AhaKey 표시 블록을 생성하고 기록할 수 있습니다. Kimi Code CLI가 설치되어 사용 중이어야 합니다: https://moonshotai.github.io/kimi-cli/"
        }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? "(파일은 있지만 읽을 수 없습니다: \(path))"
    }

    /// 현재 `cli-config`를 백업한 뒤 `permissions.allow`를 병합하고(기존 항목은 삭제하지 않는다) `approvalMode`를 `auto`로 설정한다.
    /// '훅이 이미 allow했는데도 Cursor가 한 번 더 누르라고 요구하는' 상황에서 **Cursor 자체 계층**의 차단을 완화하는 데 쓴다.
    /// - Returns: 사용자에게 보여 줄 결과 설명.
    func mergeUserCursorCliConfigForShellAutoApprove() -> String {
        let path = cursorCliConfigPath
        let cursorDir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: cursorDir, withIntermediateDirectories: true)
        } catch {
            return "디렉터리를 만들 수 없습니다 \(cursorDir): \(error.localizedDescription)"
        }
        if FileManager.default.fileExists(atPath: path) {
            let bak = path + ".ahakey.bak"
            do {
                if FileManager.default.fileExists(atPath: bak) {
                    try FileManager.default.removeItem(atPath: bak)
                }
                try FileManager.default.copyItem(atPath: path, toPath: bak)
            } catch {
                return "\(path)이(가) 이미 있지만 \(bak)으로 백업을 복사할 수 없습니다: \(error.localizedDescription)"
            }
        }
        var root = loadCursorCliConfig() ?? [:]
        if root["version"] == nil { root["version"] = 1 }

        var perms = root["permissions"] as? [String: Any] ?? [:]
        var allow = Self.stringArrayValue(perms["allow"])
        let additions: [String] = [
            "Shell(*)", "Shell(cd)", "Shell(swift)", "Shell(xcodebuild)", "Shell(git)", "Shell(python3)", "Shell(npm)", "Shell(cargo)", "Shell(curl)", "Shell(ls)",
        ]
        var merged = 0
        for a in additions {
            if !allow.contains(a) {
                allow.append(a)
                merged += 1
            }
        }
        perms["allow"] = allow
        if perms["deny"] == nil { perms["deny"] = [String]() }
        root["permissions"] = perms
        root["approvalMode"] = "auto"

        guard saveCursorCliConfig(root) else {
            return "병합한 JSON을 다시 쓸 수 없습니다: \(path)"
        }
        log.info("cli-config: merged Shell allow + approvalMode=auto at \(path)")
        return "다시 썼습니다: \(path)\n(같은 경로에 파일이 있었다면 \(path).ahakey.bak으로 백업했습니다)\n\n이번에 permissions.allow에 흔히 쓰이는 Shell(...) 규칙 \(merged)개를 새로 병합했습니다(기존 규칙은 유지). approvalMode는 auto로 설정했습니다.\n\n특정 버전에서 여전히 창이 뜬다면, 차단된 명령의 첫 단어를 문서와 대조해 허용 목록에 직접 추가하세요:\nhttps://cursor.com/docs/cli/reference/permissions\n또는 작업 공간의 .cursor/cli.json에 별도 제한이 있는지 확인하세요."
    }

    /// `~/.cursor/permissions.json`의 `terminalAllowlist`를 병합한다 (**IDE의 'Not in allowlist'**는 cli-config와 무관하다).
    func mergeUserCursorPermissionsJsonForAgentTUI() -> String {
        let path = cursorPermissionsJsonPath
        let cursorDir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: cursorDir, withIntermediateDirectories: true)
        } catch {
            return "디렉터리를 만들 수 없습니다 \(cursorDir): \(error.localizedDescription)"
        }
        if FileManager.default.fileExists(atPath: path) {
            let bak = path + ".ahakey.bak"
            do {
                if FileManager.default.fileExists(atPath: bak) { try FileManager.default.removeItem(atPath: bak) }
                try FileManager.default.copyItem(atPath: path, toPath: bak)
            } catch {
                return "permissions.json이 이미 있지만 \(bak)으로 백업할 수 없습니다: \(error.localizedDescription)"
            }
        }
        var root = loadCursorPermissionsJson() ?? [:]
        var list = Self.stringArrayValue(root["terminalAllowlist"])
        let additions = [
            "cd", "swift", "swift build", "xcodebuild", "git", "npm", "yarn", "pnpm", "bun", "deno", "node",
            "make", "cargo", "go", "python3", "python", "bash", "zsh", "sh", "curl", "ls",
        ]
        var n = 0
        for a in additions where !list.contains(a) {
            list.append(a)
            n += 1
        }
        root["terminalAllowlist"] = list
        guard saveCursorPermissionsJson(root) else {
            return "다시 쓸 수 없습니다: \(path)"
        }
        log.info("permissions.json: merged terminalAllowlist at \(path)")
        return "다시 썼습니다: \(path) (\(path).ahakey.bak으로 백업)\n\n이번에 terminalAllowlist에 접두어 \(n)개를 새로 병합했습니다. 에이전트 내부의 'Not in allowlist' 계층에 쓰이며, cli-config의 Shell(...)과는 별개입니다. 문서:\nhttps://cursor.com/docs/reference/permissions"
    }

    private func loadCursorPermissionsJson() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: cursorPermissionsJsonPath),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return j
    }

    private func saveCursorPermissionsJson(_ root: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: cursorPermissionsJsonPath), options: .atomic)
            return true
        } catch {
            log.error("saveCursorPermissionsJson: \(error.localizedDescription)")
            return false
        }
    }

    private static func prettyJsonString(atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    private static func stringArrayValue(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let a = v as? [Any] { return a.compactMap { $0 as? String } }
        return []
    }

    private func loadCursorCliConfig() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: cursorCliConfigPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func saveCursorCliConfig(_ root: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: cursorCliConfigPath), options: .atomic)
            return true
        } catch {
            log.error("saveCursorCliConfig: \(error.localizedDescription)")
            return false
        }
    }

    /// 읽기 전용. `ahakeyconfig-agent`가 `PermissionRequest`와 Cursor 승인 계열 훅에서 기록한다.
    func readPermissionRequestLog() -> String {
        (try? String(contentsOfFile: permissionRequestLogPath, encoding: .utf8))
            ?? "아직 기록이 없습니다. Claude에서 PermissionRequest를 트리거하거나, Cursor에서 에이전트가 도구/Shell/MCP를 호출하게 하거나, Kimi Code CLI에서 도구 호출을 트리거하면 `ide` / `hookEvent`가 포함된 JSON 줄이 여기에 덧붙습니다. 계속 비어 있다면 에이전트와 훅이 설치되었는지, 블루투스를 에이전트가 점유하고 있는지, `~/Library/.../AhaKeyConfig/diagnostics/`에 쓸 수 있는지 확인하세요."
    }

    /// 읽기 전용. `ahakeyconfig-agent hook Codex*` 하위 프로세스가 기록하며, Codex 클라이언트/터미널이 실제로 훅을 트리거했는지 판단하는 데 쓴다.
    func readCodexHookLog() -> String {
        (try? String(contentsOfFile: codexHookLogPath, encoding: .utf8))
            ?? "아직 기록이 없습니다. Codex를 트리거하면 여기에 JSON 줄이 덧붙어야 합니다. 터미널 Codex에는 기록이 있는데 Codex 클라이언트에는 없다면, 클라이언트가 현재 `~/.codex/config.toml`의 훅을 로드하지 않은 것입니다. 보통 Codex 클라이언트를 재시작하거나 터미널을 새로 열고 다시 시도해야 합니다."
    }

    // MARK: - Claude 훅 추가

    /// Claude Code가 지원하는 훅 이벤트 (HookClient.eventMap과 맞춤)
    private let hookEvents: [String] = [
        "Notification",
        "PermissionRequest",
        "PreToolUse",
        "PostToolUse",
        "Stop",
        "SubagentStop",  // Claude Code 분리 이후: 작업을 수동으로 종료할 때 이 이벤트가 발생한다
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "TaskCompleted",
        "PreCompact",
    ]

    /// 경로를 셸에서 안전하게 인용한다 (작은따옴표로 감싸고 내부의 작은따옴표를 이스케이프)
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 빈 문자열은 기록 완료를 뜻한다. 비어 있지 않으면 '건너뜀 / 실패' 설명이므로 사용자에게 보여 줘야 한다.
    private func installClaudeHooks() -> String {
        guard var settings = loadClaudeSettings() else {
            return "Claude Hooks: ~/.claude/settings.json을 찾지 못해 건너뛰었습니다. Claude Code를 사용해 이 파일이 만들어진 뒤 'Claude Hooks 설치'를 다시 누르세요."
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let binQuoted = shellQuote(agentBinaryPath)

        for event in hookEvents {
            let ahakeyCmd = "\(binQuoted) hook \(event)"
            var eventHooks = hooks[event] as? [[String: Any]] ?? []

            // 먼저 기존 ahakey 항목을 지워, 셸 스크립트와 새 바이너리가 함께 남지 않게 한다
            for i in eventHooks.indices {
                var entry = eventHooks[i]
                if var cmds = entry["hooks"] as? [[String: Any]] {
                    cmds.removeAll { isAhakeyHookCommand(($0["command"] as? String) ?? "") }
                    entry["hooks"] = cmds
                    eventHooks[i] = entry
                }
            }

            if let idx = eventHooks.firstIndex(where: { ($0["matcher"] as? String) == "" }) {
                var entry = eventHooks[idx]
                var cmds = entry["hooks"] as? [[String: Any]] ?? []
                cmds.append(["type": "command", "command": ahakeyCmd])
                entry["hooks"] = cmds
                eventHooks[idx] = entry
            } else {
                eventHooks.append([
                    "matcher": "",
                    "hooks": [["type": "command", "command": ahakeyCmd]],
                ])
            }
            hooks[event] = eventHooks
        }

        settings["hooks"] = hooks
        if saveClaudeSettings(settings) {
            log.info("Claude 훅에 ahakeyconfig-agent hook 하위 명령을 기록했습니다")
            return ""
        }
        return "Claude Hooks: \(claudeSettingsPath)에 쓸 수 없습니다. 해당 파일이나 상위 디렉터리의 권한 및 읽기 전용 여부를 확인하세요."
    }

    private func removeClaudeHooks() {
        guard var settings = loadClaudeSettings() else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for event in hookEvents {
            guard var eventHooks = hooks[event] as? [[String: Any]] else { continue }
            for i in eventHooks.indices {
                var entry = eventHooks[i]
                if var cmds = entry["hooks"] as? [[String: Any]] {
                    cmds.removeAll { isAhakeyHookCommand(($0["command"] as? String) ?? "") }
                    entry["hooks"] = cmds
                    eventHooks[i] = entry
                }
            }
            hooks[event] = eventHooks
        }

        settings["hooks"] = hooks
        if !saveClaudeSettings(settings) {
            log.error("removeClaudeHooks: settings를 다시 쓸 수 없습니다")
        } else {
            log.info("Claude 훅에서 ahakey 항목을 제거했습니다")
        }
    }

    private func loadClaudeSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: claudeSettingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func saveClaudeSettings(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: claudeSettingsPath), options: .atomic)
            return true
        } catch {
            log.error("saveClaudeSettings: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Cursor hooks

    /// Cursor가 지원하는 훅 이벤트 (소문자 카멜케이스, `HookClient`와 동일).
    /// 승인 체인은 `preToolUse`에 모여 있다 (모든 도구 호출 전에 실행되며 stdout으로 `permission`을 낼 수 있다). `hooks.json`에 직접
    /// `beforeShellExecution` / `beforeMCPExecution`을 추가해 이 에이전트를 가리키게 하면, 해당 이벤트 이름도 `HookClient`에서 레버를 지원한다.
    /// 설치할 때는 이 이벤트들을 기록한다. **제거**할 때는 `hooks`의 **모든 키**를 순회한다 (구버전이나 병합된 `beforeReadFile`, `beforeSubmitPrompt` 등 포함). 절반만 제거되어 '반응이 없는' 상태가 되는 것을 막기 위함이다.
    private let cursorHookEvents: [String] = [
        "sessionStart",
        "sessionEnd",
        "preToolUse",
        "beforeShellExecution",
        "beforeMCPExecution",
        "beforeReadFile",
        "beforeSubmitPrompt",
        "postToolUse",
        "stop",
    ]

    private let codexHookBlockStart = "# BEGIN AhaKey Codex Hooks"
    private let codexHookBlockEnd = "# END AhaKey Codex Hooks"
    private let codexHookEvents: [(event: String, agentEvent: String, timeout: Int)] = [
        ("SessionStart", "CodexSessionStart", 10),
        ("PostToolUse", "CodexPostToolUse", 10),
        ("PreToolUse", "CodexPreToolUse", 20),
        ("PermissionRequest", "CodexPermissionRequest", 20),
        ("UserPromptSubmit", "CodexUserPromptSubmit", 10),
        ("Stop", "CodexStop", 10),
    ]

    private let kimiHookBlockStart = "# BEGIN AhaKey Kimi Hooks"
    private let kimiHookBlockEnd = "# END AhaKey Kimi Hooks"
    private let kimiHookEntries: [(event: String, agentEvent: String, timeout: Int)] = [
        ("Notification", "KimiNotification", 10),
        ("SessionStart", "KimiSessionStart", 10),
        ("SessionEnd", "KimiSessionEnd", 10),
        ("PreToolUse", "KimiPreToolUse", 20),
        ("PostToolUse", "KimiPostToolUse", 10),
        ("UserPromptSubmit", "KimiUserPromptSubmit", 10),
        ("Stop", "KimiStop", 10),
    ]

    /// Claude 훅만 따로 설치
    func installClaudeHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        let s = installClaudeHooks()
        agentUserAlert = s.isEmpty ? "Claude Hooks를 ~/.claude/settings.json에 기록했습니다." : s
        refresh()
    }

    /// Claude 훅만 따로 제거
    func removeClaudeHooksOnly() {
        removeClaudeHooks()
        refresh()
    }

    /// Cursor 훅만 따로 설치 (UI용으로 공개. 예를 들어 Cursor만 추가로 설치할 때 호출)
    func installCursorHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        let s = installCursorHooks()
        agentUserAlert = s.isEmpty ? "Cursor Hooks를 ~/.cursor/hooks.json에 기록했습니다." : s
        refresh()
    }

    /// Codex 훅만 따로 설치 (Codex 0.125는 인라인 TOML).
    func installCodexHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        let s = installCodexHooks()
        agentUserAlert = s.isEmpty ? "Codex Hooks를 ~/.codex/config.toml에 기록했습니다.\n\n설치가 완료되었습니다. Codex 터미널이나 클라이언트를 재시작한 뒤 사용하세요." : s
        refresh()
    }

    /// Cursor 훅만 따로 제거
    func removeCursorHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        agentUserAlert = performRemoveCursorHooksUserMessage()
        refresh()
    }

    /// Codex 훅만 따로 제거.
    func removeCodexHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        agentUserAlert = removeCodexHooks()
        refresh()
    }

    /// Kimi Code CLI 훅만 따로 설치 (`~/.kimi/config.toml`, 베타).
    func installKimiHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        let s = installKimiHooks()
        agentUserAlert = s.isEmpty
            ? """
            Kimi Hooks를 ~/.kimi/config.toml에 기록했습니다.

            **AhaKey 레버 제어도 로컬 kimi-cli에 함께 패치됩니다**. kimi가 지금 열려 있다면 **완전히 종료한 뒤 다시 열어 주세요**. 다시 열면 **레버 0/1이 현재 세션의 자동 승인을 바로 제어하며**, **`/reload`도 `/yolo`도 필요하지 않습니다**.
            앞으로 **kimi-cli를 업그레이드했다면** 'Kimi Hooks 설치'를 한 번 더 눌러 이 레버 제어 계층을 다시 적용하고, kimi를 한 번 더 열어 주세요.

            설치가 완료되었습니다. Hooks는 베타이므로 동작은 공식 문서를 기준으로 하세요.
            """
            : s
        refresh()
    }

    /// Kimi Hooks 표시 블록만 따로 제거.
    func removeKimiHooksOnly() {
        isAgentOperationInProgress = true
        defer { isAgentOperationInProgress = false }
        agentUserAlert = removeKimiHooks()
        refresh()
    }

    private func installCursorHooks() -> String {
        // Cursor 디렉터리가 없을 수 있으므로 먼저 만든다
        let cursorDir = (cursorHooksPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: cursorDir, withIntermediateDirectories: true)
        } catch {
            return "Cursor Hooks: 디렉터리를 만들 수 없습니다 \(cursorDir): \(error.localizedDescription)"
        }

        var settings = loadCursorSettings() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let binQuoted = shellQuote(agentBinaryPath)

        for event in cursorHookEvents {
            let cmd = "\(binQuoted) hook \(event)"
            // Cursor: `{ "hooks": { "<event>": [{ "command": "...", "timeout": N }] } }`
            // 레버 읽기/상태 쓰기가 다소 느리므로, 긴 타임아웃은 `HookClient`와 동일하게 맞춘다
            let t: Int
            if event == "beforeSubmitPrompt" { t = 30 }
            else if ["preToolUse", "beforeShellExecution", "beforeMCPExecution", "beforeReadFile", "sessionStart"].contains(event) { t = 20 }
            else { t = 10 }
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { isAhakeyHookCommand(($0["command"] as? String) ?? "") }
            entries.append(["command": cmd, "timeout": t])
            hooks[event] = entries
        }

        settings["hooks"] = hooks
        if settings["version"] == nil {
            settings["version"] = 1
        }
        if saveCursorSettings(settings) {
            log.info("Cursor 훅을 기록했습니다")
            return ""
        }
        return "Cursor Hooks: \(cursorHooksPath)에 쓸 수 없습니다. 권한이나 디스크 공간을 확인하세요."
    }

    private func installCodexHooks() -> String {
        let codexDir = (codexConfigPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
        } catch {
            return "Codex Hooks: 디렉터리를 만들 수 없습니다 \(codexDir): \(error.localizedDescription)"
        }

        var config = (try? String(contentsOfFile: codexConfigPath, encoding: .utf8)) ?? ""
        config = removeCodexHookBlock(from: config)
        config = ensureCodexHooksFeatureEnabled(in: config)
        config = config.trimmingCharacters(in: .whitespacesAndNewlines)
        if !config.isEmpty { config += "\n\n" }
        config += buildCodexHookBlock()
        config += "\n"

        do {
            try config.write(toFile: codexConfigPath, atomically: true, encoding: .utf8)
            guard FileManager.default.fileExists(atPath: codexConfigPath),
                  let written = try? String(contentsOfFile: codexConfigPath, encoding: .utf8),
                  written.contains(codexHookBlockStart),
                  written.contains(codexHookBlockEnd) else {
                log.error("installCodexHooks: 기록 후 검증 실패 \(self.codexConfigPath)")
                return "Codex Hooks: \(codexConfigPath)에 쓰기를 시도했지만 검증 과정에서 AhaKey 표시 블록을 찾지 못했습니다. '사용자 홈 디렉터리 /.codex'에 쓰기 권한이 있는지 확인하거나, 이 파일을 점유하고 있는 다른 프로그램을 종료하세요."
            }
            log.info("Codex 훅을 ~/.codex/config.toml에 기록했습니다")
            let cliRepair = repairCodexCliPathIfNeeded()
            return cliRepair.isEmpty
                ? ""
                : "Codex Hooks를 ~/.codex/config.toml에 기록했습니다.\n\n\(cliRepair)\n\n설치가 완료되었습니다. Codex 터미널이나 클라이언트를 재시작한 뒤 사용하세요."
        } catch {
            log.error("installCodexHooks: \(error.localizedDescription)")
            return "Codex Hooks: \(codexConfigPath)에 쓸 수 없습니다: \(error.localizedDescription)"
        }
    }

    private func repairCodexCliPathIfNeeded() -> String {
        if isExecutableOnPath("codex") {
            return ""
        }
        guard FileManager.default.isExecutableFile(atPath: codexAppCliPath) else {
            return "PATH에서 `codex` 명령을 찾지 못했고, Codex 앱에 포함된 CLI도 찾지 못했습니다: \(codexAppCliPath). 훅 설정은 설치되었습니다. 터미널에서 Codex를 사용하려면 Codex 클라이언트를 먼저 설치하거나 업데이트하세요."
        }

        do {
            try FileManager.default.createDirectory(atPath: localBinDirectoryPath, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: localCodexCliPath) {
                try FileManager.default.removeItem(atPath: localCodexCliPath)
            }
            try FileManager.default.createSymbolicLink(atPath: localCodexCliPath, withDestinationPath: codexAppCliPath)
        } catch {
            return "터미널에서 `codex`를 사용할 수 없는 것으로 확인되었지만 \(localCodexCliPath)을(를) 만들 수 없습니다: \(error.localizedDescription). 훅 설정은 설치되었습니다."
        }

        let zshLine = #"export PATH="$HOME/.local/bin:$PATH""#
        do {
            var zshrc = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
            if !zshrc.contains("HOME/.local/bin") && !zshrc.contains("$HOME/.local/bin") {
                if FileManager.default.fileExists(atPath: zshrcPath) {
                    let bak = zshrcPath + ".ahakey.bak"
                    if FileManager.default.fileExists(atPath: bak) {
                        try FileManager.default.removeItem(atPath: bak)
                    }
                    try FileManager.default.copyItem(atPath: zshrcPath, toPath: bak)
                }
                zshrc = zshrc.trimmingCharacters(in: .whitespacesAndNewlines)
                if !zshrc.isEmpty { zshrc += "\n" }
                zshrc += zshLine + "\n"
                try zshrc.write(toFile: zshrcPath, atomically: true, encoding: .utf8)
                return "Codex 앱에 포함된 CLI를 확인해 터미널 명령을 복구했습니다:\n\(localCodexCliPath) → \(codexAppCliPath)\n\n`~/.local/bin`을 ~/.zshrc에 추가했습니다 (기존 파일이 있었다면 ~/.zshrc.ahakey.bak으로 백업했습니다)."
            }
        } catch {
            return "\(localCodexCliPath)을(를) 만들었지만 ~/.zshrc를 업데이트할 수 없습니다: \(error.localizedDescription). `~/.local/bin`을 PATH에 직접 추가하세요."
        }

        return "Codex 앱에 포함된 CLI를 확인해 터미널 명령을 만들었습니다:\n\(localCodexCliPath) → \(codexAppCliPath)"
    }

    private func isExecutableOnPath(_ command: String) -> Bool {
        executablePathOnPath(command) != nil
    }

    private func executablePathOnPath(_ command: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    @discardableResult
    private func removeCodexHooks() -> String {
        let path = codexConfigPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "\(path)을(를) 찾지 못했습니다. Codex Hooks를 제거할 필요가 없습니다."
        }
        guard let config = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "\(path)을(를) 읽을 수 없습니다. 권한을 확인하세요."
        }
        let next = removeCodexHookBlock(from: config)
        guard next != config else {
            return "\(path)에서 AhaKey Codex hook 표시 블록을 찾지 못했습니다."
        }
        do {
            try next.write(toFile: path, atomically: true, encoding: .utf8)
            log.info("Codex 훅에서 AhaKey 표시 블록을 제거했습니다")
            return "\(path)에서 AhaKey Codex Hooks를 제거했습니다."
        } catch {
            return "제거된 내용을 만들었지만 \(path)에 다시 쓸 수 없습니다: \(error.localizedDescription)"
        }
    }

    private func buildCodexHookBlock() -> String {
        let binQuoted = shellQuote(agentBinaryPath)
        var lines: [String] = [
            codexHookBlockStart,
            "# Managed by AhaKey Studio. Codex 0.125 uses inline TOML hooks; each command hook needs type = \"command\".",
        ]
        for item in codexHookEvents {
            lines.append("")
            lines.append("[[hooks.\(item.event)]]")
            lines.append("matcher = \"\"")
            lines.append("")
            lines.append("[[hooks.\(item.event).hooks]]")
            lines.append("type = \"command\"")
            lines.append("command = \"\(escapeTomlBasicString("/bin/zsh -lc \(shellQuote("\(binQuoted) hook \(item.agentEvent)"))"))\"")
            lines.append("timeout = \(item.timeout)")
        }
        lines.append("")
        lines.append(codexHookBlockEnd)
        return lines.joined(separator: "\n")
    }

    private func removeCodexHookBlock(from config: String) -> String {
        var lines = config.components(separatedBy: .newlines)
        while let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == codexHookBlockStart }),
              let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == codexHookBlockEnd }) {
            lines.removeSubrange(start...end)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func ensureCodexHooksFeatureEnabled(in config: String) -> String {
        var lines = config.components(separatedBy: .newlines)
        var featuresStart: Int?
        for (idx, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "[features]" {
                featuresStart = idx
                break
            }
        }

        guard let start = featuresStart else {
            var next = config.trimmingCharacters(in: .whitespacesAndNewlines)
            if !next.isEmpty { next += "\n\n" }
            next += "[features]\nhooks = true\n"
            return next
        }

        var sectionEnd = lines.count
        if start + 1 < lines.count {
            for idx in (start + 1)..<lines.count {
                let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    sectionEnd = idx
                    break
                }
            }
        }

        // Codex 신버전은 `hooks`를 쓴다. 구버전에서는 폐기된 `codex_hooks`를 기록한 적이 있다 (deprecation 경고가 발생한다).
        // 둘 다 인식한다: 첫 번째로 매칭된 것을 `hooks = true`로 유지·수정하고, 나머지(모든 `codex_hooks` 포함)는 삭제한다.
        let keyPattern = #"^\s*(codex_)?hooks\s*="#
        let regex = try? NSRegularExpression(pattern: keyPattern)
        var matchedIndices: [Int] = []
        for idx in (start + 1)..<sectionEnd {
            let line = lines[idx]
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex?.firstMatch(in: line, range: range) != nil {
                matchedIndices.append(idx)
            }
        }

        guard let first = matchedIndices.first else {
            lines.insert("hooks = true", at: start + 1)
            return lines.joined(separator: "\n")
        }

        lines[first] = "hooks = true"
        for idx in matchedIndices.dropFirst().reversed() {
            lines.remove(at: idx)
        }
        return lines.joined(separator: "\n")
    }

    private func escapeTomlBasicString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func installKimiHooks() -> String {
        let kimiDir = (kimiConfigPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: kimiDir, withIntermediateDirectories: true)
        } catch {
            return "Kimi Hooks: 디렉터리를 만들 수 없습니다 \(kimiDir): \(error.localizedDescription)"
        }

        var config = (try? String(contentsOfFile: kimiConfigPath, encoding: .utf8)) ?? ""
        config = removeKimiHookBlock(from: config)
        config = removeLegacyKimiHookEntries(from: config)
        config = config.trimmingCharacters(in: .whitespacesAndNewlines)
        if !config.isEmpty { config += "\n\n" }
        config += buildKimiHookBlock()
        config += "\n"

        do {
            try config.write(toFile: kimiConfigPath, atomically: true, encoding: .utf8)
            log.info("Kimi 훅을 ~/.kimi/config.toml에 기록했습니다")
            return patchInstalledKimiCliForAhaKeyDialControl()
        } catch {
            log.error("installKimiHooks: \(error.localizedDescription)")
            return "Kimi Hooks: \(kimiConfigPath)에 쓸 수 없습니다: \(error.localizedDescription)"
        }
    }

    private struct KimiCliPatchTargets {
        let approvalPyPath: String
        let slashPyPath: String
        let sourceHint: String
    }

    private enum KimiCliPatchStatus {
        case alreadyPatched
        case patched
    }

    private func patchInstalledKimiCliForAhaKeyDialControl() -> String {
        guard let targets = resolveKimiCliPatchTargets() else {
            return """
            Kimi Hooks를 ~/.kimi/config.toml에 기록했지만, **패치를 적용할 로컬 kimi-cli 설치를 찾지 못했습니다**.

            터미널에 `kimi` 명령이 있는지 확인하세요. 확인한 뒤 'Kimi Hooks 설치'를 다시 누르면 레버 제어 패치를 재시도합니다.
            """
        }

        do {
            _ = try patchKimiApprovalPy(atPath: targets.approvalPyPath)
            _ = try patchKimiSlashPy(atPath: targets.slashPyPath)
            log.info("Kimi CLI dial-control patch ensured at \(targets.sourceHint)")
            return ""
        } catch {
            log.error("patchInstalledKimiCliForAhaKeyDialControl: \(error.localizedDescription)")
            return """
            Kimi Hooks를 ~/.kimi/config.toml에 기록했지만, **로컬 kimi-cli의 레버 제어 패치가 완료되지 않았습니다**:
            \(error.localizedDescription)

            `kimi`가 실행 가능한지 확인한 뒤 'Kimi Hooks 설치'를 다시 눌러 재시도할 수 있습니다.
            """
        }
    }

    private func resolveKimiCliPatchTargets() -> KimiCliPatchTargets? {
        if let kimiPath = executablePathOnPath("kimi"),
           let targets = resolveKimiCliPatchTargets(fromKimiEntryPath: kimiPath) {
            return targets
        }

        let fallbackRoot = URL(fileURLWithPath: kimiCliFallbackRoot, isDirectory: true)
        if let targets = resolveKimiCliPatchTargets(fromEnvRoot: fallbackRoot, sourceHint: fallbackRoot.path) {
            return targets
        }
        return nil
    }

    private func resolveKimiCliPatchTargets(fromKimiEntryPath path: String) -> KimiCliPatchTargets? {
        guard let wrapper = try? String(contentsOfFile: path, encoding: .utf8),
              let firstLine = wrapper.components(separatedBy: .newlines).first,
              firstLine.hasPrefix("#!") else {
            return nil
        }
        let shebang = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shebang.isEmpty else { return nil }
        let pythonPath = shebang.components(separatedBy: .whitespaces).first ?? shebang
        let envRoot = URL(fileURLWithPath: pythonPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return resolveKimiCliPatchTargets(fromEnvRoot: envRoot, sourceHint: path)
    }

    private func resolveKimiCliPatchTargets(fromEnvRoot envRoot: URL, sourceHint: String) -> KimiCliPatchTargets? {
        let libRoot = envRoot.appendingPathComponent("lib", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(at: libRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard child.lastPathComponent.hasPrefix("python") else { continue }
            let pkgRoot = child.appendingPathComponent("site-packages/kimi_cli", isDirectory: true)
            let approval = pkgRoot.appendingPathComponent("soul/approval.py").path
            let slash = pkgRoot.appendingPathComponent("soul/slash.py").path
            if FileManager.default.fileExists(atPath: approval),
               FileManager.default.fileExists(atPath: slash) {
                return KimiCliPatchTargets(
                    approvalPyPath: approval,
                    slashPyPath: slash,
                    sourceHint: sourceHint
                )
            }
        }
        return nil
    }

    private func patchKimiApprovalPy(atPath path: String) throws -> KimiCliPatchStatus {
        let marker = "_AHAKEY_SOCKET_PATH = \"/tmp/ahakey.sock\""
        let helperAnchor = "type Response = Literal[\"approve\", \"approve_for_session\", \"reject\"]\n"
        let helperBlock = """
        type Response = Literal["approve", "approve_for_session", "reject"]

        _AHAKEY_SOCKET_PATH = "/tmp/ahakey.sock"
        _AHAKEY_APPROVAL_CACHE_TTL_S = 0.35
        _ahakey_cache_at = 0.0
        _ahakey_cache_value: dict[str, object] | None = None


        def _load_ahakey_override_uncached() -> dict[str, object] | None:
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                    sock.settimeout(2.0)
                    sock.connect(_AHAKEY_SOCKET_PATH)
                    sock.sendall(b'{"cmd":"approval_status"}\\n')

                    chunks: list[bytes] = []
                    while True:
                        part = sock.recv(4096)
                        if not part:
                            break
                        chunks.append(part)
                        if b"\\n" in part:
                            break
            except OSError:
                return None

            raw = b"".join(chunks).decode("utf-8", errors="ignore").strip()
            if not raw:
                return None
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                return None
            switch_state = payload.get("switchState")
            if not isinstance(switch_state, int):
                return None
            return {
                "switch_state": switch_state,
                "is_auto": switch_state == 0,
                "mode_label": "auto" if switch_state == 0 else "manual",
            }


        def get_ahakey_approval_override(*, force_refresh: bool = False) -> dict[str, object] | None:
            global _ahakey_cache_at, _ahakey_cache_value

            now = time.monotonic()
            if not force_refresh and (now - _ahakey_cache_at) < _AHAKEY_APPROVAL_CACHE_TTL_S:
                return _ahakey_cache_value

            value = _load_ahakey_override_uncached()
            _ahakey_cache_at = now
            _ahakey_cache_value = value
            return value
        """
        let oldImports = "import uuid\n"
        let newImports = """
        import json
        import socket
        import time
        import uuid
        """
        let oldApprovalLogic = """
                if self.is_auto_approve():
                    from kimi_cli.telemetry import track

                    track(
                        "tool_approved",
                        tool_name=tool_call.function.name,
                        approval_mode="afk" if self.is_afk() else "yolo",
                    )
                    return ApprovalResult(approved=True)

                if action in self._state.auto_approve_actions:
                    from kimi_cli.telemetry import track

                    track(
                        "tool_approved",
                        tool_name=tool_call.function.name,
                        approval_mode="auto_session",
                    )
                    return ApprovalResult(approved=True)
        """
        let newApprovalLogic = """
                ahakey_override = get_ahakey_approval_override(force_refresh=True)
                if ahakey_override is not None and bool(ahakey_override["is_auto"]):
                    from kimi_cli.telemetry import track

                    track(
                        "tool_approved",
                        tool_name=tool_call.function.name,
                        approval_mode="ahakey_dial_auto",
                    )
                    return ApprovalResult(approved=True)

                ahakey_manual_lock = ahakey_override is not None and not bool(ahakey_override["is_auto"])

                if not ahakey_manual_lock and self.is_auto_approve():
                    from kimi_cli.telemetry import track

                    track(
                        "tool_approved",
                        tool_name=tool_call.function.name,
                        approval_mode="afk" if self.is_afk() else "yolo",
                    )
                    return ApprovalResult(approved=True)

                if not ahakey_manual_lock and action in self._state.auto_approve_actions:
                    from kimi_cli.telemetry import track

                    track(
                        "tool_approved",
                        tool_name=tool_call.function.name,
                        approval_mode="auto_session",
                    )
                    return ApprovalResult(approved=True)
        """
        return try patchTextFile(
            atPath: path,
            marker: marker,
            replacements: [
                (oldImports, newImports + "\n"),
                (helperAnchor, helperBlock + "\n"),
                (oldApprovalLogic, newApprovalLogic),
            ],
            friendlyName: "kimi_cli/soul/approval.py"
        )
    }

    private func patchKimiSlashPy(atPath path: String) throws -> KimiCliPatchStatus {
        let marker = "from kimi_cli.soul.approval import get_ahakey_approval_override"
        let oldImport = "from kimi_cli import logger\n"
        let newImport = """
        from kimi_cli import logger
        from kimi_cli.soul.approval import get_ahakey_approval_override
        """
        let oldYoloLead = """
            # Inspect only the yolo flag: afk is independent and is toggled by /afk.
        """
        let newYoloLead = """
            ahakey_override = get_ahakey_approval_override(force_refresh=True)
            if ahakey_override is not None:
                mode_label = "자동 승인" if bool(ahakey_override["is_auto"]) else "수동 승인"
                wire_send(
                    TextPart(
                        text=(
                            f"AhaKey 레버가 제어 중입니다. 현재 모드는 {mode_label}입니다. "
                            "키보드의 물리 레버를 직접 움직여 전환하세요. `/yolo`는 레버를 덮어쓰지 않습니다."
                        )
                    )
                )
                return

            # Inspect only the yolo flag: afk is independent and is toggled by /afk.
        """
        return try patchTextFile(
            atPath: path,
            marker: marker,
            replacements: [
                (oldImport, newImport + "\n"),
                (oldYoloLead, newYoloLead),
            ],
            friendlyName: "kimi_cli/soul/slash.py"
        )
    }

    private func patchTextFile(
        atPath path: String,
        marker: String,
        replacements: [(String, String)],
        friendlyName: String
    ) throws -> KimiCliPatchStatus {
        let url = URL(fileURLWithPath: path)
        var text = try String(contentsOf: url, encoding: .utf8)
        if text.contains(marker) {
            return .alreadyPatched
        }
        for (old, new) in replacements {
            guard text.contains(old) else {
                throw NSError(
                    domain: "AhaKeyKimiPatch",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(friendlyName)에서 교체할 업스트림 앵커를 찾지 못했습니다. kimi-cli 버전이 변경되었을 수 있습니다."]
                )
            }
            text = text.replacingOccurrences(of: old, with: new)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return .patched
    }

    @discardableResult
    private func removeKimiHooks() -> String {
        let path = kimiConfigPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "\(path)을(를) 찾지 못했습니다. Kimi Hooks를 제거할 필요가 없습니다."
        }
        guard let config = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "\(path)을(를) 읽을 수 없습니다. 권한을 확인하세요."
        }
        let next = removeLegacyKimiHookEntries(from: removeKimiHookBlock(from: config))
        guard next != config else {
            return "\(path)에서 AhaKey Kimi hook 표시 블록이나 구버전 단독 훅을 찾지 못했습니다."
        }
        do {
            try next.write(toFile: path, atomically: true, encoding: .utf8)
            log.info("Kimi 훅에서 AhaKey 표시 블록과 구버전 단독 훅을 제거했습니다")
            return "\(path)에서 AhaKey Kimi Hooks를 제거했습니다."
        } catch {
            return "제거된 내용을 만들었지만 \(path)에 다시 쓸 수 없습니다: \(error.localizedDescription)"
        }
    }

    private func buildKimiHookBlock() -> String {
        let binQuoted = shellQuote(agentBinaryPath)
        var lines: [String] = [
            kimiHookBlockStart,
            "# Managed by AhaKey Studio. Kimi CLI (Beta): multiple [[hooks]] entries; each runs with JSON on stdin.",
            "# Dial integration is managed by AhaKey Studio. Re-click 'Install Kimi Hooks' after kimi-cli upgrades, then reopen kimi once.",
        ]
        for item in kimiHookEntries {
            let cmdToml = escapeTomlBasicString("/bin/zsh -lc \(shellQuote("\(binQuoted) hook \(item.agentEvent)"))")
            lines.append("")
            lines.append("[[hooks]]")
            lines.append("event = \"\(item.event)\"")
            lines.append("matcher = \"\"")
            lines.append("command = \"\(cmdToml)\"")
            lines.append("timeout = \(item.timeout)")
        }
        lines.append("")
        lines.append(kimiHookBlockEnd)
        return lines.joined(separator: "\n")
    }

    private func removeKimiHookBlock(from config: String) -> String {
        var lines = config.components(separatedBy: .newlines)
        while let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == kimiHookBlockStart }),
              let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == kimiHookBlockEnd }) {
            lines.removeSubrange(start...end)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// BEGIN/END 표시 블록에 감싸이지 않은 구버전 AhaKey Kimi 훅을 정리해, 같은 이벤트가 두 번 트리거되는 것을 막는다.
    private func removeLegacyKimiHookEntries(from config: String) -> String {
        let lines = config.components(separatedBy: .newlines)
        var kept: [String] = []
        var idx = 0

        while idx < lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            guard trimmed == "[[hooks]]" else {
                kept.append(lines[idx])
                idx += 1
                continue
            }

            var block = [lines[idx]]
            idx += 1
            while idx < lines.count {
                let nextTrimmed = lines[idx].trimmingCharacters(in: .whitespaces)
                if nextTrimmed == "[[hooks]]" || nextTrimmed == kimiHookBlockStart || nextTrimmed == kimiHookBlockEnd {
                    break
                }
                block.append(lines[idx])
                idx += 1
            }

            let joined = block.joined(separator: "\n")
            if isAhakeyHookCommand(joined), joined.contains("hook Kimi") {
                continue
            }
            kept.append(contentsOf: block)
        }

        return kept.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// '제거 메인 흐름' 등 내부 호출용. UI 알림은 없다.
    private func removeCursorHooks() {
        _ = performRemoveCursorHooksUserMessage(writeAndLog: true, preferCompactMessage: true)
    }

    /// `~/.cursor/hooks.json`의 **모든** 이벤트에서 ahakey를 가리키는 항목을 삭제하고 파일에 다시 쓴다.
    /// - Returns: 사용자에게 보여 줄 설명 (팝업용). `writeAndLog==false`일 때는 문구만 반환하고 디스크에는 쓰지 않는다 (현재 사용하지 않음).
    private func performRemoveCursorHooksUserMessage(writeAndLog: Bool = true, preferCompactMessage: Bool = false) -> String {
        let path = cursorHooksPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "사용자 수준 \(path)을(를) 찾지 못했습니다.\n\n**프로젝트** 안에서만 `.cursor/hooks.json`을 병합했다면, 해당 프로젝트 루트에서 AhaKey 관련 항목을 직접 편집하거나 삭제해야 합니다. 사용자 수준에는 제거할 내용이 애초에 없습니다."
        }
        guard var settings = loadCursorSettings() else {
            return "\(path)을(를) 파싱할 수 없습니다(올바른 JSON이 아니거나 손상됨). 편집기로 열어 수정한 뒤 다시 시도하거나 백업에서 복원하세요."
        }
        guard var hooks = settings["hooks"] as? [String: Any], !hooks.isEmpty else {
            return "hooks.json에 'hooks'가 없거나 비어 있어 제거할 AhaKey 항목이 없습니다."
        }

        var removedCount = 0
        for event in Array(hooks.keys).sorted() {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            let before = entries.count
            entries.removeAll { isAhakeyHookCommand(($0["command"] as? String) ?? "") }
            removedCount += before - entries.count
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        if removedCount == 0 {
            return "\(path)에서 `ahakeyconfig-agent` 또는 `ahakey-state`를 포함한 `command`를 **찾지 못했습니다**.\n\n훅이 **프로젝트 수준** `.cursor/hooks.json`에 있다면 해당 저장소에서 직접 삭제하세요. 이 버튼은 사용자 수준 `~/.cursor/hooks.json`만 수정합니다."
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        if writeAndLog {
            if !saveCursorSettings(settings) {
                log.error("removeCursorHooks: hooks.json을 다시 쓸 수 없습니다")
                return "메모리상의 AhaKey 항목은 삭제했지만 \(path)에 **다시 쓸 수 없습니다**. '사용자 디렉터리의 .cursor'에 대한 쓰기 권한을 확인하거나, 이 파일을 점유하고 있는 다른 앱을 종료한 뒤 다시 시도하세요."
            }
            log.info("Cursor hooks: removed \(removedCount) ahakey command(s)")
        }

        if preferCompactMessage { return "" }
        return "사용자 수준 Cursor Hooks에서 AhaKey 관련 항목을 제거했습니다 (하위 명령 \(removedCount)개).\n\n파일: \(path)\n\n어떤 저장소에 **프로젝트 수준** `.cursor/hooks.json`이 남아 있고 그 안에 이 도구가 포함되어 있다면, 우선순위가 더 높을 수 있으므로 해당 프로젝트에서도 함께 삭제하거나 병합해야 합니다."
    }

    private func loadCursorSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: cursorHooksPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func saveCursorSettings(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: cursorHooksPath), options: .atomic)
            return true
        } catch {
            log.error("saveCursorSettings: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - launchctl

    private struct LaunchctlResult {
        let ok: Bool
        let mergedOutput: String
    }

    private func runLaunchctlDetailed(_ args: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return LaunchctlResult(ok: process.terminationStatus == 0, mergedOutput: text)
        } catch {
            return LaunchctlResult(ok: false, mergedOutput: error.localizedDescription)
        }
    }

    /// 다시 load할 때 시스템이 '이미 로드됨' 류의 메시지를 자주 내놓는데, 이를 치명적 오류로 취급하지 않는다.
    private func isBenignLaunchctlLoadMessage(_ message: String) -> Bool {
        let m = message.lowercased()
        if m.isEmpty { return false }
        if m.contains("already") { return true }
        if m.contains("repeated load") { return true }
        if m.contains("service already") { return true }
        return false
    }

    @discardableResult
    private func runLaunchctlQuiet(_ args: [String]) -> Bool {
        runLaunchctlDetailed(args).ok
    }
}
