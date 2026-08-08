import Foundation

// PluginClient 위에 「호스트 기능」 계층을 덧씌웁니다. `host/*` JSON-RPC method 집합을 등록해
// 플러그인이 호스트가 제공하는 서비스를 호출할 수 있게 합니다.
//
// 현재 최소 구성 세 가지:
//   - host/getInfo          → 호스트 앱 메타 정보 반환(bundleID / version / build / platform)
//   - host/log              → 플러그인이 로그를 호스트 stderr로 출력
//   - host/getSwitchState   → /tmp/ahakey.sock을 통해 daemon에 스위치 상태를 조회(agent가 실행 중이 아니면 null 반환)
//
// 앞으로 추가할 항목(host/showNotification, host/openURL, host/storage/* 등)도 같은 방식으로
// `registerDefaultHandlers`에 연결하면 됩니다. 새 메서드를 추가할 때는 매니페스트의 권한 허용 목록에도 함께 선언해야 합니다.

public final class PluginHost: @unchecked Sendable {
    public let client: PluginClient
    public let appInfo: HostAppInfo

    /// 해당 플러그인이 호출할 수 있는 `host/*` 메서드 집합입니다. `nil`이면 제한하지 않습니다(데모 / 자체 제작용으로만 사용).
    public let permissions: Set<String>?

    public init(
        client: PluginClient,
        appInfo: HostAppInfo = .current(),
        permissions: Set<String>? = nil
    ) {
        self.client = client
        self.appInfo = appInfo
        self.permissions = permissions
    }

    /// 호스트가 현재 노출하는 모든 `host/*` 메서드 이름입니다. `plugin/initialize` 시 플러그인에 알려 주는 데 사용합니다.
    public static let availableHostMethods: [String] = [
        "host/getInfo",
        "host/log",
        "host/getSwitchState",
    ]

    /// 기본 `host/*` 메서드 집합을 등록합니다. `client.start()`보다 먼저 호출해야 합니다.
    public func registerDefaultHandlers() async {
        let appInfo = self.appInfo

        await register("host/getInfo") { _ in
            try JSONValue.encode(appInfo)
        }

        await register("host/log") { params in
            HostLog.write(params: params)
            return .null
        }

        await register("host/getSwitchState") { _ in
            let state = HostAgentBridge.readSwitchState()
            return .object([
                "switchState": state.map { JSONValue.int($0) } ?? .null,
                "agentReachable": .bool(state != nil),
            ])
        }
    }

    /// 권한 검사를 한 겹 씌워 등록합니다. `permissions`에 없는 method는 -32601로 바로 거부됩니다.
    private func register(
        _ method: String,
        _ handler: @escaping PluginClient.RequestHandler
    ) async {
        let permissions = self.permissions
        await client.setRequestHandler(method) { params in
            if let permissions, !permissions.contains(method) {
                throw JSONRPCError(
                    code: JSONRPCError.methodNotFound,
                    message: "Method \(method) not in plugin permissions",
                    data: nil
                )
            }
            return try await handler(params)
        }
    }
}

// MARK: - host/getInfo

public struct HostAppInfo: Codable, Sendable {
    public let bundleID: String
    public let version: String
    public let build: String
    public let platform: String

    public init(bundleID: String, version: String, build: String, platform: String = "macos") {
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.platform = platform
    }

    /// `Bundle.main`에서 읽습니다. 호스트가 앱 번들이 아닐 때(예: 이 Plugin 데모 실행 파일)는 기본값을 사용합니다.
    public static func current() -> HostAppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return .init(
            bundleID: Bundle.main.bundleIdentifier ?? "dev.ahakey.unknown",
            version: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
            build: info["CFBundleVersion"] as? String ?? "0"
        )
    }
}

// MARK: - host/log

enum HostLog {
    /// 다음 두 가지 params 형태를 모두 지원합니다.
    ///   - `{ "level": "info", "message": "..." }`
    ///   - `"plain string message"`
    static func write(params: JSONValue?) {
        var level = "info"
        var message = ""
        if case .object(let o)? = params {
            if case .string(let s)? = o["level"] { level = s }
            if case .string(let s)? = o["message"] { message = s }
        } else if case .string(let s)? = params {
            message = s
        }
        FileHandle.standardError.write(
            Data("[plugin:\(level)] \(message)\n".utf8)
        )
    }
}

// MARK: - host/getSwitchState

/// `Agent/HookClient.swift`와 동일한 `/tmp/ahakey.sock` 프로토콜을 사용합니다
/// (`{"cmd":"permission","value":1}` → `{"switchState": Int, ...}`).
/// agent가 실행 중이 아니거나 BLE가 연결되지 않았으면 nil을 반환합니다.
///
/// 소켓 프로토콜을 공용 유틸리티로 분리하지 않은 이유는 Agent 타깃과 AhaKeyPluginKit이 아직 서로 의존하지 않기 때문입니다.
/// 앞으로 여러 곳에서 필요해지면 `AhaKeyAgentBridge` 라이브러리로 분리하면 됩니다.
enum HostAgentBridge {
    static let socketPath = "/tmp/ahakey.sock"
    static let timeout: Double = 2.0

    static func readSwitchState() -> Int? {
        let req: [String: Any] = ["cmd": "permission", "value": 1]
        guard let reply = sendJson(req) else { return nil }
        if let i = reply["switchState"] as? Int { return i }
        if let n = reply["switchState"] as? NSNumber { return n.intValue }
        return nil
    }

    private static func sendJson(_ dict: [String: Any]) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: __darwin_time_t(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let dst = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                _ = strcpy(dst, src)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard connected == 0 else { return nil }

        guard var payload = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        payload.append(0x0A)
        let wrote = payload.withUnsafeBytes { p -> Int in
            guard let base = p.baseAddress else { return -1 }
            return write(fd, base, p.count)
        }
        guard wrote >= 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(buf[0 ..< Int(n)]))) as? [String: Any]
    }
}
