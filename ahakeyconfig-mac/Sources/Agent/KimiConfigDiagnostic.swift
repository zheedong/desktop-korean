import Foundation

/// `~/.kimi/config.toml` 스냅샷을 읽는다. `default_yolo` 는 **레버→`KimiConfigLeverSync`** 경로로 `PreToolUse` 에서 기록될 수도 있다. 이미 열려 있는 세션은 kimi 에서 **`/reload`** 를 실행해야 새 값을 읽는다. PreToolUse 에서는 여전히 **`deny`** 만 훅 쪽 차단 의미를 가진다(`runner.py`).
enum KimiConfigDiagnostic {
    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi/config.toml", isDirectory: false)
    }

    /// `permission-request.log` 에 기록되는 `kimiLeverDebug` 블록.
    static func snapshotForLog() -> [String: Any] {
        let fm = FileManager.default
        let path = configURL.path
        var d: [String: Any] = [
            "kimiConfigPath": path,
            "kimiConfigExists": fm.fileExists(atPath: path),
            "hookApprovalPolicy": "dial_writes_default_yolo_on_PreToolUse_kimi_reload_to_apply_upstream_deny_only",
        ]
        guard let data = fm.contents(atPath: path),
              let raw = String(data: data, encoding: .utf8) else { return d }
        if let regex = try? NSRegularExpression(pattern: #"(?m)^\s*default_yolo\s*=\s*(\S+)"#, options: []),
           let m = regex.firstMatch(in: raw, options: [], range: NSRange(location: 0, length: (raw as NSString).length)),
           m.numberOfRanges > 1 {
            let ns = raw as NSString
            d["default_yolo_lineno_hint"] = "matched"
            d["default_yolo_valueSnippet"] = String(ns.substring(with: m.range(at: 1)).prefix(32))
        } else {
            d["default_yolo_valueSnippet"] = NSNull()
        }
        return d
    }
}
