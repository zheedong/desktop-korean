import Foundation

enum CursorHookHandler {
    static func handleToolPermission(hookEvent: String) {
        let stdinData = HookSupport.readAllStdinSilently()
        let ctx = HookSupport.parseStdinContext(stdinData, label: "Cursor")
        let request: [String: Any] = ["cmd": "permission", "value": Int(HookSupport.permissionLedValue)]
        let reply = HookSupport.sendJsonRequest(request, timeout: HookSupport.permissionRequestTimeout)
        let switchState = HookSupport.resolvedSwitchState(reply: reply)
        let isAuto = switchState == 0

        if isAuto {
            // 자동 모드: allow 를 반환해 작업이 바로 실행되게 한다
            let out: [String: Any] = ["permission": "allow"]
            if let data = try? JSONSerialization.data(withJSONObject: out, options: []),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            // 수동 모드: deny 를 반환해 작업을 차단한다(Cursor 는 확인 요청 모드를 지원하지 않는다)
            let out: [String: Any] = ["permission": "deny"]
            if let data = try? JSONSerialization.data(withJSONObject: out, options: []),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            HookSupport.emitPermissionStderr(
                ide: "Cursor",
                hookName: hookEvent,
                reply: reply,
                switchState: switchState
            )
        }

        if let s = switchState {
            let auto = s == 0
            CursorCliLeverSync.apply(switchStateAuto: auto)
            CursorPermissionsJsonLeverSync.apply(switchStateAuto: auto)
        }

        let cursorDebug = HookSupport.buildCursorHookDebug(
            stdinData: stdinData,
            commandPreview: ctx["commandPreview"] as? String
        )
        HookSupport.appendDiagnostic(
            ide: "cursor",
            hookEvent: hookEvent,
            toolContext: ctx,
            reply: reply,
            switchState: switchState,
            isAuto: isAuto,
            claudeBehavior: nil,
            cursorPermission: isAuto ? "allow" : "deny",
            cursorDebug: cursorDebug,
            kimiPreToolDecision: nil
        )
    }
}
