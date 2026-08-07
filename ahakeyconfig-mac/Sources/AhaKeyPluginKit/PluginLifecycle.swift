import Foundation

// 플러그인 생명주기 핸드셰이크입니다. LSP의 initialize/initialized/shutdown 흐름을 참고했습니다.
//
// 순서:
//   1. 호스트가 자식 프로세스를 spawn → `client.start()`
//   2. 호스트 → 플러그인:  call  `plugin/initialize`  (params: { host, hostMethods })
//   3. 플러그인 → 호스트:  result `{ name, version, methods }`(자신이 처리할 수 있는 method를 선언)
//   4. 호스트 → 플러그인:  notify `plugin/initialized`(선택 사항. 작업을 시작해도 된다고 알림)
//   5. ... 일반 RPC ...
//   6. 호스트 → 플러그인:  call  `plugin/shutdown`(플러그인이 정리를 마칠 때까지 대기)
//   7. 호스트 → 플러그인:  notify `plugin/exit`
//   8. 호스트가 stdin을 닫음 → 자식 프로세스 종료

public struct PluginInitializeParams: Codable, Sendable {
    public let host: HostAppInfo
    public let hostMethods: [String]

    public init(host: HostAppInfo, hostMethods: [String]) {
        self.host = host
        self.hostMethods = hostMethods
    }
}

public struct PluginInitializeResult: Codable, Sendable {
    /// 플러그인이 스스로 밝힌 id / name / version이며, 로그 기록과 설정 패널 표시에만 사용합니다.
    /// 호스트가 신뢰하는 값은 매니페스트에 적힌 쪽입니다.
    public let name: String?
    public let version: String?

    /// 플러그인이 처리할 수 있다고 선언한 method 목록입니다. 호스트는 이를 근거로 엉뚱한 method 호출을 미리 거부할 수 있습니다.
    public let methods: [String]?

    public init(name: String? = nil, version: String? = nil, methods: [String]? = nil) {
        self.name = name
        self.version = version
        self.methods = methods
    }
}

public extension PluginClient {
    /// `plugin/initialize` 핸드셰이크를 수행합니다. 실패하면 오류를 그대로 전달합니다(시간 초과 → `PluginClientError.timeout`).
    @discardableResult
    func initialize(
        host: HostAppInfo,
        hostMethods: [String],
        timeout: TimeInterval = 5
    ) async throws -> PluginInitializeResult {
        let params = try JSONValue.encode(
            PluginInitializeParams(host: host, hostMethods: hostMethods)
        )
        let result = try await call("plugin/initialize", params: params, timeout: timeout)
        return try result.decode(PluginInitializeResult.self)
    }

    /// 플러그인에 「초기화가 끝났으니 작업을 시작해도 된다」고 알립니다. 실패는 무시됩니다(notification에는 응답이 없습니다).
    func sendInitialized() throws {
        try notify("plugin/initialized")
    }

    /// 플러그인에 정리 후 종료를 준비하도록 요청합니다. 실패나 시간 초과 시에도 오류를 던지지 않으므로, 호출한 쪽은 이어서 `stop()`을 호출하면 됩니다.
    func shutdown(timeout: TimeInterval = 3) async {
        _ = try? await call("plugin/shutdown", timeout: timeout)
        try? notify("plugin/exit")
    }
}
