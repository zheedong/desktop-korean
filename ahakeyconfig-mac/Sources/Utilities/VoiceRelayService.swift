import AppKit
import ApplicationServices
import Carbon
import Combine
import CoreGraphics
import Foundation
import os.log

private let voiceRelayLog = Logger(subsystem: "lab.jawa.ahakeyconfig", category: "VoiceRelay")

private struct VoiceTriggerBinding: Hashable {
    let keyCode: CGKeyCode
    let modifiers: Set<ShortcutModifier>

    var displayLabel: String {
        let modifierLabel = ShortcutModifier.displayOrder
            .filter { modifiers.contains($0) }
            .map(\.symbol)
            .joined()
        return modifierLabel + macKeyName(for: keyCode)
    }
}

private enum VoiceRouteAction: Hashable {
    case macOSDictation
    case functionRelay(appName: String)
    case doubaoPassThrough

    var title: String {
        switch self {
        case .macOSDictation:
            "macOS 기본 음성"
        case let .functionRelay(appName):
            appName
        case .doubaoPassThrough:
            "더우바오 입력기"
        }
    }

    var isFunctionRelay: Bool {
        if case .functionRelay = self { return true }
        return false
    }
}

private struct VoiceRoute: Hashable {
    let binding: VoiceTriggerBinding
    let action: VoiceRouteAction
    let mode: AhaKeyModeSlot
    let compatibilityLabel: String?
}

final class VoiceRelayService: ObservableObject {
    static let shared = VoiceRelayService()

    @Published private(set) var isListening = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var statusMessage = "음성 라우팅 초기화를 기다리는 중입니다."
    @Published private(set) var activeRouteSummary = "음성 소프트웨어가 설정되지 않았습니다."
    @Published var showsPermissionOnboarding = false
    @Published private(set) var lastPermissionCheckSummary = "권한을 아직 확인하지 않았습니다."
    @Published private(set) var lastInspectorSimulateHint: String?

    private let routeQueue = DispatchQueue(label: "lab.jawa.ahakeyconfig.voiceRelay.routes")
    private var routes: [VoiceRoute] = []
    /// 키보드의 물리 단계와 일치하며, 여러 Mode가 같은 트리거 키(예: F18 / F19)를 공유할 때 올바른 라우트를 고르는 데 사용합니다.
    private var keyboardWorkMode: AhaKeyModeSlot = .mode0

    /// NSEvent.addGlobalMonitor가 아니라 CGEventTap을 사용합니다. CGEventTap만이 키보드 이벤트를 실제로
    /// "삼켜서" 하드웨어 음성 키가 전면 App으로 새어 나가는 것을 막을 수 있기 때문입니다(예: Claude Code CLI / iTerm 같은 터미널은
    /// F17/F18을 xterm CSI 이스케이프 시퀀스로 번역해, 사용자에게는 "깨진 문자"로 보입니다).
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var suppressPermissionOnboardingUntil: Date?

    private var shadowSuppressUntil: TimeInterval = 0

    /// route.action이 .functionRelay일 때 「Fn/Globe 누르고 있기」를 시뮬레이션하는 데 사용합니다. 트리거 키는 F18/F19 등이 될 수 있고, 물리 키의 keyDown/keyUp을 그대로 따라갑니다.
    private var holdingRoute: VoiceRoute?
    /// 하드웨어 음성 키는 보통 아주 짧은 펄스입니다(down/up 간격이 몇 밀리초). 곧바로 Fn up을 따라 보내면 Typeless/위챗이 「누르고 말하기」에 진입할 시간이 부족한 경우가 많습니다. 최소 「물리 누름 시간」을 충족한 뒤에 Fn up을 보냅니다(길게 누른 경우에는 여전히 즉시 따라갑니다).
    private var functionRelayKeyDownUptime: TimeInterval?
    private var pendingFnReleaseWorkItem: DispatchWorkItem?
    /// 아직 짝이 맞지 않은 Fn keyDown을 시스템에 이미 보냈는지 여부(짧은 펄스에서 지연된 release를 취소한 뒤 keyDown이 중복되는 것을 방지).
    private var syntheticFnRelayHeld: Bool = false

    private let syntheticEventUserData: Int64 = 0x4148414B
    private let fnKeyCode: CGKeyCode = 63
    private let emojiShadowKeyCode: CGKeyCode = 179
    private let shadowSuppressSeconds: TimeInterval = 0.06
    /// 물리 누름이 이 값보다 짧으면, Fn keyUp을 전체 구간이 이 시간 이상이 되도록 지연시킵니다(IME가 「누르고 말하기」를 시작하려면 합성 Fn이 더 길어야 하는 경우가 많습니다).
    private let minFunctionRelayPhysicalHoldSeconds: TimeInterval = 0.45

    private init() {
        NotificationCenter.default.addObserver(
            forName: .ahaKeyKeyboardWorkModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let raw = note.userInfo?["workMode"] as? Int else { return }
            let slot = AhaKeyModeSlot(rawValue: raw) ?? .mode0
            self.routeQueue.async {
                self.keyboardWorkMode = slot
            }
            self.appendDiagnostic("keyboard work mode (hardware) → \(slot.rawValue) (\(slot.name))")
        }
    }

    // MARK: - Public

    func start() {
        refreshPermissions(requestIfNeeded: false)
    }

    /// - Parameter deferredTCCRequery: 사용자가 「다시 확인」을 누를 때 true로 설정합니다. Preflight만 쓰면 시스템 설정을 막 변경하고 이 App에 머물러 있을 때 여전히 이전 값을 읽을 수 있으므로, 잠시 뒤 Request API로 한 번 더 읽고 대기 시간을 조금 늘립니다.
    func refreshPermissions(requestIfNeeded: Bool = false, deferredTCCRequery: Bool = false) {
        if requestIfNeeded {
            if Thread.isMainThread {
                performPermissionRead(requestIfNeeded: true)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.performPermissionRead(requestIfNeeded: true)
                }
            }
            return
        }
        if deferredTCCRequery {
            DispatchQueue.main.async {
                self.lastPermissionCheckSummary = "시스템 권한을 확인하는 중…"
            }
            let firstDelay: TimeInterval = 0.45
            let followUpDelay: TimeInterval = 0.85
            DispatchQueue.main.asyncAfter(deadline: .now() + firstDelay) { [weak self] in
                guard let self else { return }
                self.performPermissionRead(requestIfNeeded: false, preferRequestAPI: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + followUpDelay) { [weak self] in
                    guard let self else { return }
                    if !self.inputMonitoringGranted || !self.accessibilityGranted {
                        self.performPermissionRead(requestIfNeeded: false, preferRequestAPI: true)
                        self.appendDiagnostic("permissions follow-up recheck (after system settings)")
                    }
                }
            }
            return
        }
        performPermissionRead(requestIfNeeded: false)
    }

    private func performPermissionRead(requestIfNeeded: Bool, preferRequestAPI: Bool = false) {
        let inputMonitoring: Bool
        let postEventAccess: Bool
        if requestIfNeeded || preferRequestAPI {
            // Request는 현재 TCC 판정을 따릅니다. 사용자가 「개인정보 보호 및 보안」에서 막 돌아온 직후에는 Preflight가 잠시 false로 남아 있을 수 있습니다.
            inputMonitoring = CGRequestListenEventAccess()
            postEventAccess = CGRequestPostEventAccess()
        } else {
            inputMonitoring = CGPreflightListenEventAccess()
            postEventAccess = CGPreflightPostEventAccess()
        }

        let accessibility: Bool
        if requestIfNeeded {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            accessibility = AXIsProcessTrustedWithOptions(options)
        } else {
            accessibility = AXIsProcessTrusted()
        }

        let timeLabel = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let lastCheckSummary =
            "입력 모니터링 \(inputMonitoring ? "켜짐" : "꺼짐") · 손쉬운 사용 \((accessibility && postEventAccess) ? "켜짐" : "꺼짐") · 확인 시각 \(timeLabel)"

        DispatchQueue.main.async {
            self.inputMonitoringGranted = inputMonitoring
            self.accessibilityGranted = accessibility && postEventAccess
            self.lastPermissionCheckSummary = lastCheckSummary
            self.showsPermissionOnboarding = !(inputMonitoring && accessibility && postEventAccess) && !self.isPermissionOnboardingSuppressed
            self.refreshStatusMessage()
        }

        let exePath = Bundle.main.executablePath ?? "unknown"
        let bundleID = Bundle.main.bundleIdentifier ?? "none"
        appendDiagnostic("permissions inputMonitoring=\(inputMonitoring) accessibility=\(accessibility) postEvent=\(postEventAccess) exe=\(exePath) bundle=\(bundleID)")

        if inputMonitoring && accessibility && postEventAccess {
            DispatchQueue.main.async {
                self.ensureMonitorsIfPossible()
            }
        } else {
            DispatchQueue.main.async {
                self.stopMonitors()
            }
        }
    }

    func dismissPermissionOnboarding() {
        showsPermissionOnboarding = false
    }

    func requestInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
        performPermissionRead(requestIfNeeded: false, preferRequestAPI: true)
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        performPermissionRead(requestIfNeeded: false, preferRequestAPI: true)
    }

    func suppressPermissionOnboarding(for seconds: TimeInterval = 4.0) {
        suppressPermissionOnboardingUntil = Date().addingTimeInterval(seconds)
        showsPermissionOnboarding = false
    }

    var isPermissionOnboardingSuppressed: Bool {
        if let until = suppressPermissionOnboardingUntil, until > Date() {
            return true
        }
        suppressPermissionOnboardingUntil = nil
        return false
    }

    /// Inspector 디버깅: 현재 모드에서 실물 음성 키를 한 번 누른 것을 시뮬레이션합니다(Fn/Globe = Fn 누름 상태 전환, macOS 기본 = 시스템 전사 전환).
    func simulateInspectorVoiceKeyTap(for mode: AhaKeyModeSlot) {
        let route: VoiceRoute? = routeQueue.sync {
            routes.first { $0.mode == mode }
        }
        guard let route else {
            appendDiagnostic("inspector simulate: no route for mode=\(mode.rawValue)")
            Task { @MainActor in
                lastInspectorSimulateHint = "현재 모드에 음성 라우트가 없습니다. Fn은 Fn/Globe를 선택하거나 「사용자 지정 단축키」를 F19로 설정하세요."
            }
            return
        }
        switch route.action {
        case .macOSDictation:
            Task { @MainActor in
                NativeSpeechTranscriptionService.shared.toggleRecordingFromVoiceKey()
                lastInspectorSimulateHint = "「Apple 기본 전사」의 녹음 상태를 전환했습니다(화면의 「녹음 시작」과 동일)."
            }
        case .functionRelay:
            toggleFunctionRelayHold(for: route)
            Task { @MainActor in
                lastInspectorSimulateHint = "Fn 누름 상태를 전환했습니다. Typeless/위챗 음성/더우바오 입력기에서 단축키를 Fn/Globe로 설정하세요(이 Studio는 F19를 감지하며, 구버전 F18도 호환됩니다). 다시 누르면 놓입니다."
            }
        case .doubaoPassThrough:
            configureDoubaoVoiceShortcutIfNeeded()
            ensureInputSource(id: Self.doubaoInputSourceID, label: route.action.title)
            Task { @MainActor in
                lastInspectorSimulateHint = "더우바오는 실제 F18 길게 누르기 이벤트가 필요합니다. 더우바오 입력 소스로 전환하고 F18 길게 누르기를 설정했으니 실물 음성 키로 테스트하세요."
            }
        }
        appendDiagnostic("inspector simulate mode=\(mode.rawValue) action=\(route.action.title)")
    }

    func updateRoutes(from draft: AhaKeyStudioDraft) {
        let builtRoutes = Self.buildRoutes(from: draft)
        let needsDoubaoPreparation = builtRoutes.contains { $0.action == .doubaoPassThrough }

        // 라우트 집합이 실제로 변경될 때만 "누름" 상태를 해제해, SwiftUI의 빈번한 재생성이나 무관한 onChange가
        // functionRelay의 hold 상태를 간접적으로 지워 버리는 것을 방지합니다(대표 증상: 위챗에서 누르고 말하기가 몇 초 뒤 자동 종료).
        let routesChanged: Bool = routeQueue.sync { self.routes != builtRoutes }
        if routesChanged {
            releaseFunctionRelayHoldIfNeeded()
        }

        routeQueue.async {
            self.routes = builtRoutes
            let summary = builtRoutes.isEmpty
                ? "음성 소프트웨어가 설정되지 않았습니다."
                : builtRoutes.map { route in
                    let fallback = route.compatibilityLabel.map { " · \($0)" } ?? ""
                    return "\(route.mode.title) \(route.action.title) ← \(route.binding.displayLabel)\(fallback)"
                }.joined(separator: " / ")

            DispatchQueue.main.async {
                self.activeRouteSummary = summary
                self.refreshStatusMessage()
            }
        }

        if needsDoubaoPreparation {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configureDoubaoVoiceShortcutIfNeeded()
                self.ensureInputSource(id: Self.doubaoInputSourceID, label: "더우바오 입력기")
            }
        }
    }

    // MARK: - Event Monitoring (CGEventTap)

    private func ensureMonitorsIfPossible() {
        guard eventTap == nil else {
            isListening = true
            refreshStatusMessage()
            return
        }

        guard inputMonitoringGranted, accessibilityGranted else {
            isListening = false
            refreshStatusMessage()
            return
        }

        // keyDown / keyUp만 관찰합니다. voice key는 모두 modifier가 아닌 키로 매핑되므로 flagsChanged는 필요하지 않습니다.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, cgEvent, refcon in
            guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
            let service = Unmanaged<VoiceRelayService>.fromOpaque(refcon).takeUnretainedValue()
            return service.handleTappedEvent(type: type, event: cgEvent)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            appendDiagnostic("event tap create failed (손쉬운 사용 또는 입력 모니터링 권한 없음?)")
            isListening = false
            refreshStatusMessage()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        isListening = true
        appendDiagnostic("cg event tap started")
        voiceRelayLog.info("Voice relay CG event tap started")
        refreshStatusMessage()
    }

    private func stopMonitors() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.runLoopSource = nil
        }
        releaseFunctionRelayHoldIfNeeded()
        isListening = false
        appendDiagnostic("cg event tap stopped")
        refreshStatusMessage()
    }

    /// CGEventTap 콜백. `nil`을 반환하면 이벤트를 삼킨다는 뜻(전면 App에 도달하지 못하게 함)이고, passUnretained를
    /// 반환하면 통과시킨다는 뜻입니다. 일반 키를 잘못 잡아먹지 않도록, route에 성공적으로 match된 경우에만 삼켜야 합니다.
    private func handleTappedEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 1. 처리가 너무 오래 걸려 시스템이 tap을 일시적으로 비활성화했을 수 있으므로, 여기서 다시 활성화합니다.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                appendDiagnostic("cg event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            }
            return Unmanaged.passUnretained(event)
        }

        // 2. 직접 합성한 이벤트(functionRelay가 주입한 Fn)는 반드시 통과시켜야 합니다. 그러지 않으면 무한 루프에 빠집니다.
        if event.getIntegerValueField(.eventSourceUserData) == syntheticEventUserData {
            return Unmanaged.passUnretained(event)
        }

        // 3. keyDown / keyUp만 처리하고, 다른 유형은 그대로 통과시킵니다.
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = normalizedModifierSet(from: event.flags)

        // 4. 이모지 패널 그림자 키 179 억제: Fn을 주입하면 macOS가 그림자 keyDown을 함께 보내므로,
        //    이를 삼켜 이모지 패널이 깜빡이는 것을 방지합니다.
        let now = Date().timeIntervalSinceReferenceDate
        if keyCode == emojiShadowKeyCode,
           now <= routeQueue.sync(execute: { shadowSuppressUntil })
        {
            appendDiagnostic("shadow suppress keyCode=\(keyCode) type=\(type.rawValue)")
            return nil
        }

        // 5. 음성 라우트를 매칭합니다. 일치하지 않으면 모두 통과시킵니다.
        guard let route = matchingRoute(forKeyCode: keyCode, flags: flags) else {
            return Unmanaged.passUnretained(event)
        }

        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        appendDiagnostic("matched keyCode=\(keyCode) type=\(type.rawValue) autorepeat=\(isAutoRepeat) route=\(route.action.title) mode=\(route.mode.rawValue)")

        switch route.action {
        case .macOSDictation:
            if isAutoRepeat { return nil }
            if type == .keyDown {
                Task { @MainActor in
                    NativeSpeechTranscriptionService.shared.handleVoiceKeyDown()
                }
            } else if type == .keyUp {
                Task { @MainActor in
                    NativeSpeechTranscriptionService.shared.handleVoiceKeyUp()
                }
            }
            // keyDown/keyUp을 모두 삼켜 하드웨어가 보낸 F17/F18이 전면 App으로 새어 나가지 않게 합니다(예: Claude CLI가
            // 실행 중인 터미널은 이를 \e[...~ 같은 문자로 번역합니다).
            return nil

        case .doubaoPassThrough:
            if type == .keyDown, !isAutoRepeat {
                configureDoubaoVoiceShortcutIfNeeded()
                ensureInputSource(id: Self.doubaoInputSourceID, label: route.action.title)
                appendDiagnostic("doubao pass-through keyDown → let physical event reach IME")
            } else if type == .keyUp {
                appendDiagnostic("doubao pass-through keyUp → let physical event reach IME")
            }
            return Unmanaged.passUnretained(event)

        case .functionRelay:
            // 위챗 / Typeless의 「누르고 말하기」와 동일하게: 하드웨어 keyDown을 그대로 따라가고, keyUp이 너무 이르면 Fn 누름을 조금 연장해 펄스 키가 무반응이 되는 것을 방지합니다.
            if isAutoRepeat {
                return nil
            }
            if type == .keyDown {
                routeQueue.sync {
                    cancelPendingFnReleaseLocked()
                    if holdingRoute != nil { return }
                    holdingRoute = route
                    functionRelayKeyDownUptime = ProcessInfo.processInfo.systemUptime
                    if !syntheticFnRelayHeld {
                        postFunctionKey(isKeyDown: true)
                        syntheticFnRelayHeld = true
                        appendDiagnostic("function relay keyDown → hold (\(route.action.title))")
                    } else {
                        appendDiagnostic("function relay keyDown → hold (already Fn down, \(route.action.title))")
                    }
                }
            } else if type == .keyUp {
                let releasePlan: (title: String, delay: TimeInterval, elapsed: TimeInterval)? = routeQueue.sync {
                    cancelPendingFnReleaseLocked()
                    guard holdingRoute == route else { return nil }
                    holdingRoute = nil
                    let downUptime = functionRelayKeyDownUptime ?? ProcessInfo.processInfo.systemUptime
                    functionRelayKeyDownUptime = nil
                    let elapsed = ProcessInfo.processInfo.systemUptime - downUptime
                    let delay = max(0, minFunctionRelayPhysicalHoldSeconds - elapsed)
                    return (route.action.title, delay, elapsed)
                }
                guard let releasePlan else { return nil }
                if releasePlan.delay < 0.001 {
                    routeQueue.sync { syntheticFnRelayHeld = false }
                    postFunctionKey(isKeyDown: false)
                    appendDiagnostic("function relay keyUp → release (\(releasePlan.title))")
                } else {
                    appendDiagnostic(
                        "function relay keyUp → schedule Fn release in \(String(format: "%.3f", releasePlan.delay))s (\(releasePlan.title), physical_down=\(String(format: "%.3f", releasePlan.elapsed))s)"
                    )
                    let title = releasePlan.title
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.postFunctionKey(isKeyDown: false)
                        // 이미 routeQueue에서 실행 중이므로 routeQueue.sync를 다시 호출하면 안 됩니다. 같은 큐에 중첩되면 데드락이 발생하고 디버깅 시 EXC_BREAKPOINT가 납니다.
                        self.syntheticFnRelayHeld = false
                        self.pendingFnReleaseWorkItem = nil
                        self.appendDiagnostic("function relay delayed Fn release (\(title))")
                    }
                    routeQueue.sync {
                        pendingFnReleaseWorkItem = work
                    }
                    routeQueue.asyncAfter(deadline: .now() + releasePlan.delay, execute: work)
                }
            }
            return nil
        }
    }

    private func cancelPendingFnReleaseLocked() {
        pendingFnReleaseWorkItem?.cancel()
        pendingFnReleaseWorkItem = nil
    }

    private func toggleFunctionRelayHold(for route: VoiceRoute) {
        routeQueue.sync {
            cancelPendingFnReleaseLocked()
        }
        let shouldRelease: Bool = routeQueue.sync {
            if holdingRoute != nil || syntheticFnRelayHeld {
                holdingRoute = nil
                functionRelayKeyDownUptime = nil
                return true
            } else {
                holdingRoute = route
                return false
            }
        }
        if shouldRelease {
            postFunctionKey(isKeyDown: false)
            routeQueue.sync { syntheticFnRelayHeld = false }
            appendDiagnostic("function relay toggle → release (\(route.action.title))")
        } else {
            postFunctionKey(isKeyDown: true)
            routeQueue.sync { syntheticFnRelayHeld = true }
            appendDiagnostic("function relay toggle → hold (\(route.action.title))")
        }
    }

    /// 서비스가 감지를 멈추거나 라우트가 바뀌거나 권한이 무효화될 때, Fn 「누름」이 시스템 키보드에 걸린 채 남지 않도록 보장합니다.
    private func releaseFunctionRelayHoldIfNeeded() {
        let needsFnUp: Bool = routeQueue.sync {
            cancelPendingFnReleaseLocked()
            holdingRoute = nil
            functionRelayKeyDownUptime = nil
            let wasHeld = syntheticFnRelayHeld
            syntheticFnRelayHeld = false
            return wasHeld
        }
        if needsFnUp {
            postFunctionKey(isKeyDown: false)
            appendDiagnostic("function relay force release")
        }
    }

    private func matchingRoute(forKeyCode keyCode: CGKeyCode, flags: Set<ShortcutModifier>) -> VoiceRoute? {
        routeQueue.sync {
            let candidates = routes.filter { $0.binding.keyCode == keyCode && $0.binding.modifiers == flags }
            if candidates.isEmpty { return nil }
            if let hit = candidates.first(where: { $0.mode == keyboardWorkMode }) {
                return hit
            }
            return candidates.first
        }
    }

    // MARK: - Posting

    private func postFunctionKey(isKeyDown: Bool) {
        appendDiagnostic("post fn keyDown=\(isKeyDown)")
        let flags: CGEventFlags = isKeyDown ? .maskSecondaryFn : []
        postFnRelayKeyboardEvents(keyCode: fnKeyCode, keyDown: isKeyDown, flags: flags)
        routeQueue.async {
            self.shadowSuppressUntil = Date().timeIntervalSinceReferenceDate + self.shadowSuppressSeconds
        }
    }

    /// Typeless 같은 IME는 때때로 session 또는 HID 한쪽에서만 Fn을 온전히 받습니다. 두 경로로 각각 별도의 CGEvent를 보내 「Fn 길게 누르기」가 인식될 확률을 높입니다.
    private func postFnRelayKeyboardEvents(keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
        if let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .combinedSessionState),
            virtualKey: keyCode,
            keyDown: keyDown
        ) {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
            event.post(tap: .cgSessionEventTap)
        }
        if let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: keyCode,
            keyDown: keyDown
        ) {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
            event.post(tap: .cghidEventTap)
        }
    }

    private func ensureInputSource(id inputSourceID: String, label: String) {
        guard currentInputSourceID() != inputSourceID else { return }
        if selectInputSource(id: inputSourceID) {
            appendDiagnostic("input source selected id=\(inputSourceID) for \(label)")
        } else {
            appendDiagnostic("input source select failed id=\(inputSourceID) for \(label)")
        }
    }

    private func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return inputSourceID(from: source)
    }

    private func selectInputSource(id targetID: String) -> Bool {
        let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as NSArray
        for item in sources {
            let source = item as! TISInputSource
            guard inputSourceID(from: source) == targetID else { continue }
            return TISSelectInputSource(source) == noErr
        }
        return false
    }

    private func inputSourceID(from source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private func configureDoubaoVoiceShortcutIfNeeded() {
        let defaults = UserDefaults.standard
        var global = defaults.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        var changed = false

        func set(_ key: String, _ value: Any) {
            if !NSDictionary(dictionary: global).isEqual(to: [key: value]) && "\(global[key] ?? "")" != "\(value)" {
                global[key] = value
                changed = true
            }
        }

        set("isStartASRShortcutEnable", true)
        set("isGloableASRShortcutEnable", true)
        set("asrShortcutKeyCode", Int(Self.fnTriggerMacKeyCode))
        set("asrShortcutModifierFlags", 0)
        set("asrShortcutKeyDisplay", "F18")
        set("asrLongPressShortcutKeyCode", Int(Self.fnTriggerMacKeyCode))
        set("asrLongPressShortcutModifierFlags", 0)
        set("asrLongPressShortcutKeyDisplay", "F18")

        if changed {
            defaults.setPersistentDomain(global, forName: UserDefaults.globalDomain)
            defaults.synchronize()
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("DoubaoImeSettings.asrLongPressShortcutKeyNotification"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("DoubaoImeSettings.enableStartASRShortcutNotification"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("DoubaoImeSettings.enableGloableASRShortcutNotification"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            appendDiagnostic("doubao shortcut configured: longPress F18")
        }
    }

    // MARK: - Helpers

    private func refreshStatusMessage() {
        if !inputMonitoringGranted || !accessibilityGranted {
            statusMessage = "시스템 권한이 부족합니다. AhaKey Studio에 “입력 모니터링”과 “손쉬운 사용”을 허용한 뒤, 앱으로 돌아와 “권한 다시 확인”을 눌러 주세요."
            return
        }

        guard isListening else {
            statusMessage = "음성 키 백그라운드 감지를 준비하는 중입니다. 창을 닫아도 AhaKey Studio는 백그라운드에 계속 상주합니다."
            return
        }

        if activeRouteSummary == "음성 소프트웨어가 설정되지 않았습니다." {
            statusMessage = "백그라운드 감지가 시작되었지만 현재 연동할 수 있는 음성 소프트웨어가 없습니다."
            return
        }

        statusMessage = "백그라운드 감지가 시작되었습니다. Fn/Globe 음성은 F19를 사용하며, macOS 기본과 구버전 F18도 계속 호환됩니다."
    }

    private static func buildRoutes(from draft: AhaKeyStudioDraft) -> [VoiceRoute] {
        var orderedRoutes: [VoiceRoute] = []
        let factoryF18 = VoiceTriggerBinding(keyCode: 79, modifiers: [])
        let fnF19 = VoiceTriggerBinding(keyCode: 80, modifiers: [])

        for mode in AhaKeyModeSlot.allCases {
            let voiceKey = draft.draft(for: mode).key(for: .voice)
            guard let preset = voiceKey.voicePreset,
                  preset.availableInV1,
                  let action = action(for: preset, shortcut: voiceKey.shortcut),
                  let binding = macBinding(for: voiceKey.shortcut)
            else { continue }

            orderedRoutes.append(
                VoiceRoute(
                    binding: binding,
                    action: action,
                    mode: mode,
                    compatibilityLabel: nil
                )
            )

            if action.isFunctionRelay, binding != fnF19 {
                orderedRoutes.append(
                    VoiceRoute(
                        binding: fnF19,
                        action: action,
                        mode: mode,
                        compatibilityLabel: "Fn F19 호환"
                    )
                )
            }

            if mode == .mode0, binding != factoryF18 {
                orderedRoutes.append(
                    VoiceRoute(
                        binding: factoryF18,
                        action: action,
                        mode: .mode0,
                        compatibilityLabel: "구버전 F18 호환"
                    )
                )
            }
        }

        return orderedRoutes
    }

    private static func action(for preset: VoicePreset, shortcut: ShortcutBinding) -> VoiceRouteAction? {
        switch preset {
        case .macOSNative:
            .macOSDictation
        case .typeless:
            .functionRelay(appName: "Fn/Globe")
        case .wechat:
            .functionRelay(appName: "Fn/Globe")
        case .claudeCode:
            // Claude Code preset은 macOS 기본 ASR을 재사용합니다: 녹음 → 인식 → ⌘V로 현재 커서에 붙여넣기.
            // 이렇게 하면 키 입력이 우리 monitor에서 소비되어 Claude CLI 터미널로 새어 나가 CSI 깨진 문자가 되지 않습니다.
            .macOSDictation
        case .kimiCode:
            .macOSDictation
        case .doubao:
            .functionRelay(appName: "Fn/Globe")
        case .custom:
            shortcut.keyCode == HIDUsage.f19 && shortcut.modifiers.isEmpty
                ? .functionRelay(appName: "Fn / Globe")
                : nil
        case .codex:
            nil
        }
    }

    private static let doubaoInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
    private static let fnTriggerMacKeyCode: CGKeyCode = 79

    private func appendDiagnostic(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let url = diagnosticLogURL
        routeQueue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try line.data(using: .utf8)?.write(to: url)
                } else if let handle = try? FileHandle(forWritingTo: url) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(line.utf8))
                    try handle.close()
                }
            } catch {
                voiceRelayLog.error("voice relay diagnostic write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private var diagnosticLogURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AhaKeyConfig/diagnostics", isDirectory: true)
        return directory.appendingPathComponent("voice-relay.log")
    }
}

private func normalizedModifierSet(from flags: CGEventFlags) -> Set<ShortcutModifier> {
    var modifiers = Set<ShortcutModifier>()
    if flags.contains(.maskControl) {
        modifiers.insert(.control)
    }
    if flags.contains(.maskAlternate) {
        modifiers.insert(.option)
    }
    if flags.contains(.maskShift) {
        modifiers.insert(.shift)
    }
    if flags.contains(.maskCommand) {
        modifiers.insert(.command)
    }
    return modifiers
}

private func normalizedModifierSet(from flags: NSEvent.ModifierFlags) -> Set<ShortcutModifier> {
    var modifiers = Set<ShortcutModifier>()
    if flags.contains(.control) {
        modifiers.insert(.control)
    }
    if flags.contains(.option) {
        modifiers.insert(.option)
    }
    if flags.contains(.shift) {
        modifiers.insert(.shift)
    }
    if flags.contains(.command) {
        modifiers.insert(.command)
    }
    return modifiers
}

private func macBinding(for shortcut: ShortcutBinding) -> VoiceTriggerBinding? {
    guard let keyCode = macKeyCode(forHIDUsage: shortcut.keyCode) else { return nil }
    return VoiceTriggerBinding(keyCode: keyCode, modifiers: Set(shortcut.modifiers))
}

private func macKeyName(for keyCode: CGKeyCode) -> String {
    switch keyCode {
    case 122: return "F1"
    case 120: return "F2"
    case 99: return "F3"
    case 118: return "F4"
    case 96: return "F5"
    case 97: return "F6"
    case 98: return "F7"
    case 100: return "F8"
    case 101: return "F9"
    case 109: return "F10"
    case 103: return "F11"
    case 111: return "F12"
    case 105: return "F13"
    case 107: return "F14"
    case 113: return "F15"
    case 106: return "F16"
    case 64: return "F17"
    case 79: return "F18"
    case 80: return "F19"
    case 36: return "Return"
    case 53: return "Escape"
    case 51: return "Delete"
    case 48: return "Tab"
    case 49: return "Space"
    case 57: return "CapsLock"
    case 117: return "ForwardDelete"
    case 124: return "→"
    case 123: return "←"
    case 125: return "↓"
    case 126: return "↑"
    case 0 ... 25:
        let letters: [CGKeyCode: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G",
            4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N",
            31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U",
            9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        ]
        return letters[keyCode] ?? "Key \(keyCode)"
    default:
        return "Key \(keyCode)"
    }
}

private func macKeyCode(forHIDUsage hidCode: UInt8) -> CGKeyCode? {
    switch hidCode {
    case HIDUsage.f1: return 122
    case HIDUsage.f2: return 120
    case HIDUsage.f3: return 99
    case HIDUsage.f4: return 118
    case HIDUsage.f5: return 96
    case HIDUsage.f6: return 97
    case HIDUsage.f7: return 98
    case HIDUsage.f8: return 100
    case HIDUsage.f9: return 101
    case HIDUsage.f10: return 109
    case HIDUsage.f11: return 103
    case HIDUsage.f12: return 111
    case HIDUsage.f13: return 105
    case HIDUsage.f14: return 107
    case HIDUsage.f15: return 113
    case HIDUsage.f16: return 106
    case HIDUsage.f17: return 64
    case HIDUsage.f18: return 79
    case HIDUsage.f19: return 80
    case HIDUsage.enter: return 36
    case HIDUsage.escape: return 53
    case HIDUsage.backspace: return 51
    case HIDUsage.tab: return 48
    case HIDUsage.space: return 49
    case HIDUsage.capsLock: return 57
    case HIDUsage.deleteForward: return 117
    case HIDUsage.rightArrow: return 124
    case HIDUsage.leftArrow: return 123
    case HIDUsage.downArrow: return 125
    case HIDUsage.upArrow: return 126
    case 0x04: return 0
    case 0x05: return 11
    case 0x06: return 8
    case 0x07: return 2
    case 0x08: return 14
    case 0x09: return 3
    case 0x0A: return 5
    case 0x0B: return 4
    case 0x0C: return 34
    case 0x0D: return 38
    case 0x0E: return 40
    case 0x0F: return 37
    case 0x10: return 46
    case 0x11: return 45
    case 0x12: return 31
    case 0x13: return 35
    case 0x14: return 12
    case 0x15: return 15
    case 0x16: return 1
    case 0x17: return 17
    case 0x18: return 32
    case 0x19: return 9
    case 0x1A: return 13
    case 0x1B: return 7
    case 0x1C: return 16
    case 0x1D: return 6
    case 0x1E: return 18
    case 0x1F: return 19
    case 0x20: return 20
    case 0x21: return 21
    case 0x22: return 23
    case 0x23: return 22
    case 0x24: return 26
    case 0x25: return 28
    case 0x26: return 25
    case 0x27: return 29
    default:
        return nil
    }
}
