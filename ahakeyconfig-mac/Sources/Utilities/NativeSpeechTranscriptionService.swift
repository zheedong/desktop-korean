import AppKit
import AVFoundation
import ApplicationServices
import Foundation
import Speech

@MainActor
final class NativeSpeechTranscriptionService: ObservableObject {
    static let shared = NativeSpeechTranscriptionService()

    @Published private(set) var microphoneGranted = false
    @Published private(set) var speechRecognitionGranted = false
    @Published private(set) var siriEnabled = false
    @Published private(set) var dictationEnabled = false
    @Published private(set) var isRecording = false
    @Published private(set) var statusMessage = "Apple 기본 전사 기능이 준비되기를 기다리는 중입니다."
    @Published private(set) var transcriptPreview = ""
    @Published private(set) var lastCommittedText = ""
    @Published private(set) var lastPermissionCheckSummary = "마이크, 음성 전사, Siri 권한을 아직 확인하지 않았습니다."

    // MARK: 녹음 트리거 방식 설정
    /// 짧게 누르기(토글 방식): 녹음이 끝난 뒤 AhaType 정리를 호출할지 여부
    @Published var shortPressAhaTypeEnabled: Bool = UserDefaults.standard.object(forKey: "nativeSpeech.shortPressAhaType") as? Bool ?? true {
        didSet { UserDefaults.standard.set(shortPressAhaTypeEnabled, forKey: "nativeSpeech.shortPressAhaType") }
    }
    /// 길게 누르기 모드(누르는 동안 녹음, 놓으면 전송)는 항상 켜져 있으며 사용자가 끌 수 없습니다
    @Published var longPressEnabled: Bool = true
    /// 길게 누르기 모드가 끝난 뒤 AhaType을 호출할지 여부(기본값 꺼짐: 빠른 즉시 전송)
    @Published var longPressAhaTypeEnabled: Bool = UserDefaults.standard.object(forKey: "nativeSpeech.longPressAhaType") as? Bool ?? false {
        didSet { UserDefaults.standard.set(longPressAhaTypeEnabled, forKey: "nativeSpeech.longPressAhaType") }
    }
    /// 길게 누르기 판정 임계값(밀리초)
    @Published var longPressThresholdMs: Int = UserDefaults.standard.object(forKey: "nativeSpeech.longPressThresholdMs") as? Int ?? 500 {
        didSet { UserDefaults.standard.set(longPressThresholdMs, forKey: "nativeSpeech.longPressThresholdMs") }
    }

    /// 현재 길게 누르기 녹음 모드인지 여부(누르고 있는 중이며, 놓으면 바로 전송됩니다)
    @Published private(set) var isLongPressRecording = false

    private var longPressTimerWork: DispatchWorkItem?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var finalizeWorkItem: DispatchWorkItem?
    private var currentTranscript = ""
    /// `isFinal`, 1초 타임아웃, `error` 콜백이 각각 한 번씩 발생해 같은 구간이 ⌘V로 여러 번 입력되는 것을 방지
    private var hasCommittedThisRecording = false


    private let syntheticEventUserData: Int64 = 0x4148414B

    private init() { }

    func start() {
        AhaTypeTextOptimizer.shared.refreshFromDisk()
        refreshPermissions(requestIfNeeded: false)
    }

    /// - Parameter deferredTCCRequery: `VoiceRelayService`와 동일하게, 사용자가 「다시 확인」을 누를 때 한 박자 늦게 읽어 TCC 상태가 갱신되지 않아 화면이 「반응 없음」처럼 보이는 것을 방지합니다.
    func refreshPermissions(requestIfNeeded: Bool = false, deferredTCCRequery: Bool = false) {
        if requestIfNeeded {
            performPermissionRead(requestIfNeeded: true)
            return
        }
        if deferredTCCRequery {
            lastPermissionCheckSummary = "마이크와 음성 전사 권한을 확인하는 중…"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(450) * 1_000_000)
                self.performPermissionRead(requestIfNeeded: false)
                if !self.microphoneGranted || !self.speechRecognitionGranted {
                    try? await Task.sleep(nanoseconds: UInt64(800) * 1_000_000)
                    self.performPermissionRead(requestIfNeeded: false)
                }
            }
            return
        }
        performPermissionRead(requestIfNeeded: false)
    }

    private func performPermissionRead(requestIfNeeded: Bool) {
        let currentMicGranted = Self.isMicrophoneGranted()

        let currentSpeechStatus = SFSpeechRecognizer.authorizationStatus()
        let currentSpeechGranted = currentSpeechStatus == .authorized
        let currentSiriEnabled = Self.readBooleanPreference(
            domain: "com.apple.assistant.support",
            key: "Assistant Enabled"
        ) ?? false
        let currentDictationEnabled = Self.readBooleanPreference(
            domain: "com.apple.assistant.support",
            key: "Dictation Enabled"
        ) ?? Self.readBooleanPreference(
            domain: "com.apple.HIToolbox",
            key: "AppleDictationAutoEnable"
        ) ?? false

        if requestIfNeeded {
            if Self.isMicrophoneUndetermined() {
                // 먼저 마이크 권한을 요청하고, 사용자가 응답한 뒤 음성 인식을 확인해 두 대화상자가 동시에 대기하며 순서가 뒤엉키는 것을 방지
                Self.requestMicrophoneAccess {
                    Task { @MainActor in
                        self.refreshPermissions()
                        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                            SFSpeechRecognizer.requestAuthorization { _ in
                                Task { @MainActor in self.refreshPermissions() }
                            }
                        }
                    }
                }
                return
            }

            if currentSpeechStatus == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { _ in
                    Task { @MainActor in
                        self.refreshPermissions()
                    }
                }
            }
        }

        let timeLabel = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        microphoneGranted = currentMicGranted
        speechRecognitionGranted = currentSpeechGranted
        siriEnabled = currentSiriEnabled
        dictationEnabled = currentDictationEnabled
        lastPermissionCheckSummary =
            "마이크 \(currentMicGranted ? "켜짐" : "꺼짐") · 음성 전사 \(currentSpeechGranted ? "켜짐" : "꺼짐") · Siri \(currentSiriEnabled ? "켜짐" : "꺼짐") · 받아쓰기 \(currentDictationEnabled ? "켜짐" : "꺼짐") · 확인 시각 \(timeLabel)"

        if !currentMicGranted || !currentSpeechGranted || !currentSiriEnabled || !currentDictationEnabled {
            statusMessage = "Apple 기본 음성 권한이 부족합니다. 먼저 마이크, 음성 전사, Siri, 받아쓰기를 켜 주세요."
        } else if !isRecording {
            statusMessage = "Apple 기본 전사가 준비되었습니다. 음성 키를 한 번 누르면 시작되고, 다시 누르면 종료됩니다."
        }

        appendDiagnostic("permissions mic=\(currentMicGranted) speech=\(currentSpeechGranted) siri=\(currentSiriEnabled) dictation=\(currentDictationEnabled)")
    }

    // MARK: - 음성 키 이벤트 진입점(VoiceRelayService에서 호출)

    /// keyDown 시 호출: 길게 누르기 모드가 켜져 있으면 길게 누르기 타이머를 시작하고, 그렇지 않으면 즉시 녹음을 시작하거나 keyUp 전환을 기다립니다.
    func handleVoiceKeyDown() {
        if longPressEnabled, !isRecording {
            // 길게 누르기 타이머 시작: 임계값 내에 놓으면 → 짧게 누르기, 임계값을 넘겨도 누르고 있으면 → 길게 누르기 녹음 진입
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.longPressTimerWork = nil
                if !self.isRecording {
                    self.isLongPressRecording = true
                    self.startRecording()
                    self.appendDiagnostic("long press threshold reached → start long press recording")
                }
            }
            longPressTimerWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Double(longPressThresholdMs) / 1000,
                execute: work
            )
        } else if !longPressEnabled {
            // 길게 누르기 없음: keyDown에서 바로 전환(기존 동작 호환)
            toggleRecordingFromVoiceKey()
        }
        // longPressEnabled이면서 이미 녹음 중이면 keyDown에서는 아무것도 하지 않고 keyUp에서 판단
    }

    /// keyUp 시 호출: 길게 누르기 모드가 활성이면 → 종료하고 바로 전송, 그렇지 않으면 짧게 누르기로 전환합니다.
    func handleVoiceKeyUp() {
        if isLongPressRecording {
            // 길게 누르기 녹음 종료: 정지한 뒤 길게 누르기 설정에 따라 AhaType 사용 여부를 결정
            isLongPressRecording = false
            longPressTimerWork?.cancel()
            longPressTimerWork = nil
            appendDiagnostic("long press key up → stop + \(longPressAhaTypeEnabled ? "ahatype" : "direct")")
            stopRecording(bypassAhaType: !longPressAhaTypeEnabled)
            return
        }

        if let work = longPressTimerWork {
            // 타이머가 아직 발동하지 않음 → 짧게 누르기이므로 타이머를 취소하고 녹음을 전환
            work.cancel()
            longPressTimerWork = nil
            appendDiagnostic("short press (keyUp before threshold) → toggle")
            if isRecording {
                stopRecording(bypassAhaType: !shortPressAhaTypeEnabled)
            } else {
                startRecording()
            }
        } else if longPressEnabled, isRecording {
            // 길게 누르기 모드가 켜진 상태에서 첫 번째 짧게 누르기로 이미 토글 방식 녹음에 진입했고, 두 번째 짧게 누르기에는 timer가 없습니다.
            // 이때도 짧게 누르기 설정에 따라 녹음을 종료해 “한 번 누르면 시작, 다시 누르면 종료”라는 경험을 유지해야 합니다.
            appendDiagnostic("short press while recording → stop")
            stopRecording(bypassAhaType: !shortPressAhaTypeEnabled)
        } else if !longPressEnabled {
            // 길게 누르기 모드 없음: keyDown에서 이미 처리했으므로 keyUp에서는 반복하지 않음
        }
    }

    func toggleRecordingFromVoiceKey() {
        if isRecording {
            stopRecording(bypassAhaType: !shortPressAhaTypeEnabled)
        } else {
            startRecording()
        }
    }

    func stopRecording() {
        stopRecording(bypassAhaType: !shortPressAhaTypeEnabled)
    }

    func requestMicrophonePermission() {
        if Self.isMicrophoneUndetermined() {
            Self.requestMicrophoneAccess {
                Task { @MainActor in
                    self.refreshPermissions()
                    // macOS 26에서는 requestRecordPermission이 대화상자를 띄우지 않고 조용히 반환할 수 있습니다.
                    // completion이 돌아온 뒤에도 권한이 여전히 undetermined라면 시스템이 대화상자를 표시하지 않은 것이므로,
                    // 사용자를 시스템 설정으로 안내해 직접 켜도록 합니다.
                    if Self.isMicrophoneUndetermined() {
                        self.openMicrophoneSystemSettings()
                    }
                }
            }
        } else if Self.isMicrophoneDenied() {
            Task { @MainActor in
                self.attemptResetAndRequestMicrophonePermission()
            }
        } else {
            refreshPermissions()
        }
    }

    private func openMicrophoneSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    private func attemptResetAndRequestMicrophonePermission() {
        let alert = NSAlert()
        alert.messageText = "마이크 권한이 거부되었습니다"
        alert.informativeText = "다시 승인하려면 마이크 권한을 재설정해야 합니다."
        alert.addButton(withTitle: "재설정 후 승인")
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "취소")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            DispatchQueue.global(qos: .userInitiated).async {
                PermissionSignatureChecker.resetMicrophonePermission { success, message in
                    DispatchQueue.main.async {
                        if success {
                            // 재설정에 성공하면 바로 다시 요청합니다. TCC 기록이 비워졌으므로 재시작이 필요하지 않습니다
                            Self.requestMicrophoneAccess {
                                Task { @MainActor in
                                    self.refreshPermissions()
                                    // 대화상자가 나타나지 않으면(macOS 26에서 조용히 반환) 곧바로 시스템 설정을 엽니다
                                    if !Self.isMicrophoneGranted() {
                                        self.openMicrophoneSystemSettings()
                                    }
                                }
                            }
                        } else {
                            // tccutil 실패(SIP가 켜져 있으면 일반 프로세스에는 권한이 없음) 시 시스템 설정으로 안내
                            print("[NativeSpeech] tccutil reset failed: \(message)")
                            self.openMicrophoneSystemSettings()
                        }
                    }
                }
            }
        } else if response == .alertSecondButtonReturn {
            openMicrophoneSystemSettings()
        }
    }

    func requestSpeechRecognitionPermission() {
        let status = SFSpeechRecognizer.authorizationStatus()
        appendDiagnostic("requestSpeechRecognitionPermission status=\(status.rawValue)")
        switch status {
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { _ in
                Task { @MainActor in
                    self.refreshPermissions()
                }
            }
        case .denied, .restricted:
            Task { @MainActor in
                self.attemptResetAndRequestSpeechRecognitionPermission()
            }
        default:
            refreshPermissions()
        }
    }

    private func attemptResetAndRequestSpeechRecognitionPermission() {
        let bundleId = Bundle.main.bundleIdentifier ?? "lab.jawa.ahakeyconfig"
        appendDiagnostic("attemptResetAndRequestSpeechRecognition bundleId=\(bundleId)")

        let alert = NSAlert()
        alert.messageText = "음성 인식 권한이 거부되었습니다"
        alert.informativeText = "계속하려면 음성 인식 권한을 재설정해야 합니다. 「재설정」을 누른 뒤 앱을 재시작해야 다시 승인할 수 있습니다."
        alert.addButton(withTitle: "재설정 후 재시작")
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "취소")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                task.arguments = ["reset", "SpeechRecognition", bundleId]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe
                do {
                    try task.run()
                    task.waitUntilExit()
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    print("[NativeSpeech] tccutil reset SpeechRecognition status=\(task.terminationStatus) output=\(output)")
                } catch {
                    print("[NativeSpeech] tccutil reset SpeechRecognition error=\(error.localizedDescription)")
                }
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        } else if response == .alertSecondButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func stopRecording(bypassAhaType: Bool) {
        guard isRecording else { return }
        isRecording = false
        statusMessage = "녹음을 종료하고 텍스트를 정리하는 중…"
        VoiceStatusHUDController.shared.show(.recognizing)
        pendingFinalizeBypassAhaType = bypassAhaType
        appendDiagnostic("stop recording requested bypassAhaType=\(bypassAhaType)")

        finalizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.finalizeCurrentTranscriptIfNeeded(reason: "timeout_finalize", bypassAhaType: bypassAhaType)
            }
        }
        finalizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
    }

    private func startRecording() {
        guard microphoneGranted, speechRecognitionGranted, siriEnabled, dictationEnabled else {
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            let speechStatus = SFSpeechRecognizer.authorizationStatus()
            refreshPermissions(requestIfNeeded: true)
            statusMessage = missingPermissionMessage(
                micStatus: micStatus,
                speechStatus: speechStatus,
                siriEnabled: siriEnabled,
                dictationEnabled: dictationEnabled
            )
            appendDiagnostic("blocked start recording micStatus=\(micStatus.rawValue) speechStatus=\(speechStatus.rawValue) siri=\(siriEnabled) dictation=\(dictationEnabled)")
            if !VoiceRelayService.shared.isPermissionOnboardingSuppressed {
                VoiceRelayService.shared.showsPermissionOnboarding = true
            }
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let recognizer = makeSpeechRecognizer() else {
            statusMessage = "현재 시스템 언어는 아직 Apple 기본 전사를 지원하지 않습니다."
            appendDiagnostic("speech recognizer unavailable")
            return
        }

        cancelRecognitionPipeline()
        currentTranscript = ""
        transcriptPreview = ""
        lastCommittedText = ""
        hasCommittedThisRecording = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            statusMessage = "마이크 녹음을 시작할 수 없습니다."
            appendDiagnostic("audio engine start failed: \(error.localizedDescription)")
            return
        }

        audioEngine = engine
        recognitionRequest = request
        isRecording = true
        statusMessage = "Apple 기본 전사로 녹음 중… 음성 키를 다시 누르면 종료됩니다."
        VoiceStatusHUDController.shared.show(.recording)
        appendDiagnostic("start recording locale=\(recognizer.locale.identifier)")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                self.handleRecognition(result: result, error: error)
            }
        }
    }

    /// 스트리밍 + 같은 녹음 구간에서 잠시 멈춘 뒤 이어 말하는 경우: 대부분의 프레임에서 `formattedString`은 「이 구간 녹음 시작부터 지금까지의 전체」입니다.  
    /// 두 개의 한국어 구간을 영어식 공백으로 잇거나, 「같은 문장의 재판정」과 「다음 구간의 전체 문장」을 모두 기존+신규로 억지로 붙이면 같은 내용이 여러 번 겹칩니다.  
    /// 종료 시 커밋: `hasCommittedThisRecording`도 함께 참고하세요.
    private func applyStreamingTranscriptionPartial(_ newRaw: String) {
        let newT = newRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if newT.isEmpty { return }

        let oldT = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldT.isEmpty {
            currentTranscript = newT
            return
        }
        if newT == oldT { return }
        if newT.hasPrefix(oldT) {
            currentTranscript = newT
            return
        }
        if oldT.hasPrefix(newT) {
            return
        }
        if newT.contains(oldT), newT.count > oldT.count {
            currentTranscript = newT
            return
        }
        if oldT.contains(newT) {
            return
        }
        if let merged = Self.mergeByTailHeadOverlap(prior: oldT, next: newT) {
            currentTranscript = merged
            return
        }
        if Self.commonPrefixLength(oldT, newT) >= 3 {
            currentTranscript = newT
            return
        }
        if newT.count <= 6, let a = oldT.last, let b = newT.first, Self.isCJK(a), Self.isCJK(b) {
            currentTranscript = oldT + newT
            return
        }
        if let last = oldT.last, last == "。" || last == "！" || last == "？" {
            if let b = newT.first, Self.isCJK(b) {
                currentTranscript = oldT + newT
                return
            }
        }
        // 긴 문자열을 무작정 이어 붙이지 않고, 이번 전체 구간 가설을 기준으로 삼습니다
        currentTranscript = newT
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a, b) {
            if x == y { n += 1 } else { break }
        }
        return n
    }

    private static func mergeByTailHeadOverlap(prior: String, next: String) -> String? {
        if prior.isEmpty { return next }
        if next.isEmpty { return prior }
        let maxK = min(prior.count, next.count)
        guard maxK > 0 else { return nil }
        for k in stride(from: maxK, through: 1, by: -1) {
            if String(prior.suffix(k)) == String(next.prefix(k)) {
                return prior + next.dropFirst(k)
            }
        }
        return nil
    }

    private static func isCJK(_ ch: Character) -> Bool {
        for s in ch.unicodeScalars {
            let v = s.value
            if (0x4E00 ... 0x9FFF).contains(v) { return true }
            if (0x3400 ... 0x4DBF).contains(v) { return true }
            if (0x3000 ... 0x303F).contains(v) { return true }
        }
        return false
    }

    private var pendingFinalizeBypassAhaType = false

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let newText = result.bestTranscription.formattedString
            // 스트리밍 결과: 같은 문장은 접두사 형태로 길어지므로 new를 그대로 쓰면 됩니다. 다만 중간에 멈추면
            // 시스템이 새 구간의 텍스트만(앞 문장 없이) 반환할 수 있어, 전체를 그대로 대입하면 앞 문장이 사라집니다 —
            // 접두사 관계에 따라 병합하고, 그렇지 않으면 이어 붙여야 합니다.
            if !newText.isEmpty {
                applyStreamingTranscriptionPartial(newText)
                transcriptPreview = currentTranscript
            }
            appendDiagnostic("partial result=\(newText) isFinal=\(result.isFinal)")
            if result.isFinal {
                finalizeCurrentTranscriptIfNeeded(reason: "final_result", bypassAhaType: pendingFinalizeBypassAhaType)
                return
            }
        }

        if let error {
            appendDiagnostic("recognition error: \(error.localizedDescription)")
            if !currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalizeCurrentTranscriptIfNeeded(reason: "error_with_text", bypassAhaType: pendingFinalizeBypassAhaType)
            } else {
                cancelRecognitionPipeline()
                statusMessage = "Apple 기본 전사 실패: \(error.localizedDescription)"
                VoiceStatusHUDController.shared.show(
                    VoiceStatusHUDState(kind: .warning, title: "인식 실패", subtitle: "다시 시도하거나 음성 권한을 확인하세요"),
                    autoHideAfter: 2.0
                )
            }
        }
    }

    private func finalizeCurrentTranscriptIfNeeded(reason: String, bypassAhaType: Bool = false) {
        finalizeWorkItem?.cancel()
        finalizeWorkItem = nil

        if hasCommittedThisRecording {
            appendDiagnostic("skip duplicate finalize reason=\(reason)")
            return
        }

        let text = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelRecognitionPipeline()

        guard !text.isEmpty else {
            statusMessage = "유효한 음성 내용을 인식하지 못했습니다."
            VoiceStatusHUDController.shared.show(.empty, autoHideAfter: 1.8)
            appendDiagnostic("finalize empty reason=\(reason)")
            return
        }

        hasCommittedThisRecording = true
        let willUseAhaType = !bypassAhaType && AhaTypeTextOptimizer.shared.isEnabled
        statusMessage = willUseAhaType ? "AhaType 정리 중…" : "붙여넣기 준비 중…"
        VoiceStatusHUDController.shared.show(willUseAhaType ? .ahaType : .pasting)
        appendDiagnostic("finalize begin reason=\(reason) bypass=\(bypassAhaType) rawText=\(text)")

        Task { @MainActor in
            let output: String
            if willUseAhaType {
                output = await AhaTypeTextOptimizer.shared.processIfEnabled(text)
            } else {
                output = text
            }
            if self.injectText(output) {
                self.lastCommittedText = output
                self.statusMessage = output == text ? "입력 완료: \(output)" : "AhaType이 정리하여 입력했습니다: \(output)"
                VoiceStatusHUDController.shared.show(.done, autoHideAfter: 1.4)
                self.appendDiagnostic("finalize success reason=\(reason) rawText=\(text) outputText=\(output)")
            } else {
                self.statusMessage = "인식은 완료했지만 현재 커서 위치에 입력하지 못했습니다."
                VoiceStatusHUDController.shared.show(.failed, autoHideAfter: 2.0)
                self.appendDiagnostic("finalize inject failed reason=\(reason) text=\(output)")
            }
        }
    }

    private func cancelRecognitionPipeline() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
    }

    private func makeSpeechRecognizer() -> SFSpeechRecognizer? {
        if let preferredIdentifier = Locale.preferredLanguages.first {
            let locale = Locale(identifier: preferredIdentifier)
            if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable {
                return recognizer
            }
        }

        if let recognizer = SFSpeechRecognizer(), recognizer.isAvailable {
            return recognizer
        }

        return nil
    }

    private func missingPermissionMessage(
        micStatus: AVAuthorizationStatus,
        speechStatus: SFSpeechRecognizerAuthorizationStatus,
        siriEnabled: Bool,
        dictationEnabled: Bool
    ) -> String {
        var missing: [String] = []
        if micStatus != .authorized {
            missing.append("마이크")
        }
        if speechStatus != .authorized {
            missing.append("음성 전사")
        }
        if !siriEnabled {
            missing.append("Siri")
        }
        if !dictationEnabled {
            missing.append("받아쓰기")
        }
        return "\(missing.joined(separator: ", ")) 권한이 없습니다. 먼저 시스템 설정에서 켠 뒤 음성 키를 다시 눌러 주세요."
    }

    // MARK: - 마이크 권한 보조(macOS 14+에서는 AVAudioApplication 사용, 이전 시스템은 AVCaptureDevice로 폴백)

    private static func isMicrophoneGranted() -> Bool {
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    private static func isMicrophoneUndetermined() -> Bool {
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .undetermined
        } else {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        }
    }

    private static func isMicrophoneDenied() -> Bool {
        if #available(macOS 14.0, *) {
            let p = AVAudioApplication.shared.recordPermission
            return p == .denied
        } else {
            let s = AVCaptureDevice.authorizationStatus(for: .audio)
            return s == .denied || s == .restricted
        }
    }

    private static func requestMicrophoneAccess(completion: @escaping () -> Void) {
        if #available(macOS 14.0, *) {
            AVAudioApplication.requestRecordPermission { _ in completion() }
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in completion() }
        }
    }

    private static func readBooleanPreference(domain: String, key: String) -> Bool? {
        guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else {
            return nil
        }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private func injectText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard CGPreflightPostEventAccess() else {
            appendDiagnostic("inject denied: no post event access")
            return false
        }

        // 클립보드 + ⌘V 방식을 사용합니다.
        // Electron / Chromium 앱(Cursor, VS Code, Slack 등)은
        // CGEvent.keyboardSetUnicodeString으로 합성한 Unicode 키보드 이벤트를 삼켜 버리므로,
        // 표준 붙여넣기 경로가 더 범용적이고 안정적입니다. 붙여넣기가 끝나면 원래 클립보드 내용을 복원합니다.
        if injectViaPaste(text: text) {
            return true
        }

        // 이론적으로는 여기까지 오지 않습니다 —— Unicode-synthesis를 last-resort fallback으로 남겨 둡니다.
        appendDiagnostic("inject fallback to unicode-synthesis")
        for scalar in text.utf16 {
            var unit = scalar
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                return false
            }

            withUnsafePointer(to: &unit) { pointer in
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: pointer)
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: pointer)
            }

            down.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
            up.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(5_000)
        }

        return true
    }

    /// NSPasteboard + 합성 ⌘V 방식으로 `text`를 현재 포커스 위치에 주입합니다.
    /// true를 반환하면 붙여넣기 이벤트를 전달했다는 뜻이며, 이후 비동기로 원래 클립보드 내용을 복원합니다.
    private func injectViaPaste(text: String) -> Bool {
        let pasteboard = NSPasteboard.general

        // 현재 클립보드 백업(모든 유형의 데이터를 보존해 이미지/서식 있는 텍스트도 호환)
        var backup: [(NSPasteboard.PasteboardType, Data)] = []
        if let types = pasteboard.types {
            for type in types {
                if let data = pasteboard.data(forType: type) {
                    backup.append((type, data))
                }
            }
        }

        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        guard wrote else {
            appendDiagnostic("paste inject failed: pasteboard setString returned false")
            restorePasteboard(backup: backup)
            return false
        }

        // ⌘V 합성 —— virtualKey 0x09 = V(kVK_ANSI_V)
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            appendDiagnostic("paste inject failed: cannot create CGEvent")
            restorePasteboard(backup: backup)
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        appendDiagnostic("paste inject posted ⌘V for text.count=\(text.count)")

        // 대상 앱이 붙여넣기 이벤트를 소비할 시간을 충분히 준 뒤 클립보드를 복원
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.restorePasteboard(backup: backup)
        }

        return true
    }

    private func restorePasteboard(backup: [(NSPasteboard.PasteboardType, Data)]) {
        guard !backup.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        for (type, data) in backup {
            pb.setData(data, forType: type)
        }
    }

    private func appendDiagnostic(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let url = diagnosticLogURL

        Task.detached {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try Data(line.utf8).write(to: url)
                } else {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(line.utf8))
                    try handle.close()
                }
            } catch {
                // ignore diagnostics write errors
            }
        }
    }

    private var diagnosticLogURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AhaKeyConfig/diagnostics", isDirectory: true)
        return directory.appendingPathComponent("native-speech.log")
    }
}
