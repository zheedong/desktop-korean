import CoreBluetooth
import Foundation
import os.log

private let log = Logger(subsystem: "lab.jawa.ahakeyconfig.agent", category: "BLE")

/// 기기의 8바이트 상태 파싱 결과.
///
/// Sources/BLE/AhaKeyProtocol.swift 의 `AhaKeyDeviceStatus` 와 동일한 구조를 유지한다.
/// 에이전트는 독립된 target 이라 소스 코드를 공유하지 않으므로, 여기에 최소한의 파서를 인라인으로 둔다.
struct AgentDeviceStatus {
    let battery: Int
    let signal: Int
    let firmwareMain: Int
    let firmwareSub: Int
    let workMode: Int
    let lightMode: Int
    let switchState: Int
}

/// 경량 BLE 데몬 프로세스: 연결 유지 + Unix socket 명령 수신 → LED 상태 전송 / 레버 상태 회신
final class AhaKeyAgent: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var lastUUID: UUID?
    private let serviceUUID = CBUUID(string: "7340")
    private let commandCharUUID = CBUUID(string: "7343")
    private let notifyCharUUID = CBUUID(string: "7344")
    private let deviceNamePrefix = "AhaKey"
    private let socketPath: String

    private let header: [UInt8] = [0xAA, 0xBB]
    private let trailer: [UInt8] = [0xCC, 0xDD]

    // MARK: 캐시(훅 조회용)
    /// 최신 switchState(0=auto, 1=manual). 알 수 없으면 nil
    private(set) var cachedSwitchState: UInt8?
    /// 최신 lightMode
    private(set) var cachedLightMode: UInt8?
    /// 사용자가 캔버스에서 가상 레버를 클릭해 설정한 재정의 값. nil 이 아니면 훅의 자동 승인 판단에서 cachedSwitchState 보다 우선한다.
    /// 에이전트를 재시작해도 유지되도록 UserDefaults 에 저장한다. 물리 레버가 고장 난 사용자는 이 값으로 훅 자동 승인을 동작시킨다.
    private(set) var userSwitchOverride: UInt8?

    private static let switchOverrideDefaultsKey = "lab.jawa.ahakeyconfig.agent.userSwitchOverride"

    /// 다음 status 응답을 기다리는 콜백 큐(querySwitchState 에서 사용)
    private var statusWaiters: [(AgentDeviceStatus?) -> Void] = []
    /// 도구 완료 / 사용자 제출처럼 짧게 지나가는 상태의 자동 복귀 처리.
    private var pendingStateReset: DispatchWorkItem?

    // MARK: 워치독(Claude Code 에서 작업을 수동으로 중단하면 Stop 훅이 발생하지 않으므로, 타임아웃 후 자동으로 원위치시킨다)
    /// 훅이 상태 명령을 보낸 가장 최근 시각(nil = 아직 받지 못함)
    private var lastHookStateAt: Date?
    /// 우리가 키보드로 마지막에 직접 보낸 LED 상태
    private var lastSentState: UInt8 = 0
    private var watchdogTimer: DispatchSourceTimer?

    /// 각 활성 상태의 타임아웃(초):
    ///   1=PermissionRequest / 7=UserPromptSubmit → 30초(대기 단계여서 수동 중단 후에는 뒤따르는 훅이 없다)
    ///   그 외 도구 실행 상태 → 60초(도구가 오래 걸릴 수 있어 잘못된 발동을 피한다)
    private func watchdogTimeout(for state: UInt8) -> Double {
        switch state {
        case 1, 7: return 30   // PermissionRequest / UserPromptSubmit: 짧은 타임아웃
        default:   return 60   // PreToolUse / PostToolUse / SessionStart / TaskCompleted
        }
    }

    var onLog: ((String) -> Void)?

    init(socketPath: String = "/tmp/ahakey.sock") {
        self.socketPath = socketPath
        if let raw = UserDefaults.standard.object(forKey: Self.switchOverrideDefaultsKey) as? Int {
            userSwitchOverride = UInt8(clamping: raw)
        }
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        // 시작 시점에 저장된 재정의 값이 있으면 즉시 공유 파일에 기록해, 메인 App UI 가 처음부터 볼 수 있게 한다
        Self.writeLiveState(switchState: userSwitchOverride)
    }

    /// 훅이 실제로 사용하는 레버 값: 사용자 재정의가 우선이고, 없으면 BLE 캐시로 되돌아간다
    var effectiveSwitchState: UInt8? {
        userSwitchOverride ?? cachedSwitchState
    }

    func setSwitchOverride(_ value: UInt8?) {
        userSwitchOverride = value
        if let v = value {
            UserDefaults.standard.set(Int(v), forKey: Self.switchOverrideDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.switchOverrideDefaultsKey)
        }
        // 최신 펌웨어에서 0x91 은 조명 효과 미리보기에 쓰인다. 레버는 훅의 소프트웨어 재정의만 유지하고, 더 이상 예전 0x91 을 키보드로 보내지 않는다.
        if let v = value {
            emit("레버 \(v) 는 소프트웨어 재정의로만 기록합니다. 예전 0x91 은 보내지 않습니다.")
        }
        // 재정의 값을 공유 파일에 기록해, 메인 App 이 캔버스의 레버 위치 변경을 곧바로 반영하도록 한다
        Self.writeLiveState(switchState: effectiveSwitchState)
        emit("레버 재정의 = \(value.map { String($0) } ?? "해제")(effective=\(effectiveSwitchState.map { String($0) } ?? "알 수 없음"))")
    }

    // MARK: - Public

    func sendState(_ state: UInt8) {
        pendingStateReset?.cancel()
        pendingStateReset = nil
        guard let commandChar, let peripheral else {
            emit("LED 상태 \(state): 연결되지 않음")
            return
        }
        let data = Data(header + [0x90, state] + trailer)
        let wt: CBCharacteristicWriteType =
            commandChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: commandChar, type: wt)
        lastSentState = state
        emit("→ LED 상태 \(state): \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
        Self.writeLiveState(stateValue: state)
    }

    /// 에이전트가 현재 파악한 키보드 상태(훅이 마지막으로 보낸 stateValue + BLE 가 보고한 lightMode/switchState/workMode)를
    /// 공유 파일에 merge-write 해서, 에이전트가 BLE 를 점유한 동안에도 메인 App 이 실시간 상태를 읽을 수 있게 한다.
    /// 호출하는 쪽은 자신이 갱신할 필드만 넘긴다. 넘기지 않은 필드는 파일에 있던 기존 값을 유지한다.
    static func writeLiveState(stateValue: UInt8? = nil,
                               lightMode: UInt8? = nil,
                               switchState: UInt8? = nil,
                               workMode: UInt8? = nil) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AhaKeyConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("current-ide-state.json")
        var obj: [String: Any] = [:]
        if let existing = try? Data(contentsOf: url),
           let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] {
            obj = parsed
        }
        let now = Date().timeIntervalSince1970
        if let s = stateValue {
            obj["stateValue"] = Int(s)
            obj["stateTs"] = now
        }
        if let lm = lightMode {
            obj["lightMode"] = Int(lm)
            obj["lightModeTs"] = now
        }
        if let sw = switchState {
            obj["switchState"] = Int(sw)
        }
        if let wm = workMode {
            obj["workMode"] = Int(wm)
        }
        obj["ts"] = now
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 기기 상태를 한 번 직접 조회하고, 다음 notify 응답을 (timeout 초 안에) 기다린다.
    /// 타임아웃이 나면 캐시로 대체하고, 그것도 없으면 nil 을 반환한다. 완료 콜백은 main 큐에서 호출된다.
    func querySwitchState(timeout: TimeInterval = 1.5,
                          completion: @escaping (AgentDeviceStatus?) -> Void) {
        guard let commandChar, let peripheral else {
            completion(nil)
            return
        }
        // 기기 상태 조회 명령 AA BB 00 CC DD 전송
        let query = Data(header + [0x00] + trailer)
        let wt: CBCharacteristicWriteType =
            commandChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(query, for: commandChar, type: wt)

        statusWaiters.append(completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            // 큐에 아직 남아 있는 waiter 를 모두 캐시 값으로 대체해 처리한다
            guard !self.statusWaiters.isEmpty else { return }
            let waiters = self.statusWaiters
            self.statusWaiters.removeAll()
            let fallback = self.cachedStatus()
            for w in waiters { w(fallback) }
        }
    }

    private func cachedStatus() -> AgentDeviceStatus? {
        guard let sw = cachedSwitchState else { return nil }
        return AgentDeviceStatus(
            battery: -1, signal: -1, firmwareMain: -1, firmwareSub: -1,
            workMode: -1, lightMode: Int(cachedLightMode ?? 0), switchState: Int(sw)
        )
    }

    @discardableResult
    func startSocketListener() -> Bool {
        if Self.hasLiveSocket(at: socketPath) {
            emit("이미 다른 에이전트가 Unix socket 을 수신 중입니다: \(socketPath)")
            return false
        }

        startWatchdog()
        // 수신 프로세스가 없는 잔여 socket 정리
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { emit("socket() 실패"); return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let buf = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                strcpy(buf, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { emit("bind() 실패: \(errno)"); close(fd); return false }

        listen(fd, 5)
        emit("Unix socket 수신 시작: \(socketPath)")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let clientFd = accept(fd, nil, nil)
                guard clientFd >= 0 else { continue }
                self?.handleClient(clientFd)
            }
        }
        return true
    }

    // MARK: - 워치독

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.checkWatchdog()
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func checkWatchdog() {
        guard let lastAt = lastHookStateAt else { return }
        let activeStates: [UInt8] = [1, 2, 3, 4, 6, 7]
        guard activeStates.contains(lastSentState) else { return }
        let elapsed = Date().timeIntervalSince(lastAt)
        let threshold = watchdogTimeout(for: lastSentState)
        guard elapsed >= threshold else { return }
        emit("⏰ 워치독: \(Int(elapsed))초 동안 훅 활동 없음(직전 LED=\(lastSentState), 임계값 \(Int(threshold))초). Stop(5) 을 자동 전송합니다")
        sendState(5)
        lastHookStateAt = nil  // 중복 발동을 막기 위해 초기화
    }

    // MARK: - Socket handling

    private static func hasLiveSocket(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let buf = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                strcpy(buf, ptr)
            }
        }

        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    /// 개별 클라이언트 처리: 요청 한 덩어리를 읽어 JSON 또는 예전의 숫자 전용 형식으로 분기한다.
    ///
    /// 프로토콜:
    /// - JSON 한 줄: `{"cmd":"state","value":3}` / `{"cmd":"permission","value":1}` / `{"cmd":"status"}`
    /// - 숫자만(예전 `ahakey-state.sh` 호환): `3` → sendState(3), 응답 없음
    private func handleClient(_ clientFd: Int32) {
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = read(clientFd, &buf, buf.count)
        guard n > 0 else { close(clientFd); return }

        let line = String(bytes: buf[0 ..< Int(n)], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // JSON 요청
        if let lineData = line.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
           let cmd = obj["cmd"] as? String {
            DispatchQueue.main.async { [weak self] in
                self?.handleJsonCommand(cmd: cmd, obj: obj, clientFd: clientFd)
            }
            return // fd 는 명령 handler 안에서 최종적으로 닫는다
        }

        // 예전 프로토콜: 숫자만 오면 state 로 간주하고 fire-and-forget 처리
        if let state = UInt8(line) {
            DispatchQueue.main.async { [weak self] in self?.sendState(state) }
        }
        close(clientFd)
    }

    /// main 큐에서 실행되는 JSON 명령 분기. 응답은 `replyAndClose` 가 비동기로 기록하고 fd 를 닫는다.
    private func handleJsonCommand(cmd: String, obj: [String: Any], clientFd: Int32) {
        switch cmd {
        case "state":
            if let v = obj["value"] as? Int {
                lastHookStateAt = Date()
                sendState(UInt8(clamping: v))
            }
            Self.replyAndClose(clientFd, ["ok": true])

        case "state_with_reset":
            let stateValue = obj["value"] as? Int ?? 0
            let resetValue = obj["resetValue"] as? Int ?? 4
            let delayMs = max(0, obj["delayMs"] as? Int ?? 1200)
            sendState(UInt8(clamping: stateValue))
            scheduleStateReset(
                to: UInt8(clamping: resetValue),
                afterMs: delayMs,
                reason: "temporary state \(stateValue) -> reset \(resetValue)"
            )
            Self.replyAndClose(clientFd, ["ok": true])

        case "permission":
            // PermissionRequest 에 해당하는 state(기본값 1)를 보내면서, 레버 상태도 함께 조회한다
            let stateValue = obj["value"] as? Int ?? 1
            lastHookStateAt = Date()
            sendState(UInt8(clamping: stateValue))
            querySwitchState(timeout: 1.5) { status in
                let body = Self.statusReply(status, cachedSwitch: self.effectiveSwitchState, cachedLight: self.cachedLightMode)
                self.emit("← permission 응답 switchState=\(String(describing: body["switchState"]))")
                if let s = body["switchState"] as? Int, s != 0 {
                    self.emit("(레버가 0 이 아님: PermissionRequest 는 터미널의 수동 확인으로 넘깁니다)")
                } else if body["switchState"] is NSNull {
                    self.emit("(switchState 없음: 승인 흐름이 여전히 수동으로 넘어갈 수 있습니다. 「블루투스」를 에이전트에 넘기고 키보드를 연결해 주세요.)")
                }
                Self.replyAndClose(clientFd, body)
            }

        case "status":
            // BLE 가 실제로 키보드에 연결되었는지 판단한다: cachedSwitchState 가 nil 이 아닐 때만(키보드가 notify 로 보고한 적이 있을 때만) 연결로 본다.
            // effectiveSwitchState 는 사용자가 userSwitchOverride 를 설정하면 BLE 가 연결되지 않아도 값이 있으므로, 키보드 연결 여부의 근거로 쓸 수 없다.
            if cachedSwitchState != nil {
                Self.replyAndClose(clientFd, [
                    "switchState": effectiveSwitchState.map { Int($0) } ?? NSNull(),
                    "lightMode": cachedLightMode.map { Int($0) } ?? NSNull(),
                ])
            } else {
                querySwitchState(timeout: 1.5) { status in
                    Self.replyAndClose(clientFd, Self.statusReply(status, cachedSwitch: self.effectiveSwitchState, cachedLight: self.cachedLightMode))
                }
            }

        case "approval_status":
            // Kimi CLI 의 실시간 승인 판단용: 매번 기기에 현재 레버 값을 직접 요청해, 세션 안에서 예전 yolo/state 를 그대로 쓰는 것을 막는다.
            querySwitchState(timeout: 1.5) { status in
                Self.replyAndClose(clientFd, Self.statusReply(status, cachedSwitch: self.effectiveSwitchState, cachedLight: self.cachedLightMode))
            }

        case "set_switch_override":
            // 메인 App 캔버스의 가상 레버 클릭 → 재정의 설정 / 해제
            // value=null / 없음 → 해제(실제 BLE 보고값 사용으로 복귀)
            // value=0/1/2 → 재정의 값 설정. 예전 0x91 은 더 이상 보내지 않는다
            if obj["value"] is NSNull || obj["value"] == nil {
                setSwitchOverride(nil)
            } else if let v = obj["value"] as? Int {
                setSwitchOverride(UInt8(clamping: v))
            }
            Self.replyAndClose(clientFd, [
                "ok": true,
                "switchState": effectiveSwitchState.map { Int($0) } ?? NSNull(),
                "override": userSwitchOverride.map { Int($0) } ?? NSNull(),
            ])

        default:
            Self.replyAndClose(clientFd, ["error": "unknown cmd: \(cmd)"])
        }
    }

    private static func statusReply(_ status: AgentDeviceStatus?,
                                    cachedSwitch: UInt8?,
                                    cachedLight: UInt8?) -> [String: Any] {
        if let s = status {
            return ["switchState": s.switchState, "lightMode": s.lightMode]
        }
        return [
            "switchState": cachedSwitch.map { Int($0) } ?? NSNull(),
            "lightMode": cachedLight.map { Int($0) } ?? NSNull(),
        ]
    }

    private func scheduleStateReset(to state: UInt8, afterMs: Int, reason: String) {
        pendingStateReset?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sendState(state)
            self.emit("조명 상태 자동 복귀: \(reason)")
        }
        pendingStateReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(afterMs), execute: work)
    }

    private static func replyAndClose(_ fd: Int32, _ dict: [String: Any]) {
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: []) {
                var out = data
                out.append(0x0A) // \n 을 메시지 경계로 사용
                _ = out.withUnsafeBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return write(fd, base, ptr.count)
                }
            }
            close(fd)
        }
    }

    // MARK: - Connection

    private func connectAutomatically() {
        // 1. 이미 알고 있는 UUID 사용
        if let uuid = lastUUID {
            let known = central.retrievePeripherals(withIdentifiers: [uuid])
            if let p = known.first {
                emit("알려진 기기에 직접 연결: \(uuid.uuidString.prefix(8))…")
                peripheral = p
                p.delegate = self
                central.connect(p, options: nil)
                return
            }
        }

        // 2. 시스템에 이미 연결된 기기
        let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        if let p = connected.first(where: { ($0.name ?? "").lowercased().hasPrefix(deviceNamePrefix.lowercased()) }) {
            emit("시스템에 이미 연결됨: \(p.name ?? "?")")
            peripheral = p
            p.delegate = self
            central.connect(p, options: nil)
            return
        }

        // 3. 스캔
        emit("스캔 시작…")
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    private func emit(_ msg: String) {
        log.info("\(msg)")
        onLog?(msg)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            emit("블루투스 준비 완료")
            connectAutomatically()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.lowercased().hasPrefix(deviceNamePrefix.lowercased()) else { return }
        central.stopScan()
        emit("발견: \(name)")
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        lastUUID = peripheral.identifier
        emit("연결됨: \(peripheral.name ?? "?")")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        commandChar = nil
        notifyChar = nil
        self.peripheral = nil
        cachedSwitchState = nil
        cachedLightMode = nil
        // 대기 중인 waiter 를 모두 nil 로 통지한다(훅 클라이언트가 계속 기다리지 않도록)
        if !statusWaiters.isEmpty {
            let waiters = statusWaiters
            statusWaiters.removeAll()
            for w in waiters { w(nil) }
        }
        emit("연결이 끊겼습니다. 2초 후 재연결합니다")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.connectAutomatically()
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else { return }
        peripheral.discoverCharacteristics([commandCharUUID, notifyCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            if char.uuid == commandCharUUID {
                commandChar = char
                emit("명령 채널 준비 완료")
            } else if char.uuid == notifyCharUUID {
                notifyChar = char
                peripheral.setNotifyValue(true, for: char)
                emit("알림 채널 구독 완료")
            }
        }
        // 두 characteristic 이 모두 준비되면 초기 상태 조회를 한 번 보낸다
        if commandChar != nil, notifyChar != nil {
            let query = Data(header + [0x00] + trailer)
            let wt: CBCharacteristicWriteType =
                commandChar!.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            peripheral.writeValue(query, for: commandChar!, type: wt)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == commandCharUUID || characteristic.uuid == notifyCharUUID,
              let data = characteristic.value else { return }
        guard let status = Self.parseDeviceStatus(data) else { return }

        cachedSwitchState = UInt8(clamping: status.switchState)
        cachedLightMode = UInt8(clamping: status.lightMode)
        emit("← status battery=\(status.battery) light=\(status.lightMode) switch=\(status.switchState)")
        // 공유 파일에 기록할 때는 사용자 재정의 값을 우선 사용하고, 없으면 키보드의 실제 보고값을 쓴다. 이렇게 하면 메인 App 캔버스의
        // 레버 위치가 훅이 실제로 사용하는 승인 로직과 항상 일치한다(캔버스는 한 단계를 표시하고 훅은 다른 단계로 동작하는 어긋남을 막는다).
        Self.writeLiveState(
            lightMode: UInt8(clamping: status.lightMode),
            switchState: effectiveSwitchState,
            workMode: UInt8(clamping: max(0, status.workMode))
        )

        guard !statusWaiters.isEmpty else { return }
        let waiters = statusWaiters
        statusWaiters.removeAll()
        for w in waiters { w(status) }
    }

    // MARK: - 프로토콜 인라인 파싱

    /// AA BB 00 [battery][signal][fw_main][fw_sub][work][light][switch][reserve] CC DD 를 파싱한다
    /// Sources/BLE/AhaKeyProtocol.swift:parseDeviceStatus 와 동일한 동작
    private static func parseDeviceStatus(_ data: Data) -> AgentDeviceStatus? {
        guard data.count >= 12,
              data[0] == 0xAA, data[1] == 0xBB,
              data[data.count - 2] == 0xCC, data[data.count - 1] == 0xDD else {
            return nil
        }
        let payload = data[2 ..< data.count - 2]
        guard payload.count >= 8, payload[payload.startIndex] == 0x00 else { return nil }
        let base = payload.startIndex + 1 // cmd echo 를 건너뛴다
        return AgentDeviceStatus(
            battery: Int(payload[base]),
            signal: Int(Int8(bitPattern: payload[base + 1])),
            firmwareMain: Int(payload[base + 2]),
            firmwareSub: Int(payload[base + 3]),
            workMode: Int(payload[base + 4]),
            lightMode: Int(payload[base + 5]),
            switchState: Int(payload[base + 6])
        )
    }
}
