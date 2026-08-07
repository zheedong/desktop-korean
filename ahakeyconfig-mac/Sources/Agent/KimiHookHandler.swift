import Foundation

enum KimiHookHandler {
    static func handlePreToolPermission() {
        let stdinData = HookSupport.readAllStdinSilently()
        let ctx = HookSupport.parseStdinContext(stdinData, label: "Kimi")
        KimiHookDebugLog.append(event: "kimi_PreToolUse_start", details: [
            "stdinBytes": stdinData.count,
            "toolPreview": ctx,
            "hintLogFile": KimiHookDebugLog.logPath,
        ])
        KimiHookDebugLog.stderrLine("PreToolUse hook start bytes=\(stdinData.count); full log=\(KimiHookDebugLog.logPath)")

        let request: [String: Any] = ["cmd": "permission", "value": Int(HookSupport.permissionLedValue)]
        let reply = HookSupport.sendJsonRequest(request, timeout: HookSupport.permissionRequestTimeout)
        let switchState = HookSupport.intValue(reply?["switchState"])
        let isAuto = switchState == 0

        KimiHookDebugLog.append(event: "kimi_PreToolUse_agent_reply", details: [
            "agentReplyNil": reply == nil,
            "switchState": switchState.map { $0 } ?? NSNull(),
            "computedIsAuto": isAuto,
            "replyPreview": kimiReplyPreview(reply),
        ])
        KimiHookDebugLog.stderrLine("agent socket reply: switchState=\(switchState.map { String($0) } ?? "nil") isAuto=\(isAuto)")

        let stdoutPayload: String
        let kimiPreToolDecision: String
        if isAuto {
            stdoutPayload = ""
            kimiPreToolDecision = "auto_no_stdout_no_veto"
        } else {
            stdoutPayload = ""
            kimiPreToolDecision = "manual_lever_no_stdout"
            HookSupport.emitPermissionStderr(
                ide: "Kimi",
                hookName: "PreToolUse",
                reply: reply,
                switchState: switchState
            )
        }

        let kimiProbeInitial = KimiConfigDiagnostic.snapshotForLog()
        KimiHookDebugLog.append(event: "kimi_PreToolUse_probe_before_lever_sync", details: [
            "kimiLeverDebug_preview": kimiProbeInitial,
            "switchStateNil": switchState == nil,
            "kimiRunnerNote": "upstream_kimi_hooks_runner_only_handles_permissionDecision_deny",
        ])
        var leverSnapshotForLog = kimiProbeInitial
        if switchState == nil {
            KimiHookDebugLog.stderrLine("no switchState from agent → skipped default_yolo sync; kimiPreTool=\(kimiPreToolDecision); check BLE/agent")
        } else {
            KimiConfigLeverSync.apply(switchStateAuto: isAuto)
            leverSnapshotForLog = KimiConfigLeverSync.diagnosticSnapshotForLog()
            KimiHookDebugLog.append(event: "kimi_PreToolUse_after_default_yolo_disk_sync", details: leverSnapshotForLog)
            KimiHookDebugLog.stderrLine(
                "default_yolo synced on disk (\(isAuto ? "true" : "false")); if kimi is already running: enter /reload in that session — no quit needed."
            )
            let yoloSnippet: String
            if let v = leverSnapshotForLog["default_yolo_valueSnippet"], !(v is NSNull) {
                yoloSnippet = String(describing: v)
            } else {
                yoloSnippet = "(unset/absent)"
            }
            KimiHookDebugLog.stderrLine("on-disk default_yolo now reads \(yoloSnippet); /reload picks it up.")
        }

        if !stdoutPayload.isEmpty {
            FileHandle.standardOutput.write(Data(stdoutPayload.utf8))
        }
        KimiHookDebugLog.append(event: "kimi_PreToolUse_stdout", details: [
            "kimiDecision": kimiPreToolDecision,
            "stdoutChars": stdoutPayload.count,
            "hint": "kimi-cli 는 KimiCLI.create/load_config 에서 default_yolo 를 읽는다. 이미 열려 있는 세션에서는 /reload 만 입력하면 된다(kimi 를 종료할 필요는 없다). PreToolUse 에서는 여전히 deny 만 도구를 차단하며, default_yolo 는 대화형 승인 계층을 담당한다.",
        ])
        KimiHookDebugLog.stderrLine("stdout chars=\(stdoutPayload.count) decision=\(kimiPreToolDecision)")

        HookSupport.appendDiagnostic(
            ide: "kimi",
            hookEvent: "PreToolUse",
            toolContext: ctx,
            reply: reply,
            switchState: switchState,
            isAuto: isAuto,
            claudeBehavior: nil,
            cursorPermission: nil,
            cursorDebug: nil,
            kimiPreToolDecision: kimiPreToolDecision,
            kimiLeverDebug: KimiConfigLeverSync.diagnosticSnapshotForLog()
        )
    }

    private static func kimiReplyPreview(_ reply: [String: Any]?) -> [String: Any] {
        guard let reply else {
            return ["nil": true]
        }
        var o: [String: Any] = [:]
        if let sv = reply["switchState"] {
            o["switchState"] = String(String(describing: sv).prefix(48))
        }
        if let ok = reply["ok"] {
            o["ok"] = ok
        }
        if let err = reply["error"] as? String {
            o["error"] = String(err.prefix(160))
        }
        return o
    }
}
