import Foundation

/// 키보드 레버를 Kimi **`~/.kimi/config.toml`** 의 루트 수준 **`default_yolo`** 와 맞춘다: **자동 단계는 `true`, 수동 단계는 `false`**.
///
/// 수동 단계를 나타내는 데 「전체 파일 스냅샷 복원」을 쓰지 않는다: 사용자가 원래 YOLO 를 켜 둔 상태였다면 스냅샷에 `default_yolo=true` 가 그대로 기록되고, 복원하는 순간 `/reload` 를 어떻게 해도 다시 YOLO 로 돌아가기 때문이다. 자동 단계에서는 첫 기록 전에 **`.ahakey.lever0.bak`** 백업을 남겨 두어 나중에 직접 비교할 수 있게 한다. 수동 단계로 전환할 때는 다시 잘못 복원되지 않도록 그 스냅샷을 삭제한다.
enum KimiConfigLeverSync {
    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi/config.toml", isDirectory: false)
    }

    private static var snapshotURL: URL { configURL.appendingPathExtension("ahakey.lever0.bak") }

    static func apply(switchStateAuto: Bool) {
        if switchStateAuto {
            enableYoloInConfig()
        } else {
            disableDefaultYoloForManualDial()
        }
    }

    private static func enableYoloInConfig() {
        let fm = FileManager.default
        let path = configURL.path
        guard fm.fileExists(atPath: path) else {
            fprintStderr("KimiConfigLeverSync: \(path) 를 찾을 수 없어 건너뜁니다.\n")
            KimiHookDebugLog.append(event: "kimi_lever_sync_missing_config", details: ["path": path])
            return
        }

        if !fm.fileExists(atPath: snapshotURL.path) {
            do {
                try fm.copyItem(at: configURL, to: snapshotURL)
                KimiHookDebugLog.append(event: "kimi_lever_sync_backup_created", details: ["to": snapshotURL.path])
            } catch {
                fprintStderr("KimiConfigLeverSync: 백업 실패 \(error.localizedDescription)\n")
                KimiHookDebugLog.append(event: "kimi_lever_sync_backup_failed", details: ["error": error.localizedDescription])
            }
        }

        guard let data = fm.contents(atPath: path),
              var raw = String(data: data, encoding: .utf8) else {
            fprintStderr("KimiConfigLeverSync: \(path) 를 읽을 수 없습니다\n")
            return
        }
        raw = replaceOrInsertDefaultYolo(raw, template: #"default_yolo = true  # AhaKey: dial auto; run /reload in Kimi after changing dial"#)
        writeRaw(raw, label: "enable_auto")
    }

    private static func disableDefaultYoloForManualDial() {
        let fm = FileManager.default
        let path = configURL.path
        // 예전 로직이 쓰던 스냅샷을 삭제한다: 수동 단계에서 이 스냅샷으로 「전체 파일 복원」을 하면 원래의 default_yolo=true 가 통째로 되살아난다.
        if fm.fileExists(atPath: snapshotURL.path) {
            do {
                try fm.removeItem(at: snapshotURL)
                KimiHookDebugLog.append(event: "kimi_lever_snapshot_removed_for_manual_clear", details: [:])
                KimiHookDebugLog.stderrLine("removed config.toml.ahakey.lever0.bak (avoid restoring old default_yolo=true)")
            } catch {
                fprintStderr("KimiConfigLeverSync: 스냅샷을 삭제할 수 없습니다 \(error.localizedDescription)\n")
            }
        }
        guard fm.fileExists(atPath: path) else { return }
        guard let data = fm.contents(atPath: path),
              var raw = String(data: data, encoding: .utf8) else { return }
        raw = replaceOrInsertDefaultYolo(raw, template: #"default_yolo = false  # AhaKey: dial manual; run /reload in Kimi after changing dial"#)
        writeRaw(raw, label: "disable_manual")
        KimiHookDebugLog.stderrLine("default_yolo=false on dial manual; run /reload in Kimi.")
        // kimi-cli: effective_yolo = load_config.default_yolo OR session persist state.json approval.yolo
        KimiHookDebugLog.stderrLine(
            "note: kimi ORs persisted session YOLO (e.g. after /yolo) with config — if reload still shows yolo, toggle /yolo off once or use a fresh session."
        )
    }

    private static func replaceOrInsertDefaultYolo(_ text: String, template: String) -> String {
        let pattern = #"(?m)^\s*default_yolo\s*=\s*[^\r\n]*\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return template + "\n\n" + text
        }
        let nsFull = text as NSString
        let fullRange = NSRange(location: 0, length: nsFull.length)
        if regex.firstMatch(in: text, options: [], range: fullRange) != nil {
            return regex.stringByReplacingMatches(in: text, options: [], range: fullRange, withTemplate: template)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return template + "\n" }
        return template + "\n\n" + text
    }

    private static func writeRaw(_ raw: String, label: String) {
        guard let out = raw.data(using: .utf8) else { return }
        do {
            try out.write(to: configURL, options: .atomic)
            KimiHookDebugLog.append(event: "kimi_lever_sync_\(label)", details: [
                "bytes": out.count,
                "reloadHint": "kimi_reload_slash_same_session_ok",
            ])
        } catch {
            fprintStderr("KimiConfigLeverSync: 기록 실패 \(error.localizedDescription)\n")
            KimiHookDebugLog.append(event: "kimi_lever_sync_write_failed", details: ["error": error.localizedDescription])
        }
    }

    private static func fprintStderr(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }

    /// `permission-request.log` 의 `kimiLeverDebug` 용.
    static func diagnosticSnapshotForLog() -> [String: Any] {
        var d = KimiConfigDiagnostic.snapshotForLog()
        d["leverSnapshotBakExists"] = FileManager.default.fileExists(atPath: snapshotURL.path)
        return d
    }
}
