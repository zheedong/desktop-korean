import Foundation

enum HookSupport {
    static let permissionLedValue: UInt8 = 1
    static let socketPath = "/tmp/ahakey.sock"
    static let stateRequestTimeout: Double = 2.0
    static let permissionRequestTimeout: Double = 5.0

    static let diagnosticTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func handleFireAndForgetState(stateValue: UInt8) {
        _ = sendUnifiedLightState(stateValue: stateValue)
    }

    @discardableResult
    static func sendUnifiedLightState(stateValue: UInt8) -> [String: Any]? {
        let request: [String: Any] = ["cmd": "state", "value": Int(stateValue)]
        return sendJsonRequest(request, timeout: stateRequestTimeout)
    }

    @discardableResult
    static func readAllStdinSilently() -> Data {
        let handle = FileHandle.standardInput
        return (try? handle.readToEnd()) ?? Data()
    }

    static func sendJsonRequest(_ dict: [String: Any], timeout: Double) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(
            tv_sec: __darwin_time_t(timeout),
            tv_usec: suseconds_t((timeout - Double(Int(timeout))) * 1_000_000)
        )
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
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, addrLen)
            }
        }
        guard connected == 0 else { return nil }

        guard var payload = try? JSONSerialization.data(withJSONObject: dict, options: []) else {
            return nil
        }
        payload.append(0x0A)
        let wrote = payload.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return write(fd, base, ptr.count)
        }
        guard wrote >= 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: 1024 * 4)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        let slice = Data(buf[0 ..< Int(n)])
        return (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any]
    }

    static func intValue(_ v: Any?) -> Int? {
        switch v {
        case let i as Int:
            return i
        case let n as NSNumber:
            return n.intValue
        case let d as Double:
            return Int(d)
        case let s as String:
            return Int(s)
        default:
            return nil
        }
    }

    /// 공유 상태 파일(`current-ide-state.json`)에 기록된 레버 값. 지정한 시간 안에 갱신된 값만 유효로 본다.
    ///
    /// BLE 는 이 App 과 데몬 중 하나만 점유할 수 있고, 점유한 쪽이 이 파일을 갱신한다. 데몬이 점유하지 못한
    /// 상태에서는 데몬이 기동 시점에 들고 있던 값을 계속 응답하므로, 파일 쪽이 최신이면 그것을 신뢰해야 한다.
    static func liveStateSwitchState(maxAge: TimeInterval = 120) -> Int? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AhaKeyConfig/current-ide-state.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sw = intValue(obj["switchState"])
        else { return nil }
        // ts 가 없거나 오래된 값이면 키보드와 끊긴 뒤 남은 찌꺼기일 수 있으므로 쓰지 않는다.
        guard let ts = obj["ts"] as? Double,
              Date().timeIntervalSince1970 - ts <= maxAge
        else { return nil }
        return sw
    }

    /// 훅이 자동 승인 판단에 쓸 레버 값. 공유 상태 파일이 최신이면 그것을, 아니면 데몬 응답을 쓴다.
    /// 둘 다 없으면 nil 을 돌려 호출부가 수동(ask)으로 넘기게 한다.
    static func resolvedSwitchState(reply: [String: Any]?) -> Int? {
        liveStateSwitchState() ?? intValue(reply?["switchState"])
    }

    static func emitPermissionStderr(
        ide: String,
        hookName: String,
        reply: [String: Any]?,
        switchState: Int?
    ) {
        if switchState == nil, reply == nil {
            let msg = "[ahakey-hook] \(ide) \(hookName): 에이전트 응답이 없거나 Unix socket 연결에 실패했습니다(/tmp/ahakey.sock 연결 불가 또는 타임아웃, 제한 시간 \(Int(permissionRequestTimeout))초)."
                + "LaunchAgent 에서 ahakeyconfig-agent 가 실행 중이고, 블루투스가 「에이전트가 점유」로 설정되어 키보드에 연결되어 있는지 확인해 주세요.\n"
            FileHandle.standardError.write(Data(msg.utf8))
        } else if switchState == nil, reply != nil {
            let msg = "[ahakey-hook] \(ide) \(hookName): 응답에 유효한 switchState 가 없습니다(BLE 가 연결되어 레버 값을 읽을 수 있어야 하며 0=자동 승인). 사용자/터미널로 넘겨 처리합니다.\n"
            FileHandle.standardError.write(Data(msg.utf8))
        } else if let s = switchState, s != 0 {
            let msg = "[ahakey-hook] \(ide) \(hookName): 레버 switchState=\(s)(0 이 아님)이므로 자동 승인하지 않습니다.\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
    }

    static func parseStdinContext(_ data: Data, label: String) -> [String: Any] {
        var out: [String: Any] = [
            "stdinBytes": data.count,
            "parser": label,
        ]
        guard !data.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return out
        }
        if let t = obj["tool_name"] as? String {
            out["tool_name"] = t
        }
        if let c = obj["command"] as? String {
            out["commandPreview"] = String(c.prefix(120))
        }
        if out["tool_name"] == nil, let t = obj["name"] as? String {
            out["name"] = t
        }
        if let he = obj["hook_event_name"] as? String {
            out["hook_event_name"] = he
        }
        if let sid = obj["session_id"] as? String {
            out["session_id_short"] = String(sid.prefix(16))
        }
        if let cw = obj["cwd"] as? String {
            out["cwdPreview"] = String(cw.prefix(120))
        }
        return out
    }

    static func appendDiagnostic(
        ide: String,
        hookEvent: String,
        toolContext: [String: Any],
        reply: [String: Any]?,
        switchState: Int?,
        isAuto: Bool,
        claudeBehavior: String?,
        cursorPermission: String?,
        cursorDebug: [String: Any]? = nil,
        kimiPreToolDecision: String? = nil,
        kimiLeverDebug: [String: Any]? = nil
    ) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AhaKeyConfig/diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let fileURL = dir.appendingPathComponent("permission-request.log")

        let diagnostic: String
        if reply == nil {
            diagnostic = "no_agent_reply"
        } else if switchState == nil {
            diagnostic = "no_switch_in_reply"
        } else if isAuto {
            diagnostic = "allow"
        } else {
            diagnostic = "ask"
        }

        var lineObj: [String: Any] = [
            "ts": diagnosticTimestampFormatter.string(from: Date()),
            "ide": ide,
            "hookEvent": hookEvent,
            "switchState": switchState.map { $0 } ?? NSNull(),
            "isAuto": isAuto,
            "agentReply": reply == nil ? false : true,
            "diagnostic": diagnostic,
            "tool": toolContext,
        ]
        if let b = claudeBehavior { lineObj["claudeBehavior"] = b }
        if let p = cursorPermission { lineObj["cursorPermission"] = p }
        if let c = cursorDebug { lineObj["cursorDebug"] = c }
        if let k = kimiPreToolDecision { lineObj["kimiPreToolDecision"] = k }
        if let kd = kimiLeverDebug { lineObj["kimiLeverDebug"] = kd }

        guard let data = try? JSONSerialization.data(withJSONObject: lineObj, options: []),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        appendLine(line, to: fileURL)
    }

    static func appendCodexHookLog(
        hookEvent: String?,
        agentEvent: String,
        stateValue: UInt8,
        toolContext: [String: Any],
        reply: [String: Any]?,
        switchState: Int?,
        decision: String?
    ) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AhaKeyConfig/diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let fileURL = dir.appendingPathComponent("codex-hook.log")

        var lineObj: [String: Any] = [
            "ts": diagnosticTimestampFormatter.string(from: Date()),
            "agentEvent": agentEvent,
            "hookEvent": hookEvent ?? NSNull(),
            "stateValue": Int(stateValue),
            "agentReply": reply == nil ? false : true,
            "switchState": switchState.map { $0 } ?? NSNull(),
            "tool": toolContext,
        ]
        if let decision { lineObj["decision"] = decision }

        guard let data = try? JSONSerialization.data(withJSONObject: lineObj, options: []),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        appendLine(line, to: fileURL)
    }

    static func appendLine(_ line: String, to fileURL: URL) {
        guard let out = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? out.write(to: fileURL, options: .atomic)
            return
        }
        if let h = try? FileHandle(forWritingTo: fileURL) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(out)
        }
    }

    static let cursorStdinLogKeys: [String] = [
        "cursorVersion", "cursor_version", "appVersion", "app_version", "version",
        "workspacePath", "workspace_path", "workspaceFolders", "workspace_folders", "workspaceRoot",
        "cwd", "root", "shell", "shell_type", "sessionId", "conversation_id",
    ]

    static func buildCursorHookDebug(stdinData: Data, commandPreview: String?) -> [String: Any] {
        var out: [String: Any] = [
            "userCliConfig": CursorCliLeverSync.diagnosticSnapshotForLog(),
            "userPermissionsJson": CursorPermissionsJsonLeverSync.diagnosticSnapshotForLog(),
            "note": "IDE 의 「Not in allowlist」는 ~/.cursor/permissions.json 의 terminalAllowlist 를 사용하며, userCliConfig(cli-config=CLI)와는 분리되어 있다. cursor.com/docs/reference/permissions 참고",
            "stdinFields": cursorStdinDebugFields(stdinData),
            "processEnvCursorVscode": cursorRelatedEnvForLog(),
        ]
        if let cd = inferredCdPathFromShellCommand(commandPreview) {
            out["inferredCdPath"] = cd
            let proj = (cd as NSString).appendingPathComponent(".cursor/cli.json")
            out["projectCliJsonPath"] = proj
            out["projectCliJsonExists"] = FileManager.default.fileExists(atPath: proj)
        }
        return out
    }

    static func cursorStdinDebugFields(_ data: Data) -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["parse": "empty_or_invalid_json"]
        }
        var o: [String: Any] = [:]
        for k in cursorStdinLogKeys {
            guard let v = obj[k] else { continue }
            o[k] = stringifyDebugValue(v, maxLen: 220)
        }
        if o.isEmpty { o["note"] = "no_whitelisted_keys_in_stdin" }
        return o
    }

    static func stringifyDebugValue(_ v: Any, maxLen: Int) -> String {
        if let s = v as? String { return String(s.prefix(maxLen)) }
        if let n = v as? NSNumber { return n.stringValue }
        if let a = v as? [String] {
            return String(a.prefix(12).joined(separator: ", ").prefix(maxLen))
        }
        return String(String(describing: v).prefix(maxLen))
    }

    static func cursorRelatedEnvForLog() -> [String: Any] {
        var o: [String: Any] = [:]
        for (k, v) in ProcessInfo.processInfo.environment.sorted(by: { $0.key < $1.key }) {
            let ku = k.uppercased()
            guard ku.contains("CURSOR") || ku.hasPrefix("VSCODE_") || ku == "TERM" else { continue }
            o[k] = String(v.prefix(200))
            if o.count >= 32 { break }
        }
        return o
    }

    static func inferredCdPathFromShellCommand(_ command: String?) -> String? {
        guard let raw = command?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("cd ") else { return nil }
        var rest = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        if let r = rest.range(of: " && ") { rest = String(rest[..<r.lowerBound]) }
        if let r = rest.firstIndex(of: ";") { rest = String(rest[..<r]) }
        if let r = rest.firstIndex(of: "|") { rest = String(rest[..<r]) }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\"") {
            let drop = rest.dropFirst()
            if let end = drop.firstIndex(of: "\"") {
                return String(drop[..<end])
            }
        }
        if let sp = rest.firstIndex(where: { $0.isWhitespace }) {
            return String(rest[..<sp])
        }
        return rest.isEmpty ? nil : rest
    }
}
