import AppKit
import Combine
import CoreBluetooth
import Foundation
import os.log
import UserNotifications

private let log = Logger(subsystem: "lab.jawa.ahakeyconfig", category: "BLE")

/// 0x83 조회로 받아온 특정 mode의 이미지 메타 정보(SwiftUI .onChange 감시가 쉽도록 Equatable struct 사용)
struct KeyboardPictureState: Equatable {
    let frameCount: Int
    let frameIntervalMs: Int
}

/// 통신 로그 항목
struct BLELogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let isError: Bool

    var formattedTime: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: timestamp)
    }
}

/// AhaKey-X1 BLE 통신 관리자
@MainActor
final class AhaKeyBLEManager: NSObject, ObservableObject {
    typealias CommandResponse = (status: UInt8, payload: Data)

    struct OLEDUploadProgress: Equatable {
        let completedChunks: Int
        let totalChunks: Int
        let completedFrames: Int
        let totalFrames: Int

        var fractionCompleted: Double {
            guard totalChunks > 0 else { return 0 }
            return Double(completedChunks) / Double(totalChunks)
        }
    }

    // MARK: - Published State

    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var deviceName: String?
    @Published private(set) var batteryLevel: Int = 0
    @Published private(set) var signalStrength: Int = 0
    @Published private(set) var firmwareMainVersion: Int = 0
    @Published private(set) var firmwareSubVersion: Int = 0
    @Published private(set) var firmwareRevision: String = "—"
    @Published private(set) var modelNumber: String = "—"
    @Published private(set) var workMode: Int = 0
    @Published private(set) var lightMode: Int = 0
    @Published private(set) var switchState: Int = 0
    @Published private(set) var brightness: Int = 35
    @Published private(set) var bleConnectionStatus: String = "연결되지 않음"
    @Published private(set) var bleDeviceUUID: String = "—"
    @Published private(set) var bluetoothPermissionGranted = true
    @Published private(set) var bluetoothPoweredOn = false
    @Published private(set) var oledUploadProgress: OLEDUploadProgress?
    @Published private(set) var isUploadingOLED = false
    /// ahakeyconfig-agent가 기록한 현재 IDE hook 상태 값(IDEState.rawValue). 캔버스 LED 색을 실시간으로 재현하는 데 쓴다
    @Published private(set) var liveIDEStateValue: Int? = nil
    /// Agent 쪽 BLE 알림에 캐시된 lightMode/switchState/workMode(agent가 블루투스를 점유하면 메인 App은 BLE에 직접 연결되지 않으므로, 이 값으로 키보드의 실시간 상태를 읽는다)
    @Published private(set) var agentLightMode: Int? = nil
    @Published private(set) var agentSwitchState: Int? = nil
    @Published private(set) var agentWorkMode: Int? = nil
    /// 각 mode의 flash에 저장된 실제 이미지 메타 정보.
    /// 메인 App이 BLE를 점유한 뒤 0x83 조회로 채운다. frameCount == 0이면 사용자가 직접 업로드하지 않았다는 뜻이며,
    /// 키보드는 펌웨어 기본 애니메이션을 표시한다(bundle/DefaultOLED와 같은 소스).
    @Published private(set) var keyboardPictureStates: [Int: KeyboardPictureState] = [:]

    /// 통신 로그(최근 200개)
    @Published private(set) var commLog: [BLELogEntry] = []
    private let maxLogEntries = 200

    // 특성 준비 상태
    @Published private(set) var dataCharReady = false
    @Published private(set) var commandCharReady = false
    @Published private(set) var notifyCharReady = false

    // MARK: - BLE Constants

    // AhaKey 메인 서비스
    static let serviceUUID = CBUUID(string: "7340")
    static let dataCharUUID = CBUUID(string: "7341")
    static let infoCharUUID = CBUUID(string: "7342")
    static let commandCharUUID = CBUUID(string: "7343")
    static let notifyCharUUID = CBUUID(string: "7344")

    // 표준 Battery Service
    static let batteryServiceUUID = CBUUID(string: "180F")
    static let batteryLevelCharUUID = CBUUID(string: "2A19")

    // 표준 Device Information Service
    static let deviceInfoServiceUUID = CBUUID(string: "180A")
    static let firmwareRevisionCharUUID = CBUUID(string: "2A26")
    static let modelNumberCharUUID = CBUUID(string: "2A24")

    nonisolated static let deviceNamePrefix = "AhaKey"

    // MARK: - Private

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var dataChar: CBCharacteristic?
    private var commandChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var batteryLevelChar: CBCharacteristic?
    private var pendingConnect = false
    private var rssiTimer: Timer?
    private var autoReconnectTimer: Timer?
    private var statusPollTimer: Timer?
    private var ideStatePollTimer: Timer?
    /// 마지막으로 연결한 UUID를 기억해 두어 빠르게 재연결한다
    private var lastPeripheralUUID: UUID?
    /// true이면 이 App은 검색·연결을 하지 않고 연결 끊김/폴링 재연결에도 반응하지 않는다(물리 키보드를 `ahakeyconfig-agent`가 점유할 때 AgentManager가 설정한다)
    private var suppressAutomaticConnection = false
    /// onAllCharacteristicsReady가 중복으로 실행되는 것을 방지
    private var didQueryAfterConnect = false
    /// 쓰기 큐: 연속 전송으로 기기에 과부하가 걸리는 것을 방지
    private var writeQueue: [(Data, String)] = []
    private var isWriting = false
    /// `writeQueue`의 앞쪽 순서에 대응하는 각 `writeCommandsSequentially` 배치의 남은 개수와 완료 콜백.
    private struct WriteCommandBatch {
        var commandsRemaining: Int
        var completion: (() -> Void)?
    }

    private var writeBatches: [WriteCommandBatch] = []
    private var protocolResponseWaiters: [UInt8: CheckedContinuation<CommandResponse, Error>] = [:]
    private var dataWriteResultContinuation: CheckedContinuation<Void, Error>?

    // MARK: - Init

    override init() {
        super.init()
        let storedOwner = UserDefaults.standard.string(forKey: "lab.jawa.ahakeyconfig.bluetoothConnectionOwner")
        if storedOwner == nil || storedOwner == BluetoothConnectionOwner.agentDaemon.rawValue {
            suppressAutomaticConnection = true
        }
        // 블루투스 권한이 허용된 경우에만 CBCentralManager를 만든다(만드는 즉시 시스템 팝업이 뜬다).
        // 권한이 미결정이면 사용자가 「요청」을 누른 뒤 ensureCentralManager()를 호출하도록 미룬다.
        if CBCentralManager.authorization == .allowedAlways {
            central = CBCentralManager(delegate: self, queue: nil)
        }
        refreshBluetoothAuthorization()
        startAutoReconnectPolling()
        startIDEStatePolling()
    }

    /// CBCentralManager가 생성되어 있는지 확인한다. 사용자가 블루투스 권한을 직접 요청할 때 호출한다.
    func ensureCentralManager() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    func refreshBluetoothAuthorization() {
        bluetoothPermissionGranted = Self.currentBluetoothAuthorizationGranted()
        bluetoothPoweredOn = central?.state == .poweredOn
        if !bluetoothPermissionGranted {
            bleConnectionStatus = "블루투스 권한이 꺼져 있음"
        } else if central?.state == .poweredOff {
            bleConnectionStatus = "블루투스 꺼짐"
        }
    }

    var bluetoothAuthorizationCanPrompt: Bool {
        CBCentralManager.authorization == .notDetermined
    }

    var bluetoothAuthorizationDeniedOrRestricted: Bool {
        switch CBCentralManager.authorization {
        case .restricted, .denied:
            return true
        case .allowedAlways, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private static func currentBluetoothAuthorizationGranted() -> Bool {
        switch CBCentralManager.authorization {
        case .allowedAlways:
            return true
        case .notDetermined:
            return true
        case .restricted, .denied:
            return false
        @unknown default:
            return true
        }
    }

    /// 「기기 정보 / 상단 바」 등에서 **사용자가 직접** 연결을 시작할 때 호출한다. 「Agent에 위임」으로 걸린 억제를 풀고 연결을 시도한다.
    func userInitiatedConnect() {
        ensureCentralManager()
        suppressAutomaticConnection = false
        connectAutomatically()
    }

    /// `AgentManager`의 블루투스 점유 주체와 일치한다. Agent에 넘기면 true, 이 App으로 돌려받으면 false.
    func setSuppressedForAgentOwningKeyboard(_ suppress: Bool) {
        suppressAutomaticConnection = suppress
    }

    func connectAutomatically() {
        guard !suppressAutomaticConnection else { return }
        guard central?.state == .poweredOn else {
            pendingConnect = true
            return
        }

        // 1. 알려진 UUID로 바로 연결(가장 빠름)
        if let uuid = lastPeripheralUUID {
            let known = central?.retrievePeripherals(withIdentifiers: [uuid]) ?? []
            if let p = known.first {
                appendLog("알려진 UUID로 바로 연결: \(p.name ?? uuid.uuidString)")
                self.peripheral = p
                p.delegate = self
                central?.connect(p, options: nil)
                bleConnectionStatus = "연결 중…"
                return
            }
        }

        // 2. 시스템에 이미 연결된 기기 찾기
        let connected = central?.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]) ?? []
        if let existing = connected.first(where: { ($0.name ?? "").lowercased().hasPrefix(Self.deviceNamePrefix.lowercased()) }) {
            appendLog("시스템에 이미 연결된 기기 발견: \(existing.name ?? "?")")
            self.peripheral = existing
            existing.delegate = self
            central?.connect(existing, options: nil)
            bleConnectionStatus = "연결 중…"
            return
        }

        // 3. 검색
        startScan()
    }

    func startScan() {
        guard central?.state == .poweredOn else {
            pendingConnect = true
            return
        }
        isScanning = true
        bleConnectionStatus = "검색 중…"
        appendLog("AhaKey 기기 검색 시작…")
        central?.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Double(10) * 1_000_000_000))
            if self.isScanning {
                self.central?.stopScan()
                self.isScanning = false
                self.bleConnectionStatus = "기기 대기 중"
                self.appendLog("검색 시간이 초과되어 백그라운드에서 기기 폴링을 계속합니다")
            }
        }
    }

    func disconnect() {
        guard let peripheral else { return }
        central?.cancelPeripheralConnection(peripheral)
        appendLog("사용자가 직접 연결 해제")
    }

    /// 0x7343으로 원시 명령 전송(큐를 사용해 연속 전송 과부하 방지)
    func writeCommand(_ data: Data) {
        guard let commandChar, let peripheral else {
            appendLog("명령 채널이 준비되지 않았습니다", isError: true)
            return
        }
        let writeType: CBCharacteristicWriteType =
            commandChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: commandChar, type: writeType)
        appendLog("→ CMD \(data.count)B: \(data.hexString)")
    }

    func uploadOLEDFrames(_ frames: [Data], fps: Int, mode: UInt8 = 0, startIndex: UInt16 = 0) async throws {
        guard let peripheral, let dataChar, let commandChar else {
            throw OLEDUploadError.channelNotReady
        }
        guard !frames.isEmpty else {
            throw OLEDUploadError.noFrames
        }
        guard frames.count <= AhaKeyCommand.oledMaxFrames else {
            throw OLEDUploadError.tooManyFrames(max: AhaKeyCommand.oledMaxFrames)
        }

        isUploadingOLED = true
        oledUploadProgress = OLEDUploadProgress(
            completedChunks: 0,
            totalChunks: frames.reduce(0) { partialResult, frame in
                partialResult + max(1, Int(ceil(Double(frame.count) / Double(AhaKeyCommand.oledChunkSize))))
            },
            completedFrames: 0,
            totalFrames: frames.count
        )
        appendLog("LCD 데이터 업로드 시작: \(frames.count) 프레임, FPS=\(fps), mode=\(mode), startIndex=\(startIndex), frameSlotSize=\(AhaKeyCommand.oledFrameSlotSize)")

        defer {
            isUploadingOLED = false
            oledUploadProgress = nil
        }

        let writeType: CBCharacteristicWriteType =
            dataChar.properties.contains(.write) ? .withResponse : .withoutResponse
        var completedChunks = 0

        for (frameIndex, frame) in frames.enumerated() {
            let frameAddress = UInt32(Int(startIndex) + frameIndex) * UInt32(AhaKeyCommand.oledFrameSlotSize)
            appendLog("  프레임 #\(frameIndex) 물리 주소=0x\(String(format: "%08X", frameAddress))=\(frameAddress), 크기=\(frame.count)B")
            let chunks = stride(from: 0, to: frame.count, by: AhaKeyCommand.oledChunkSize).map { offset in
                let end = min(offset + AhaKeyCommand.oledChunkSize, frame.count)
                return (offset: offset, data: Data(frame[offset ..< end]))
            }

            for chunk in chunks {
                let address = frameAddress + UInt32(chunk.offset)
                let prepare = AhaKeyCommand.prepareWrite(chunkLength: chunk.data.count, address: address)
                _ = try await sendCommandAwaitingResponse(prepare, expectedCommand: AhaKeyCommand.cmdPrepareWrite)

                try await writeDataChunk(chunk.data, to: peripheral, characteristic: dataChar, type: writeType)
                completedChunks += 1
                oledUploadProgress = OLEDUploadProgress(
                    completedChunks: completedChunks,
                    totalChunks: oledUploadProgress?.totalChunks ?? completedChunks,
                    completedFrames: frameIndex,
                    totalFrames: frames.count
                )
            }

            oledUploadProgress = OLEDUploadProgress(
                completedChunks: completedChunks,
                totalChunks: oledUploadProgress?.totalChunks ?? completedChunks,
                completedFrames: frameIndex + 1,
                totalFrames: frames.count
            )
        }

        let delay = UInt16(max(1, 1000 / max(1, fps)))
        let updateCommand = AhaKeyCommand.updatePicture(
            mode: mode,
            startIndex: startIndex,
            frameCount: UInt16(frames.count),
            timeDelayMs: delay
        )
        appendLog("→ updatePicture mode=\(mode) startIndex=\(startIndex) frameCount=\(frames.count) delayMs=\(delay) hex=\(updateCommand.hexString)")
        _ = try await sendCommandAwaitingResponse(updateCommand, expectedCommand: AhaKeyCommand.cmdUpdatePic)
        appendLog("LCD 업로드 완료: \(frames.count) 프레임, start=\(startIndex)")
        _ = commandChar
    }

    /// 명령 일괄 쓰기(각 명령 사이 50ms 간격으로 기기 과부하 방지). **해당 배치**가 모두 쓰이면 메인 스레드에서 `completion`을 실행한다(큐에 0개가 들어가면 즉시 실행).
    func writeCommandsSequentially(
        _ commands: [(data: Data, label: String)],
        completion: (() -> Void)? = nil
    ) {
        if commands.isEmpty {
            completion?()
            return
        }
        writeBatches.append(WriteCommandBatch(commandsRemaining: commands.count, completion: completion))
        writeQueue.append(contentsOf: commands.map { ($0.data, $0.label) })
        drainWriteQueue()
    }

    private func drainWriteQueue() {
        guard !isWriting, !writeQueue.isEmpty else { return }
        isWriting = true
        let (data, label) = writeQueue.removeFirst()
        if !writeBatches.isEmpty {
            writeBatches[0].commandsRemaining -= 1
            if writeBatches[0].commandsRemaining == 0 {
                let c = writeBatches.removeFirst().completion
                c?()
            }
        }
        appendLog(label)
        writeCommand(data)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(50) * 1_000_000)
            self.isWriting = false
            self.drainWriteQueue()
        }
    }

    /// 기기 상태 조회
    func queryDeviceStatus() {
        let cmd = AhaKeyCommand.queryDeviceStatus()
        appendLog("기기 상태 조회…")
        writeCommand(cmd)
    }

    /// 키 매핑 설정
    func setKeyMapping(mode: UInt8 = 0, keyIndex: UInt8, hidCodes: [UInt8]) {
        let cmd = AhaKeyCommand.setKeyMapping(mode: mode, keyIndex: keyIndex, hidCodes: hidCodes)
        let keyName = "Key\(keyIndex + 1)"
        let codeNames = hidCodes.map { HIDUsage.name(for: $0) }.joined(separator: "+")
        appendLog("Mode\(mode) \(keyName) 키 코드 쓰기: \(codeNames)")
        writeCommand(cmd)
    }

    /// 키 매크로 설정(펌웨어 subMacro 서브타입 0x74).
    /// - parameter macroData: 평탄화된 (action, param) 바이트 스트림. 펌웨어 상한은 98바이트.
    func setKeyMacro(mode: UInt8 = 0, keyIndex: UInt8, macroData: [UInt8]) {
        let cmd = AhaKeyCommand.setKeyMacro(mode: mode, keyIndex: keyIndex, macroData: macroData)
        appendLog("Mode\(mode) Key\(keyIndex + 1) 매크로 쓰기: \(macroData.count) 바이트 / \(macroData.count / 2) 단계")
        writeCommand(cmd)
    }

    /// 키 설명 설정(LCD에 표시)
    func setKeyDescription(mode: UInt8 = 0, keyIndex: UInt8, text: String) {
        let cmd = AhaKeyCommand.setKeyDescription(mode: mode, keyIndex: keyIndex, text: text)
        appendLog("Mode\(mode) Key\(keyIndex + 1) 설명 쓰기: \(text)")
        writeCommand(cmd)
    }

    /// 기기 Flash에 설정 저장
    func saveConfig() {
        let cmd = AhaKeyCommand.saveConfig()
        appendLog("기기에 설정 저장…")
        writeCommand(cmd)
    }

    func readPictureState(mode: UInt8) async throws -> AhaKeyPictureState {
        let response = try await sendCommandAwaitingResponse(
            AhaKeyCommand.readPicState(mode: mode),
            expectedCommand: AhaKeyCommand.cmdReadPicState
        )
        guard let state = AhaKeyResponseParser.parsePictureStateResponse(response.payload) else {
            throw OLEDUploadError.invalidPictureStatePayload
        }
        appendLog("  이미지 상태 mode=\(state.mode) start=\(state.startIndex) length=\(state.picLength) interval=\(state.frameInterval) max=\(state.allModeMaxPic)")
        return state
    }

    /// IDE 상태를 키보드 LED에 동기화
    func updateIDEState(_ state: IDEState) {
        guard commandChar != nil else { return }
        let cmd = AhaKeyCommand.updateState(state)
        writeCommand(cmd)
    }

    /// 최신 펌웨어에서 0x91은 조명 효과 미리보기로 바뀌었다. 가상 레버는 소프트웨어 오버라이드만 유지하며, 더 이상 예전 0x91을 키보드로 보내지 않는다.
    /// value: 0=auto/up, 1=manual/down, 2=mid
    func setSwitchStateViaBLE(_ value: UInt8) {
        appendLog("가상 레버 sw_state=\(value)는 소프트웨어 오버라이드로만 동작합니다. 최신 펌웨어의 0x91은 조명 효과 미리보기용입니다.")
    }

    func setLightMapping(mode: UInt8, stateEffects: [UInt8]) {
        guard commandChar != nil else { return }
        writeCommand(AhaKeyCommand.setLightMapping(mode: mode, stateEffects: stateEffects))
        appendLog("→ 조명 효과 매핑 mode=\(mode) effects=\(stateEffects)")
    }

    func setBrightness(_ value: UInt8) {
        guard commandChar != nil else { return }
        writeCommand(AhaKeyCommand.setBrightness(value))
        appendLog("→ 밝기 \(value)")
    }

    func previewLightEffect(_ effect: UInt8) {
        guard commandChar != nil else { return }
        writeCommand(AhaKeyCommand.previewLightEffect(effect))
        appendLog("→ 조명 효과 미리보기 \(effect)")
    }

    func setWorkMode(_ mode: UInt8) {
        guard commandChar != nil else { return }
        writeCommand(AhaKeyCommand.setWorkMode(mode))
        appendLog("→ 작업 모드 \(mode)")
    }

    /// 기기 블루투스 이름 변경
    func changeDeviceName(_ name: String) {
        let cmd = AhaKeyCommand.changeName(name)
        appendLog("기기 이름 변경: \(name)")
        writeCommand(cmd)
        // 변경 후 저장하고 새로 고침
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(100) * 1_000_000)
            self.saveConfig()
        }
    }

    func clearLog() {
        commLog.removeAll()
    }

    /// 내부 `appendLog`와 동일하다(`~/Library/.../AhaKeyConfig/diagnostics/ble-comm.log`와 시스템 로그 포함). Studio 등에서 디버그 설명을 기록할 때 쓴다.
    func appendCommLogLine(_ message: String, isError: Bool = false) {
        appendLog(message, isError: isError)
    }

    // MARK: - Logging

    static let logFileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AhaKeyConfig/diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ble-comm.log")
    }()

    private func appendLog(_ message: String, isError: Bool = false) {
        let entry = BLELogEntry(timestamp: Date(), message: message, isError: isError)
        commLog.append(entry)
        if commLog.count > maxLogEntries {
            commLog.removeFirst(commLog.count - maxLogEntries)
        }
        if isError {
            log.error("\(message)")
        } else {
            log.info("\(message)")
        }
        let line = "[\(entry.formattedTime)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.logFileURL.path) {
                if let fh = try? FileHandle(forWritingTo: Self.logFileURL) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try? data.write(to: Self.logFileURL)
            }
        }
    }

    private func startRSSIPolling() {
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.peripheral?.readRSSI()
            }
        }
    }

    private func startAutoReconnectPolling() {
        autoReconnectTimer?.invalidate()
        autoReconnectTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.central?.state == .poweredOn else { return }
                guard !self.isConnected, !self.isScanning else { return }
                guard self.bleConnectionStatus != "연결 중…" else { return }
                self.appendLog("백그라운드 폴링 중, 기기를 찾는 중…")
                self.connectAutomatically()
            }
        }
    }

    private func stopRSSIPolling() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }

    /// 기기 상태를 주기적으로 조회해 키보드 물리 레버 단계 변화를 감지한다(workMode / switchState / lightMode).
    /// 펌웨어는 단계가 바뀔 때 직접 push하지 않으므로 폴링이 필요하다.
    private func startStatusPolling() {
        statusPollTimer?.invalidate()
        statusPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isConnected else { return }
                // LCD 업로드 중에는 명령 채널을 점유하지 않는다
                guard !self.isUploadingOLED else { return }
                // protocol 응답을 기다리는 중이면(readPictureState / saveConfig 등) 건너뛴다
                guard self.protocolResponseWaiters.isEmpty else { return }
                self.queryDeviceStatus()
            }
        }
    }

    private func stopStatusPolling() {
        statusPollTimer?.invalidate()
        statusPollTimer = nil
    }

    private func startIDEStatePolling() {
        ideStatePollTimer?.invalidate()
        ideStatePollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pollIDEStateFile()
            }
        }
    }

    /// 공유 파일 읽기를 즉시 한 번 실행한다(사용자가 가상 레버를 누른 직후 호출해 다음 정기 poll을 기다리지 않도록 한다)
    func refreshAgentStateFromFileNow() {
        pollIDEStateFile()
    }

    /// 가상 레버를 누른 순간의 낙관적 갱신 값. 파일 poll이 agentSwitchState를 목표 값으로 갱신하기 전까지 이 값으로 버티고,
    /// 이후 폴링이 실제 값을 가져오면 지운다. 한 번 누르면 곧바로 레버 단계가 바뀌는 것이 보이도록 하기 위한 것이다.
    @Published private(set) var optimisticSwitchOverride: Int? = nil

    func applyOptimisticSwitchOverride(_ value: UInt8) {
        optimisticSwitchOverride = Int(value)
    }

    private func clearOptimisticSwitchOverrideIfMatched() {
        guard let opt = optimisticSwitchOverride else { return }
        if agentSwitchState == opt || (isConnected && switchState == opt) {
            optimisticSwitchOverride = nil
        }
    }

    private func pollIDEStateFile() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AhaKeyConfig/current-ide-state.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if liveIDEStateValue != nil { liveIDEStateValue = nil }
            if agentLightMode != nil { agentLightMode = nil }
            if agentSwitchState != nil { agentSwitchState = nil }
            if agentWorkMode != nil { agentWorkMode = nil }
            return
        }
        let now = Date().timeIntervalSince1970
        // stateValue는 순간 상태(hook 트리거)로 30초 뒤 만료된다. 만료되면 비우며, 펌웨어 LED도 state 없는 기본값으로 돌아간다
        if let v = obj["stateValue"] as? Int,
           let stateTs = (obj["stateTs"] as? Double) ?? (obj["ts"] as? Double),
           now - stateTs <= 30 {
            if liveIDEStateValue != v { liveIDEStateValue = v }
        } else {
            if liveIDEStateValue != nil { liveIDEStateValue = nil }
        }
        // lightMode/switchState/workMode는 BLE 알림에서 온다. 2분간 새 데이터가 없으면 agent가 연결 해제된 것으로 본다
        if let topTs = obj["ts"] as? Double, now - topTs <= 120 {
            let lm = obj["lightMode"] as? Int
            let sw = obj["switchState"] as? Int
            let wm = obj["workMode"] as? Int
            if agentLightMode != lm { agentLightMode = lm }
            if agentSwitchState != sw { agentSwitchState = sw }
            if agentWorkMode != wm { agentWorkMode = wm }
        } else {
            if agentLightMode != nil { agentLightMode = nil }
            if agentSwitchState != nil { agentSwitchState = nil }
            if agentWorkMode != nil { agentWorkMode = nil }
        }
        clearOptimisticSwitchOverrideIfMatched()
    }

    /// AhaKey 메인 서비스 특성이 모두 준비되면 실행된다(한 번만)
    private func onAllCharacteristicsReady() {
        guard !didQueryAfterConnect else { return }
        didQueryAfterConnect = true
        appendLog("모든 특성 준비 완료, 기기 상태 조회")
        queryDeviceStatus()
        queryAllPictureStates()
    }

    /// 각 mode의 0x83 이미지 메타 정보를 순서대로 조회해 keyboardPictureStates에 누적한다
    private func queryAllPictureStates() {
        Task { [weak self] in
            guard let self else { return }
            for slot in 0..<4 {
                do {
                    let state = try await self.readPictureState(mode: UInt8(slot))
                    self.keyboardPictureStates[slot] = KeyboardPictureState(
                        frameCount: state.picLength,
                        frameIntervalMs: state.frameInterval
                    )
                    self.appendLog("  mode\(slot) flash: 프레임 수=\(state.picLength) 간격=\(state.frameInterval)ms")
                } catch {
                    self.appendLog("  mode\(slot) 이미지 상태 조회 실패: \(error)", isError: true)
                }
            }
        }
    }

    private func sendCommandAwaitingResponse(_ data: Data, expectedCommand: UInt8, timeoutSeconds: Double = 5.0) async throws -> CommandResponse {
        defer { protocolResponseWaiters[expectedCommand] = nil }
        return try await withThrowingTaskGroup(of: CommandResponse.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResponse, Error>) in
                    Task { @MainActor in
                        self?.protocolResponseWaiters[expectedCommand] = continuation
                        self?.writeCommand(data)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Double(timeoutSeconds) * 1_000_000_000))
                throw OLEDUploadError.timeout(command: expectedCommand)
            }

            let result = try await group.next() ?? (status: 0, payload: Data())
            group.cancelAll()
            guard result.status == 0 else {
                throw OLEDUploadError.deviceRejected(command: expectedCommand, status: result.status)
            }
            return result
        }
    }

    private func writeDataChunk(
        _ data: Data,
        to peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        type: CBCharacteristicWriteType,
        timeoutSeconds: Double = 5.0
    ) async throws {
        defer { dataWriteResultContinuation = nil }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task { @MainActor in
                        self?.dataWriteResultContinuation = continuation
                        let negotiatedLength = max(1, peripheral.maximumWriteValueLength(for: type))
                        // 펌웨어 쪽은 oledPacketSize(약 180B) 단위로 프레임을 구성하므로 이 값을 서브 패킷 상한으로 삼아야 한다.
                        // 그렇지 않으면 CoreBluetooth의 "value's length is invalid"가 발생하거나 펌웨어가 프레임을 그냥 버린다.
                        let maxPacketLength = min(negotiatedLength, AhaKeyCommand.oledPacketSize)
                        self?.appendLog("→ DATA \(data.count)B, 분할 \(maxPacketLength)B (협상 상한 \(negotiatedLength)B)")
                        Task {
                            for offset in stride(from: 0, to: data.count, by: maxPacketLength) {
                                let end = min(offset + maxPacketLength, data.count)
                                let packet = Data(data[offset ..< end])
                                peripheral.writeValue(packet, for: characteristic, type: type)
                                try? await Task.sleep(nanoseconds: UInt64(12) * 1_000_000)
                            }
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Double(timeoutSeconds) * 1_000_000_000))
                throw OLEDUploadError.timeout(command: AhaKeyCommand.cmdWriteResult)
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }
}

// MARK: - 레버 단계 전환 → 시스템 알림(`switchState`와 같은 소스. 별도 .swift 파일이 인덱서에 잡히지 않는 문제를 피하려고 이 파일에 둔다)

/// `AhaKeyBLEManager.switchState`의 안정적인 변화를 감시해, 레버 단계가 바뀔 때 macOS 알림을 띄운다.
@MainActor
final class SwitchStateNotifier: ObservableObject {
    static let shared = SwitchStateNotifier()

    private weak var bleManager: AhaKeyBLEManager?
    private var switchStateCancellable: AnyCancellable?
    private var agentSwitchStateCancellable: AnyCancellable?
    private var lastObservedState: Int?
    private var lastNotificationAt: Date?
    private var hasInitialState = false
    private var hasRequestedAuthorization = false

    private init() {}

    func bind(to manager: AhaKeyBLEManager) {
        if bleManager === manager, switchStateCancellable != nil, agentSwitchStateCancellable != nil { return }

        bleManager = manager
        lastObservedState = nil
        hasInitialState = false
        switchStateCancellable = manager.$switchState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                self?.handleStateChange(newState)
            }
        agentSwitchStateCancellable = manager.$agentSwitchState
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                self?.handleStateChange(newState)
            }
    }

    private func handleStateChange(_ newState: Int) {
        defer { lastObservedState = newState }

        guard hasInitialState else {
            hasInitialState = true
            return
        }

        guard let previous = lastObservedState, previous != newState else { return }

        if let last = lastNotificationAt, Date().timeIntervalSince(last) < 1.5 {
            return
        }
        lastNotificationAt = Date()

        let switchedToAuto = (previous != 0 && newState == 0)
        let switchedToManual = (previous == 0 && newState != 0)

        if switchedToAuto {
            postNotification(
                title: "레버 → 자동 승인",
                body: "Kimi: AhaKey Kimi Hooks가 설치되어 있으면 자동 단계가 현재 세션의 승인을 바로 이어받습니다. 방금 설치했거나 kimi-cli를 업그레이드했다면 kimi를 한 번 다시 실행하세요. Claude/Cursor/Codex는 각자의 훅을 그대로 사용합니다.",
                identifier: "lab.jawa.ahakey.switch.auto",
                isCritical: true
            )
        } else if switchedToManual {
            postNotification(
                title: "레버 → 수동 승인",
                body: "Claude / Cursor / Codex: 각자의 확인 절차를 따릅니다. Kimi: AhaKey Kimi Hooks가 설치되어 있으면 수동 단계가 현재 세션을 곧바로 수동 승인으로 되돌립니다.",
                identifier: "lab.jawa.ahakey.switch.manual",
                isCritical: false
            )
        }
    }

    private func postNotification(title: String, body: String, identifier: String, isCritical: Bool) {
        let center = UNUserNotificationCenter.current()
        let deliver = { [weak self] in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = isCritical ? .defaultCritical : .default
            let request = UNNotificationRequest(identifier: "\(identifier).\(UUID().uuidString)",
                                                content: content,
                                                trigger: nil)
            center.add(request) { error in
                if error != nil {
                    Task { @MainActor in
                        self?.fallbackAlert(title: title, body: body)
                    }
                }
            }
        }

        if hasRequestedAuthorization {
            deliver()
            return
        }
        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                deliver()
            } else {
                Task { @MainActor in
                    self.fallbackAlert(title: title, body: body)
                }
            }
        }
    }

    private func fallbackAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}

enum OLEDUploadError: LocalizedError {
    case channelNotReady
    case noFrames
    case tooManyFrames(max: Int)
    case noAvailablePictureSlot(needed: Int, max: Int)
    case timeout(command: UInt8)
    case deviceRejected(command: UInt8, status: UInt8)
    case invalidPictureStatePayload

    var errorDescription: String? {
        switch self {
        case .channelNotReady:
            return "BLE 데이터 채널이 아직 준비되지 않았습니다."
        case .noFrames:
            return "업로드할 이미지 프레임이 없습니다."
        case .tooManyFrames(let max):
            return "프레임 수가 기기 상한을 초과했습니다. 최대 \(max) 프레임까지 지원합니다."
        case .noAvailablePictureSlot(let needed, let max):
            return "애니메이션에 \(needed) 프레임이 필요하지만 기기에 연속된 공간이 부족합니다. 전체 용량 상한은 약 \(max) 프레임입니다."
        case .timeout(let command):
            return String(format: "기기 응답 대기 시간 초과: 0x%02X", command)
        case .deviceRejected(let command, let status):
            return String(format: "기기가 명령 0x%02X을 거부했습니다. 상태 코드 0x%02X", command, status)
        case .invalidPictureStatePayload:
            return "기기가 반환한 애니메이션 슬롯 정보를 해석할 수 없습니다."
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension AhaKeyBLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.refreshBluetoothAuthorization()
                self.appendLog("블루투스가 켜졌습니다")
                self.connectAutomatically()
            case .poweredOff:
                self.refreshBluetoothAuthorization()
                self.appendLog("블루투스가 꺼졌습니다", isError: true)
                self.bleConnectionStatus = "블루투스 꺼짐"
            case .unauthorized:
                self.refreshBluetoothAuthorization()
                self.appendLog("블루투스 권한이 꺼져 있음", isError: true)
                self.bleConnectionStatus = "블루투스 권한이 꺼져 있음"
            default:
                self.refreshBluetoothAuthorization()
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.lowercased().hasPrefix(Self.deviceNamePrefix.lowercased()) else { return }

        Task { @MainActor in
            self.appendLog("기기 발견: \(name) RSSI=\(RSSI)")
            self.central?.stopScan()
            self.isScanning = false
            self.peripheral = peripheral
            peripheral.delegate = self
            self.central?.connect(peripheral, options: nil)
            self.bleConnectionStatus = "연결 중…"
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.isConnected = true
            self.deviceName = peripheral.name
            self.bleDeviceUUID = peripheral.identifier.uuidString
            self.lastPeripheralUUID = peripheral.identifier
            self.bleConnectionStatus = "연결됨"
            self.appendLog("연결됨: \(peripheral.name ?? "?") UUID=\(peripheral.identifier.uuidString)")
            self.autoReconnectTimer?.invalidate()
            self.autoReconnectTimer = nil
            peripheral.discoverServices([
                Self.serviceUUID,
                Self.batteryServiceUUID,
                Self.deviceInfoServiceUUID,
            ])
            peripheral.readRSSI()
            self.startRSSIPolling()
            self.startStatusPolling()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.bleConnectionStatus = "연결 실패"
            self.appendLog("연결 실패: \(error?.localizedDescription ?? "알 수 없음")", isError: true)
            self.startAutoReconnectPolling()
            // 3초 후 재시도
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Double(3) * 1_000_000_000))
                if !self.isConnected {
                    self.connectAutomatically()
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let dropped = self.writeQueue.count
            let openBatches = self.writeBatches.count
            if dropped > 0 || openBatches > 0 {
                self.appendLog(
                    "BLE 연결이 해제되어 아직 보내지 않은 명령 \(dropped)건을 버립니다(닫히지 않은 배치 \(openBatches)개). \(error.map { "원인: \($0.localizedDescription)" } ?? "")",
                    isError: true
                )
            }
            self.isConnected = false
            self.bleConnectionStatus = "연결 해제됨"
            self.dataChar = nil
            self.commandChar = nil
            self.notifyChar = nil
            self.batteryLevelChar = nil
            self.dataCharReady = false
            self.commandCharReady = false
            self.notifyCharReady = false
            // peripheral과 lastPeripheralUUID는 지우지 않는다 — 직접 연결 재시도에 사용한다
            self.peripheral = nil
            self.writeQueue.removeAll()
            self.isWriting = false
            self.writeBatches.removeAll()
            self.didQueryAfterConnect = false
            self.keyboardPictureStates.removeAll()
            self.stopRSSIPolling()
            self.stopStatusPolling()
            self.startAutoReconnectPolling()
            self.appendLog("연결 해제됨: \(error?.localizedDescription ?? "정상")")

            // 2초 후 자동 재연결
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Double(2) * 1_000_000_000))
                if !self.isConnected {
                    self.appendLog("자동 재연결 시도…")
                    self.connectAutomatically()
                }
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension AhaKeyBLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let services = peripheral.services else { return }
            for service in services {
                self.appendLog("서비스 발견: \(service.uuid)")
                switch service.uuid {
                case Self.serviceUUID:
                    peripheral.discoverCharacteristics(
                        [Self.dataCharUUID, Self.infoCharUUID, Self.commandCharUUID, Self.notifyCharUUID],
                        for: service
                    )
                case Self.batteryServiceUUID:
                    peripheral.discoverCharacteristics([Self.batteryLevelCharUUID], for: service)
                case Self.deviceInfoServiceUUID:
                    peripheral.discoverCharacteristics(
                        [Self.firmwareRevisionCharUUID, Self.modelNumberCharUUID],
                        for: service
                    )
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for char in service.characteristics ?? [] {
                switch char.uuid {
                // AhaKey 메인 서비스 특성
                case Self.dataCharUUID:
                    self.dataChar = char
                    self.dataCharReady = true
                    peripheral.setNotifyValue(true, for: char)
                    self.appendLog("데이터 특성(0x7341) 알림 구독 완료")
                case Self.commandCharUUID:
                    self.commandChar = char
                    self.commandCharReady = true
                    self.appendLog("명령 특성(0x7343) 준비 완료")
                case Self.notifyCharUUID:
                    self.notifyChar = char
                    self.notifyCharReady = true
                    peripheral.setNotifyValue(true, for: char)
                    self.appendLog("알림 특성(0x7344) 구독 완료")
                case Self.infoCharUUID:
                    self.appendLog("기기 정보(0x7342) 준비 완료")

                // 표준 Battery Level
                case Self.batteryLevelCharUUID:
                    self.batteryLevelChar = char
                    peripheral.readValue(for: char)
                    if char.properties.contains(.notify) {
                        peripheral.setNotifyValue(true, for: char)
                    }
                    self.appendLog("배터리 특성(0x2A19) 읽는 중")

                // 표준 Device Information
                case Self.firmwareRevisionCharUUID:
                    peripheral.readValue(for: char)
                case Self.modelNumberCharUUID:
                    peripheral.readValue(for: char)

                default:
                    break
                }
            }

            // AhaKey 핵심 특성 세 개가 모두 준비되었는지 확인한 뒤 조회를 보낸다
            if self.dataCharReady && self.commandCharReady && self.notifyCharReady {
                self.onAllCharacteristicsReady()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor in
            self.handleNotification(from: characteristic.uuid, data: data)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        Task { @MainActor in
            self.signalStrength = RSSI.intValue
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                self.appendLog("특성 \(characteristic.uuid) 쓰기 실패: \(error.localizedDescription)", isError: true)
            } else {
                self.appendLog("특성 \(characteristic.uuid) 쓰기 완료")
            }
        }
    }

    private func handleNotification(from uuid: CBUUID, data: Data) {
        let hex = data.hexString
        switch uuid {
        case Self.dataCharUUID:
            appendLog("← DATA(0x7341): \(hex)")
            parseProtocolResponse(data)
        case Self.notifyCharUUID:
            appendLog("← NOTIFY(0x7344): \(hex)")
            parseProtocolResponse(data)
        case Self.batteryLevelCharUUID:
            if let level = data.first {
                batteryLevel = Int(level)
                appendLog("← 배터리: \(batteryLevel)%")
            }
        case Self.firmwareRevisionCharUUID:
            if let str = String(data: data, encoding: .utf8) {
                firmwareRevision = str
            }
        case Self.modelNumberCharUUID:
            if let str = String(data: data, encoding: .utf8) {
                modelNumber = str
            }
        default:
            appendLog("← 알 수 없음(\(uuid)): \(hex)")
        }
    }

    private func parseProtocolResponse(_ data: Data) {
        if let status = AhaKeyResponseParser.parseDeviceStatus(data) {
            batteryLevel = status.battery
            firmwareMainVersion = status.firmwareMain
            firmwareSubVersion = status.firmwareSub
            workMode = status.workMode
            NotificationCenter.default.post(
                name: .ahaKeyKeyboardWorkModeChanged,
                object: nil,
                userInfo: ["workMode": status.workMode]
            )
            lightMode = status.lightMode
            switchState = status.switchState
            brightness = status.brightness
            appendLog("  상태: 배터리=\(status.battery) 펌웨어=\(status.firmwareMain).\(status.firmwareSub) 모드=\(status.workMode) 조명=\(status.lightMode) 스위치=\(status.switchState) 밝기=\(status.brightness)")
        } else if AhaKeyResponseParser.isProtocolFrame(data) {
            if let response = AhaKeyResponseParser.parseCommandResponse(data) {
                protocolResponseWaiters.removeValue(forKey: response.cmd)?.resume(returning: (response.status, response.payload))

                if response.cmd == AhaKeyCommand.cmdWriteResult {
                    if response.status == 0 {
                        dataWriteResultContinuation?.resume()
                    } else {
                        dataWriteResultContinuation?.resume(throwing: OLEDUploadError.deviceRejected(command: response.cmd, status: response.status))
                    }
                    dataWriteResultContinuation = nil
                }

                if response.status == 0 {
                    appendLog("  ✓ 명령 0x\(String(format: "%02X", response.cmd)) 성공")
                } else {
                    let payloadHex = response.payload.isEmpty ? "—" : response.payload.hexString
                    appendLog("  명령 0x\(String(format: "%02X", response.cmd)) 실패: status=0x\(String(format: "%02X", response.status)) payload=\(payloadHex)", isError: true)
                }
            }
        } else {
            let bytes = data.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
            appendLog("  원시 [\(data.count)B]: \(bytes)")
        }
    }

    /// 탐지 명령 전송
    func sendProbeCommands() {
        guard commandChar != nil else {
            appendLog("명령 채널이 준비되지 않았습니다", isError: true)
            return
        }
        appendLog("═══ 탐지 시작 ═══")

        let probes: [(String, Data)] = [
            ("기기 상태 조회", AhaKeyCommand.queryDeviceStatus()),
            ("설정 읽기 0x01", Data([0xAA, 0xBB, 0x01, 0xCC, 0xDD])),
            ("설정 읽기 0x03", Data([0xAA, 0xBB, 0x03, 0xCC, 0xDD])),
            ("설정 읽기 0x05", Data([0xAA, 0xBB, 0x05, 0xCC, 0xDD])),
        ]
        for (label, data) in probes {
            appendLog("→ \(label): \(data.hexString)")
            writeCommand(data)
        }

        if let batteryLevelChar {
            peripheral?.readValue(for: batteryLevelChar)
            appendLog("→ 배터리 잔량 다시 읽기")
        }

        appendLog("═══ 탐지 완료, 콜백 대기 ═══")
    }
}

extension Notification.Name {
    /// `userInfo["workMode"]`는 `Int`이며, 키보드 물리 레버 단계와 일치한다.
    static let ahaKeyKeyboardWorkModeChanged = Notification.Name("lab.jawa.ahakeyconfig.keyboardWorkModeChanged")
}

// MARK: - Data Extension

extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
