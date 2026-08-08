import Foundation

/// 이벤트 라우팅만 담당한다. IDE 별 구체적인 로직은 별도 handler 로 분리해 서로 영향을 주지 않도록 했다.
enum HookClient {
    private enum EventRoute {
        case sharedState(UInt8)
        case claudePermissionRequest
        case cursorToolPermission
        case codexState(UInt8)
        case codexPermissionRequest
        case kimiPreToolPermission
    }

    private static let eventMap: [String: EventRoute] = [
        "Notification": .sharedState(0),
        "PermissionRequest": .claudePermissionRequest,
        "PostToolUse": .sharedState(2),
        "PreToolUse": .sharedState(3),
        "SessionStart": .sharedState(4),
        "Stop": .sharedState(5),
        // SubagentStop: Claude Code 가 기존 Stop 을 분리한 뒤로는, 작업을 수동으로 종료하면 Stop 대신 이 이벤트가 발생한다
        "SubagentStop": .sharedState(5),
        "TaskCompleted": .sharedState(6),
        "UserPromptSubmit": .sharedState(7),
        "SessionEnd": .sharedState(8),
        "PreCompact": .sharedState(0),

        "sessionStart": .sharedState(4),
        "sessionEnd": .sharedState(8),
        "postToolUse": .sharedState(2),
        "stop": .sharedState(5),
        "preToolUse": .cursorToolPermission,
        "beforeShellExecution": .cursorToolPermission,
        "beforeMCPExecution": .cursorToolPermission,

        "CodexSessionStart": .codexState(4),
        "CodexPostToolUse": .codexState(2),
        "CodexPreToolUse": .codexState(3),
        "CodexUserPromptSubmit": .codexState(7),
        "CodexStop": .codexState(5),
        "CodexPermissionRequest": .codexPermissionRequest,

        "KimiNotification": .sharedState(0),
        "KimiSessionStart": .sharedState(4),
        "KimiSessionEnd": .sharedState(8),
        "KimiPreToolUse": .kimiPreToolPermission,
        "KimiPostToolUse": .sharedState(2),
        "KimiUserPromptSubmit": .sharedState(7),
        "KimiStop": .sharedState(5),
    ]

    static func run(event: String) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        
        // 디버그 로그: 수신한 모든 이벤트를 기록한다
        FileHandle.standardError.write(Data("[ahakey-hook] DEBUG: received event: '\(event)'\n".utf8))
        
        guard let route = eventMap[event] else {
            FileHandle.standardError.write(Data("[ahakey-hook] unknown event: \(event)\n".utf8))
            return 0
        }

        switch route {
        case .sharedState(let value):
            HookSupport.handleFireAndForgetState(stateValue: value)
        case .claudePermissionRequest:
            ClaudeHookHandler.handlePermissionRequest()
        case .cursorToolPermission:
            CursorHookHandler.handleToolPermission(hookEvent: event)
        case .codexState(let value):
            CodexHookHandler.handleState(stateValue: value)
        case .codexPermissionRequest:
            CodexHookHandler.handlePermissionRequest()
        case .kimiPreToolPermission:
            KimiHookHandler.handlePreToolPermission()
        }
        return 0
    }
}
