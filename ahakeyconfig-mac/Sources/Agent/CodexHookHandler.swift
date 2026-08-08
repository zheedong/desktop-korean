import Foundation

enum CodexHookHandler {
    static func handleState(stateValue: UInt8) {
        let stdinData = HookSupport.readAllStdinSilently()
        let ctx = HookSupport.parseStdinContext(stdinData, label: "Codex")
        let reply = HookSupport.sendUnifiedLightState(stateValue: stateValue)
        let switchState = HookSupport.resolvedSwitchState(reply: reply)

        // SessionStart 시점에 레버 상태를 최상위 approval_policy 에 기록한다:
        // Codex 는 세션 시작 시점에 승인 정책을 읽고, 그 다음에야 PermissionRequest 를 발생시킬지 결정한다.
        // 따라서 여기서 동기화해야 "자동/수동"이 이번 세션에 적용된다.
        // 주의: `cmd: "state"` 의 응답에는 switchState 가 없다(AhaKeyAgent.handleJsonCommand 참고).
        // 레버의 실제 상태를 알려면 `status` 를 따로 보내 조회해야 한다.
        if stateValue == 4 {
            let statusReply = HookSupport.sendJsonRequest(["cmd": "status"], timeout: HookSupport.stateRequestTimeout)
            if let s = HookSupport.intValue(statusReply?["switchState"]) {
                CodexConfigLeverSync.apply(switchStateAuto: s == 0)
            }
        }

        HookSupport.appendCodexHookLog(
            hookEvent: ctx["hook_event_name"] as? String,
            agentEvent: codexAgentEventName(forStateValue: stateValue),
            stateValue: stateValue,
            toolContext: ctx,
            reply: reply,
            switchState: switchState,
            decision: nil
        )
        print("{}")
    }

    static func handlePermissionRequest() {
        let stdinData = HookSupport.readAllStdinSilently()
        let ctx = HookSupport.parseStdinContext(stdinData, label: "Codex")
        let request: [String: Any] = ["cmd": "permission", "value": Int(HookSupport.permissionLedValue)]
        let reply = HookSupport.sendJsonRequest(request, timeout: HookSupport.permissionRequestTimeout)
        let switchState = HookSupport.resolvedSwitchState(reply: reply)
        let isAuto = switchState == 0

        if let s = switchState {
            CodexConfigLeverSync.apply(switchStateAuto: s == 0)
        }

        if !isAuto {
            HookSupport.emitPermissionStderr(
                ide: "Codex",
                hookName: "PermissionRequest",
                reply: reply,
                switchState: switchState
            )
        }

        var hookOut: [String: Any] = ["hookEventName": "PermissionRequest"]
        if isAuto {
            hookOut["decision"] = ["behavior": "allow"]
        }
        HookSupport.appendCodexHookLog(
            hookEvent: "PermissionRequest",
            agentEvent: "CodexPermissionRequest",
            stateValue: HookSupport.permissionLedValue,
            toolContext: ctx,
            reply: reply,
            switchState: switchState,
            decision: isAuto ? "allow" : "pass_through"
        )
        let out: [String: Any] = ["hookSpecificOutput": hookOut]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: []),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }

        HookSupport.appendDiagnostic(
            ide: "codex",
            hookEvent: "PermissionRequest",
            toolContext: ctx,
            reply: reply,
            switchState: switchState,
            isAuto: isAuto,
            claudeBehavior: nil,
            cursorPermission: nil,
            cursorDebug: nil,
            kimiPreToolDecision: nil
        )
    }

    private static func codexAgentEventName(forStateValue stateValue: UInt8) -> String {
        switch stateValue {
        case 2: return "CodexPostToolUse"
        case 3: return "CodexPreToolUse"
        case 4: return "CodexSessionStart"
        case 5: return "CodexStop"
        case 7: return "CodexUserPromptSubmit"
        default: return "CodexState\(stateValue)"
        }
    }
}
