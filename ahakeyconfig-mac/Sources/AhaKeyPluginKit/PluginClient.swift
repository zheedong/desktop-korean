import Foundation

/// stdio 기반 JSON-RPC 2.0 클라이언트입니다.
///
/// - 자식 프로세스를 시작합니다(플러그인 host 측 = 우리 쪽, 자식 프로세스 = 플러그인 본체).
/// - 프레임 형식: **newline-delimited JSON**(메시지 한 건마다 UTF-8 한 줄 + `\n`).
///   stdio 통신에서 가장 흔히 쓰이는 방식입니다. 나중에 LSP의 `Content-Length` 헤더 방식으로
///   바꾸려면 `sendFramed(_:)`와 reader의 프레임 분리 로직만 교체하면 됩니다.
/// - 자식 프로세스의 `stderr`는 상위 계층으로 그대로 전달합니다(기본은 현재 프로세스의 stderr이며 `onStderr`로 바꿀 수 있습니다).
///
/// 사용법:
/// ```swift
/// let client = PluginClient(
///     executable: URL(fileURLWithPath: "/usr/bin/env"),
///     arguments: ["node", "my-plugin.js"]
/// )
/// try client.start()
/// let result = try await client.call("add", params: .array([.int(1), .int(2)]))
/// // result == .int(3)
/// client.stop()
/// ```
public actor PluginClient {
    // MARK: - 설정

    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]?
    private let workingDirectory: URL?

    /// `call` 한 건이 응답을 기다리는 기본 시간 초과입니다. `notify`는 영향을 받지 않습니다.
    public var defaultCallTimeout: TimeInterval = 30

    /// 자식 프로세스 stderr 콜백이며, nil이면 현재 프로세스의 stderr로 그대로 전달합니다.
    public var onStderr: (@Sendable (String) -> Void)?

    // MARK: - 프로세스 / 파이프

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var started = false

    // MARK: - 프로토콜 상태

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]

    /// 서버 → 클라이언트 방향 notification 핸들러입니다(method → 처리 클로저).
    public typealias NotificationHandler = @Sendable (JSONValue?) -> Void
    private var notificationHandlers: [String: NotificationHandler] = [:]

    /// 서버 → 클라이언트 방향 request 핸들러입니다(method → result 반환 또는 JSONRPCError 던짐).
    /// JSON-RPC는 대등한 양방향 프로토콜이므로 자식 프로세스도 우리를 역방향으로 호출할 수 있습니다.
    public typealias RequestHandler = @Sendable (JSONValue?) async throws -> JSONValue
    private var requestHandlers: [String: RequestHandler] = [:]

    // MARK: - 초기화

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    // MARK: - 시작 / 정지

    public func start() throws {
        guard !started else { return }
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 자식 프로세스가 종료되면 대기 중인 모든 pending을 깨웁니다.
        process.terminationHandler = { [weak self] proc in
            Task { await self?.handleProcessTermination(status: proc.terminationStatus) }
        }

        try process.run()
        started = true
        startReader()
        startStderrReader()
    }

    /// 정상 종료: stdin을 닫고 자식 프로세스가 스스로 끝나기를 기다립니다. 강제로 끝내려면 `terminate()`를 사용하세요.
    public func stop() {
        guard started else { return }
        try? stdinPipe.fileHandleForWriting.close()
    }

    public func terminate() {
        guard started else { return }
        process.terminate()
    }

    // MARK: - 콜백 등록

    public func setNotificationHandler(_ method: String, _ handler: @escaping NotificationHandler) {
        notificationHandlers[method] = handler
    }

    public func setRequestHandler(_ method: String, _ handler: @escaping RequestHandler) {
        requestHandlers[method] = handler
    }

    // MARK: - 전송: call / notify

    /// JSON-RPC 호출을 보내고 응답을 기다립니다.
    @discardableResult
    public func call(
        _ method: String,
        params: JSONValue? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> JSONValue {
        guard started, process.isRunning else { throw PluginClientError.notRunning }

        let id = nextID
        nextID += 1
        let request = JSONRPCRequest(method: method, params: params, id: .int(id))

        // 응답이 등록보다 먼저 도착하지 않도록 continuation을 먼저 등록한 뒤 데이터를 보냅니다.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
                pending[id] = cont
                do {
                    try sendFramed(request)
                } catch {
                    pending.removeValue(forKey: id)
                    cont.resume(throwing: error)
                    return
                }
                armTimeout(id: id, after: timeout ?? defaultCallTimeout)
            }
        } onCancel: {
            Task { await self.failPending(id: id, with: CancellationError()) }
        }
    }

    /// Notification을 전송합니다(id가 없고 응답을 기다리지 않습니다).
    public func notify(_ method: String, params: JSONValue? = nil) throws {
        guard started, process.isRunning else { throw PluginClientError.notRunning }
        let request = JSONRPCRequest(method: method, params: params, id: nil)
        try sendFramed(request)
    }

    // MARK: - 프레임 인코딩

    private func sendFramed(_ request: JSONRPCRequest) throws {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A) // '\n'
        if ProcessInfo.processInfo.environment["AHAKEY_PLUGIN_DEBUG"] != nil,
           let s = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data("[client→plugin] \(s)".utf8))
        }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    // MARK: - Reader（stdout）

    // 기존의 `handle.bytes.lines` 방식은 daemon 스레드가 stdout에 쓰는 상황에서 몇 초씩 늦게 트리거되었습니다.
    // 그래서 `readabilityHandler`로 바꿔 dispatch IO를 사용하며, 이벤트 기반으로 즉시 처리됩니다.
    private var stdoutBuffer = Data()

    private func startReader() {
        let handle = stdoutPipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty {
                // EOF — 자식 프로세스가 stdout을 닫았습니다.
                h.readabilityHandler = nil
                Task { await self.handleProcessTermination(status: nil) }
                return
            }
            Task { await self.appendStdout(data) }
        }
    }

    private func appendStdout(_ data: Data) async {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex ..< nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex ... nl)
            if let line = String(data: lineData, encoding: .utf8) {
                await handleIncoming(line: line)
            }
        }
    }

    private func startStderrReader() {
        let handle = stderrPipe.fileHandleForReading
        let onStderr = self.onStderr
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            if let onStderr, let s = String(data: data, encoding: .utf8) {
                // 줄 단위로 콜백을 호출하며, 끝에 남은 불완전한 줄은 그대로 둡니다(드문 경우).
                for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                    if !line.isEmpty { onStderr(String(line)) }
                }
            } else {
                FileHandle.standardError.write(data)
            }
        }
    }

    // MARK: - 수신 메시지 분배

    private func handleIncoming(line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        if ProcessInfo.processInfo.environment["AHAKEY_PLUGIN_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[client←plugin] \(trimmed)\n".utf8))
        }

        // 메시지 한 건은 Response(id + result/error 포함), Request(id + method 포함),
        // Notification(method는 있지만 id는 없음) 중 하나입니다. 먼저 `method` 필드가 있는지 확인합니다.
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           raw["method"] is String {
            await dispatchInbound(data: data, raw: raw)
            return
        }

        // Response로 간주하고 디코딩합니다.
        do {
            let resp = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
            dispatch(response: resp)
        } catch {
            // 끝까지 해석할 수 없으면 원인 파악을 위해 stderr로 내보냅니다.
            FileHandle.standardError.write(
                Data("[PluginClient] unrecognized frame: \(trimmed)\n".utf8)
            )
        }
    }

    private func dispatch(response: JSONRPCResponse) {
        guard case .int(let i)? = response.id else {
            // 우리가 보내는 id는 모두 int이므로 다른 형태의 id는 그대로 버립니다.
            return
        }
        guard let cont = pending.removeValue(forKey: i) else { return }
        if let err = response.error {
            cont.resume(throwing: err)
        } else {
            cont.resume(returning: response.result ?? .null)
        }
    }

    private func dispatchInbound(data: Data, raw: [String: Any]) async {
        guard let method = raw["method"] as? String else { return }
        let params: JSONValue? = {
            guard raw["params"] != nil else { return nil }
            // params 필드를 JSONValue로 다시 디코딩합니다.
            struct Wrapper: Decodable { let params: JSONValue? }
            return (try? JSONDecoder().decode(Wrapper.self, from: data))?.params
        }()

        if raw["id"] == nil {
            // Notification
            notificationHandlers[method]?(params)
            return
        }

        // 수신 Request이므로 Response를 돌려주어야 합니다.
        let id: JSONRPCID
        do {
            struct Wrapper: Decodable { let id: JSONRPCID }
            id = try JSONDecoder().decode(Wrapper.self, from: data).id
        } catch {
            return
        }

        if let handler = requestHandlers[method] {
            do {
                let result = try await handler(params)
                try sendResult(id: id, result: result)
            } catch let err as JSONRPCError {
                try? sendError(id: id, error: err)
            } catch {
                try? sendError(id: id, error: JSONRPCError(
                    code: JSONRPCError.internalError,
                    message: "\(error)",
                    data: nil
                ))
            }
        } else {
            try? sendError(id: id, error: JSONRPCError(
                code: JSONRPCError.methodNotFound,
                message: "Method not found: \(method)",
                data: nil
            ))
        }
    }

    private struct OutboundResponse: Encodable {
        let jsonrpc: String = JSONRPC.version
        let id: JSONRPCID
        let result: JSONValue?
        let error: JSONRPCError?
    }

    private func sendResult(id: JSONRPCID, result: JSONValue) throws {
        let resp = OutboundResponse(id: id, result: result, error: nil)
        var data = try JSONEncoder().encode(resp)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func sendError(id: JSONRPCID, error: JSONRPCError) throws {
        let resp = OutboundResponse(id: id, result: nil, error: error)
        var data = try JSONEncoder().encode(resp)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    // MARK: - 시간 초과 / 취소 / 프로세스 종료

    private func armTimeout(id: Int, after seconds: TimeInterval) {
        guard seconds > 0 else { return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            failPending(id: id, with: PluginClientError.timeout)
        }
    }

    private func failPending(id: Int, with error: Error) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(throwing: error)
    }

    private func handleProcessTermination(status: Int32?) {
        guard started else { return }
        started = false
        let err: Error = status.map { PluginClientError.processTerminated($0) }
            ?? PluginClientError.notRunning
        let pendingSnapshot = pending
        pending.removeAll()
        for (_, cont) in pendingSnapshot {
            cont.resume(throwing: err)
        }
    }
}

