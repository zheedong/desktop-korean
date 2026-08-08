import Foundation

/// Kimi PreToolUse 등 기기 측 디버그 로그: stderr(터미널에서 kimi 가 보게 된다) + 한 줄 JSON 을 **현재 작업 디렉터리**의 `kimi-hook-debug.log` 에 기록한다.
enum KimiHookDebugLog {
    private static let logFileName = "kimi-hook-debug.log"

    /// 훅의 stderr 에서 전체 JSON 줄 로그를 어디서 볼 수 있는지 사용자에게 알려 주기 위한 절대 경로.
    static var logPath: String { debugFileURL.path }

    private static var debugFileURL: URL {
        let cwd = FileManager.default.currentDirectoryPath
        let base = cwd.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : cwd
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(logFileName, isDirectory: false)
    }

    private static let isoTs: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// stderr 한 줄. 접두어를 통일해 `grep` 하기 쉽게 했고, kimi-cli 는 훅 도구의 stderr 를 그대로 출력한다(버전에 따라 다름).
    static func stderrLine(_ msg: String) {
        let line = "[aha-kimi] \(msg)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// 구조화된 형태로 디스크에 덧붙인다(`permission-request.log` 같은 App diagnostics 와 분리해, 경로에 공백이 있어 찾기 어려운 상황을 피한다).
    static func append(event: String, details: [String: Any]) {
        let cwd = FileManager.default.currentDirectoryPath
        var payload: [String: Any] = [
            "ts": isoTs.string(from: Date()),
            "event": event,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "cwd": cwd.isEmpty ? NSNull() : cwd,
        ]
        for (k, v) in details { payload[k] = v }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              var line = String(data: data, encoding: .utf8) else {
            stderrLine("debug log JSON encode failed event=\(event)")
            return
        }
        line += "\n"

        let url = debugFileURL
        let fm = FileManager.default
        do {
            // 로그는 cwd 아래에 있으므로 디렉터리는 이미 존재해야 한다. cwd 가 비어 home 으로 되돌아간 경우에는 상위 디렉터리 존재를 보장한다
            if FileManager.default.currentDirectoryPath.isEmpty {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: url.path) {
                try line.data(using: .utf8)?.write(to: url, options: .atomic)
            } else if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            }
        } catch {
            let fallback = "[aha-kimi] append log failed \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(fallback.utf8))
        }
    }
}
