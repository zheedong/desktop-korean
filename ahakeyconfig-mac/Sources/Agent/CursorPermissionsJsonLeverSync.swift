import Foundation

/// IDE 안의 에이전트 터미널 TUI 에 나타나는 **「Not in allowlist」** 는 `~/.cursor/permissions.json` 의 **`terminalAllowlist`** 와
/// 관련이 있다(Cursor 문서 「permissions.json reference」 참고). 이는 **`~/.cursor/cli-config.json`(CLI 권한)과는 별개의 체계다**.
/// cli-config 만 고쳐도 이 TUI 에는 반영되지 않는다. 레버가 0 일 때 이 파일의 `terminalAllowlist` 에 접두어 항목을 병합한다.
enum CursorPermissionsJsonLeverSync {
    private static var permURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("permissions.json", isDirectory: false)
    }

    private static var snapshotURL: URL { permURL.appendingPathExtension("ahakey.lever0.bak") }
    private static var hadNoPriorMarker: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent(".ahakey_had_no_permissions_json", isDirectory: false)
    }

    /// 문서 「Terminal allowlist format」과 동일하다: 접두어 매칭이므로 예를 들어 `cd` 는 `cd ` 로 시작하는 줄 전체와 일치한다. `cd … && swift …` 가 분리되어 검사되는 경우를 감당하려고 `swift` 등도 포함한다.
    private static let relaxedTerminalPrefixes: [String] = [
        "cd", "swift", "swift build", "xcodebuild", "git", "npm", "yarn", "pnpm", "bun", "deno", "node",
        "make", "cargo", "go", "python3", "python", "ruby", "bash", "zsh", "sh", "curl", "ls",
    ]

    static func apply(switchStateAuto: Bool) {
        if switchStateAuto {
            applyRelaxed()
        } else {
            restoreIfNeeded()
        }
    }

    private static func applyRelaxed() {
        let dir = permURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fm = FileManager.default
        if !fm.fileExists(atPath: snapshotURL.path) && !fm.fileExists(atPath: hadNoPriorMarker.path) {
            if fm.fileExists(atPath: permURL.path) {
                do {
                    if fm.fileExists(atPath: snapshotURL.path) { try? fm.removeItem(at: snapshotURL) }
                    try fm.copyItem(at: permURL, to: snapshotURL)
                } catch {
                    fprintStderr("CursorPermissionsJsonLeverSync: 기존 permissions.json 을 백업할 수 없습니다: \(error.localizedDescription)\n")
                }
            } else {
                try? Data().write(to: hadNoPriorMarker, options: .atomic)
            }
        }

        var root = readJson(permURL) ?? [:]
        var list = stringArray(root["terminalAllowlist"])
        for t in relaxedTerminalPrefixes where !list.contains(t) {
            list.append(t)
        }
        root["terminalAllowlist"] = list
        if !writeJson(root, to: permURL) {
            fprintStderr("CursorPermissionsJsonLeverSync: \(permURL.path) 에 기록할 수 없습니다\n")
        }
    }

    private static func restoreIfNeeded() {
        let fm = FileManager.default
        if fm.fileExists(atPath: hadNoPriorMarker.path) {
            try? fm.removeItem(at: hadNoPriorMarker)
            if fm.fileExists(atPath: permURL.path) { try? fm.removeItem(at: permURL) }
            if fm.fileExists(atPath: snapshotURL.path) { try? fm.removeItem(at: snapshotURL) }
            return
        }
        guard fm.fileExists(atPath: snapshotURL.path) else { return }
        do {
            if fm.fileExists(atPath: permURL.path) { try fm.removeItem(at: permURL) }
            try fm.copyItem(at: snapshotURL, to: permURL)
            try fm.removeItem(at: snapshotURL)
        } catch {
            fprintStderr("CursorPermissionsJsonLeverSync: 스냅샷에서 permissions.json 을 복원할 수 없습니다: \(error.localizedDescription)\n")
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

    private static func stringArray(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let a = v as? [Any] { return a.compactMap { $0 as? String } }
        return []
    }

    private static func fprintStderr(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }

    // MARK: - 진단

    static func diagnosticSnapshotForLog() -> [String: Any] {
        let fm = FileManager.default
        var d: [String: Any] = [
            "permissionsJsonPath": permURL.path,
            "permissionsJsonExists": fm.fileExists(atPath: permURL.path),
            "lever0SnapshotBakExists": fm.fileExists(atPath: snapshotURL.path),
            "hadNoPriorMarkerExists": fm.fileExists(atPath: hadNoPriorMarker.path),
        ]
        guard let root = readJson(permURL) else { return d }
        let t = stringArray(root["terminalAllowlist"])
        d["terminalAllowlistCount"] = t.count
        d["terminalAllowlistHasPrefix_cd"] = t.contains { $0 == "cd" || $0.hasPrefix("cd:") }
        d["terminalAllowlistHasPrefix_swift"] = t.contains { $0 == "swift" || $0.hasPrefix("swift ") }
        d["mcpAllowlistDefined"] = (root["mcpAllowlist"] != nil)
        return d
    }
}
