import Foundation

// ahakeyconfig-agent
//
// 두 가지 실행 모드(첫 번째 인자로 결정된다):
//   1. Daemon(인자 없음 / --socket 만 전달): LaunchAgent 로 상주하며 BLE 연결 유지 + Unix socket 수신
//        ahakeyconfig-agent [--socket /tmp/ahakey.sock]
//   2. Hook 하위 명령(첫 번째 인자가 hook): Claude Code / Cursor / Codex / Kimi Code CLI 가 이 프로세스를 exec 한다
//        ahakeyconfig-agent hook <EventName>
//      내부적으로 Unix socket 을 통해 상주 daemon 과 통신하고, 필요에 따라 Claude 결정 JSON 을 stdout 으로 출력한다.

let args = CommandLine.arguments

if args.count >= 3, args[1] == "hook" {
    let event = args[2]
    exit(HookClient.run(event: event))
}

// Daemon 모드
let socketPath: String
if let idx = args.firstIndex(of: "--socket"), idx + 1 < args.count {
    socketPath = args[idx + 1]
} else {
    socketPath = "/tmp/ahakey.sock"
}

let agent = AhaKeyAgent(socketPath: socketPath)
agent.onLog = { msg in
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(msg)")
}
guard agent.startSocketListener() else {
    exit(EXIT_FAILURE)
}

// 계속 실행 상태 유지
RunLoop.main.run()
