import Foundation

/// 레버가 0 일 때 `~/.cursor/cli-config.json` 의 `permissions` 를 일시적으로 완화한다(흔한 허용 목록 항목을 막지 않는 것과 같다).
/// 0 이 아니면 최초 시점의 스냅샷에서 복원하며, HookClient 의 `permission` 출력과 함께 사용한다.
///
/// 참고: Cursor 가 스스로 읽는 전역/설정 계층에만 영향을 준다. `switchState` 를 읽지 못했을 때(nil)는 파일을 변경하지 않는다.
enum CursorCliLeverSync {
    private static let cliName = "cli-config.json"
    private static var cliURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent(cliName, isDirectory: false)
    }

    private static var snapshotURL: URL { cliURL.appendingPathExtension("ahakey.lever0.bak") }
    private static var hadNoPriorCliMarker: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent(".ahakey_had_no_cli_config", isDirectory: false)
    }

    /// 와일드카드는 Cursor 문서와 동일하다. 여기에 `Shell(cd)` / `Shell(swift)` 처럼 명시적인 항목도 포함한다: 일부 버전의 에이전트 TUI 는
    /// 「Not in allowlist: cd /path, swift …」를 표시할 때 `Shell(*)` 를 복합 명령줄과 맞추지 못하므로, 첫 단어/툴체인을 따로 적어야 한다.
    private static let relaxedAllow: [String] = [
        "Shell(*)", "Shell(cd)", "Shell(swift)", "Shell(bash)", "Shell(zsh)", "Shell(sh)",
        "Read(**/*)", "Write(**/*)", "WebFetch(*)", "Mcp(*:*)",
    ]

    /// `permission: allow|ask` 를 기록하기 **전에** 호출해서, Cursor 가 이후 설정을 읽을 때 이미 완화/복원된 상태가 되도록 보장한다.
    static func apply(switchStateAuto: Bool) {
        if switchStateAuto {
            applyRelaxed()
        } else {
            restoreIfneeded()
        }
    }

    private static func applyRelaxed() {
        let cursorDir = cliURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)

        let fm = FileManager.default
        if !fm.fileExists(atPath: snapshotURL.path) && !fm.fileExists(atPath: hadNoPriorCliMarker.path) {
            if fm.fileExists(atPath: cliURL.path) {
                do {
                    if fm.fileExists(atPath: snapshotURL.path) { try? fm.removeItem(at: snapshotURL) }
                    try fm.copyItem(at: cliURL, to: snapshotURL)
                } catch {
                    fprintStderr("CursorCliLeverSync: 기존 cli-config 를 백업할 수 없습니다: \(error.localizedDescription)\n")
                }
            } else {
                do {
                    try Data().write(to: hadNoPriorCliMarker, options: .atomic)
                } catch { /* 무시 */ }
            }
        }

        var root = readJson(cliURL) ?? [:]
        if root["version"] == nil { root["version"] = 1 }
        var perms = root["permissions"] as? [String: Any] ?? [:]
        var allow = stringArray(from: perms["allow"])
        for token in relaxedAllow {
            if !allow.contains(token) { allow.append(token) }
        }
        perms["allow"] = allow
        if perms["deny"] == nil { perms["deny"] = [String]() }
        root["permissions"] = perms
        root["approvalMode"] = "auto"
        if !writeJson(root, to: cliURL) {
            fprintStderr("CursorCliLeverSync: \(cliURL.path) 에 기록할 수 없습니다(훅의 permission 은 그대로 반환합니다)\n")
        }
    }

    private static func restoreIfneeded() {
        let fm = FileManager.default
        if fm.fileExists(atPath: hadNoPriorCliMarker.path) {
            try? fm.removeItem(at: hadNoPriorCliMarker)
            if fm.fileExists(atPath: cliURL.path) {
                try? fm.removeItem(at: cliURL)
            }
            if fm.fileExists(atPath: snapshotURL.path) {
                try? fm.removeItem(at: snapshotURL)
            }
            return
        }
        guard fm.fileExists(atPath: snapshotURL.path) else { return }
        do {
            if fm.fileExists(atPath: cliURL.path) { try fm.removeItem(at: cliURL) }
            try fm.copyItem(at: snapshotURL, to: cliURL)
            try fm.removeItem(at: snapshotURL)
        } catch {
            fprintStderr("CursorCliLeverSync: 스냅샷에서 cli-config 를 복원할 수 없습니다: \(error.localizedDescription)\n")
        }
    }

    private static func readJson(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return o
    }

    @discardableResult
    private static func writeJson(_ root: [String: Any], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func stringArray(from v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let a = v as? [Any] { return a.compactMap { $0 as? String } }
        return []
    }

    private static func fprintStderr(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }

    // MARK: - 진단(permission-request.log)

    /// 기록/복원 후의 `~/.cursor/cli-config.json` 및 레버 동기화 관련 보조 파일 상태를 `HookClient` 의 로그용으로 제공한다.
    static func diagnosticSnapshotForLog() -> [String: Any] {
        let fm = FileManager.default
        var d: [String: Any] = [
            "userCliConfigPath": cliURL.path,
            "userCliConfigExists": fm.fileExists(atPath: cliURL.path),
            "lever0SnapshotBakExists": fm.fileExists(atPath: snapshotURL.path),
            "hadNoPriorCliMarkerExists": fm.fileExists(atPath: hadNoPriorCliMarker.path),
        ]
        guard let root = readJson(cliURL) else { return d }
        d["cliConfigVersion"] = root["version"] as Any
        d["approvalMode"] = root["approvalMode"] as Any
        if let sb = root["sandbox"] {
            d["cliConfigSandboxPreview"] = String(String(describing: sb).prefix(400))
        }
        if let perms = root["permissions"] as? [String: Any] {
            let allow = stringArray(from: perms["allow"])
            let deny = stringArray(from: perms["deny"])
            d["permissionsAllowCount"] = allow.count
            d["permissionsDenyCount"] = deny.count
            d["permissionsHasShellStar"] = allow.contains("Shell(*)")
            d["permissionsAllowHasReadStar"] = allow.contains { $0.hasPrefix("Read(") && $0.contains("*") }
            d["permissionsAllowHasWriteStar"] = allow.contains { $0.hasPrefix("Write(") && $0.contains("*") }
        }
        return d
    }
}
