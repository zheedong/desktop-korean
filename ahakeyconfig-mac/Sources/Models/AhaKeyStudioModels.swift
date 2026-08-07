import Foundation

enum AhaKeyModeSlot: Int, CaseIterable, Codable, Identifiable {
    case mode0 = 0
    case mode1 = 1
    case mode2 = 2
    case mode3 = 3

    var id: Int { rawValue }

    var title: String {
        "Mode \(rawValue + 1)"
    }

    var shortTitle: String {
        "M\(rawValue + 1)"
    }

    var defaultName: String {
        switch self {
        case .mode0: "Claude"
        case .mode1: "Cursor"
        case .mode2: "Codex"
        case .mode3: "custom"
        }
    }

    var name: String {
        AhaKeyModeNameStore.load()[rawValue] ?? defaultName
    }

    var subtitle: String {
        switch self {
        case .mode0:
            "Claude Code · 터미널 권한 Y/N"
        case .mode1:
            "Cursor · Composer Accept/Reject"
        case .mode2:
            "Codex · ↵ / Esc"
        case .mode3:
            "custom · 사용자 지정 모드"
        }
    }

    var guidance: String {
        switch self {
        case .mode0:
            "Claude Code 터미널 권한 메뉴에 맞춘 설정입니다. Key2는 Y(동의)를, Key3는 N(거부)를 바로 입력합니다."
        case .mode1:
            "Cursor Composer / Agent에 맞춘 설정입니다. Key2는 ↵, Key3는 ⌫를 보냅니다(단일 키와 동일)."
        case .mode2:
            "Codex 터미널 승인에 맞춘 설정입니다. Key2는 ↵로 확인하고, Key3는 Esc로 취소합니다."
        case .mode3:
            "사용자 지정 모드입니다. 모든 키와 조명 효과를 자유롭게 설정할 수 있습니다."
        }
    }

    var guidanceHoverDetail: String? {
        switch self {
        case .mode1:
            return "「⌘↵ 수락 / ⌘⌫ 거부」 같은 조합 키와 맞추려면 편집기에서 해당 키에 조합 키를 추가하고, Cursor 설정 → Keyboard Shortcuts에서 같은 조합으로 지정하세요."
        case .mode0, .mode2, .mode3:
            return nil
        }
    }
}

enum AhaKeyModeNameStore {
    private static let key = "ahakey.mode.customNames.v1"

    static func load() -> [Int: String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([Int: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    static func save(_ names: [Int: String]) {
        guard let data = try? JSONEncoder().encode(names) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum AhaKeyStudioPart: String, CaseIterable, Codable, Identifiable {
    case lightBar
    case oledDisplay
    case key1
    case key2
    case key3
    case key4
    case toggleSwitch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lightBar:
            "라이트 바"
        case .oledDisplay:
            "LCD 화면"
        case .key1:
            "Key 1"
        case .key2:
            "Key 2"
        case .key3:
            "Key 3"
        case .key4:
            "Key 4"
        case .toggleSwitch:
            "레버"
        }
    }

    var subtitle: String {
        switch self {
        case .lightBar:
            "AI 상태 표시"
        case .oledDisplay:
            "움직이는 이미지 표시"
        case .key1:
            "음성 키"
        case .key2:
            "확인 키"
        case .key3:
            "취소 키"
        case .key4:
            "삭제 키"
        case .toggleSwitch:
            "승인 방식"
        }
    }

    var systemImage: String {
        switch self {
        case .lightBar:
            // lightspectrum.horizontal requires macOS 13; fall back to light.max on macOS 12
            if #available(macOS 13, *) { "lightspectrum.horizontal" } else { "light.max" }
        case .oledDisplay:
            "rectangle.inset.filled"
        case .key1:
            "microphone"
        case .key2:
            "checkmark"
        case .key3:
            "xmark"
        case .key4:
            "delete.left"
        case .toggleSwitch:
            "switch.2"
        }
    }

    var keyRole: AhaKeyKeyRole? {
        switch self {
        case .key1:
            .voice
        case .key2:
            .approve
        case .key3:
            .reject
        case .key4:
            .submit
        default:
            nil
        }
    }

    var isKey: Bool { keyRole != nil }
}

enum AhaKeyKeyRole: Int, CaseIterable, Codable, Identifiable {
    case voice = 0
    case approve = 1
    case reject = 2
    case submit = 3

    var id: Int { rawValue }

    var part: AhaKeyStudioPart {
        switch self {
        case .voice:
            .key1
        case .approve:
            .key2
        case .reject:
            .key3
        case .submit:
            .key4
        }
    }

    var title: String {
        switch self {
        case .voice:
            "음성 키"
        case .approve:
            "확인 키"
        case .reject:
            "취소 키"
        case .submit:
            "삭제 키"
        }
    }

    var systemImage: String {
        switch self {
        case .voice:
            "microphone"
        case .approve:
            "checkmark"
        case .reject:
            "xmark"
        case .submit:
            "delete.left"
        }
    }

    var defaultDescription: String {
        switch self {
        case .voice:
            "Record"
        case .approve:
            "Accept"
        case .reject:
            "Reject"
        case .submit:
            "Backspace"
        }
    }

    var manualText: String {
        switch self {
        case .voice:
            "주로 음성 입력을 실행하는 데 사용합니다. 소프트웨어에는 음성 프로그램 이름이 표시되지만, 내부적으로는 단축키로 기록됩니다."
        case .approve:
            "승인, 확인, 계속 실행처럼 자주 사용하는 동작에 적합합니다."
        case .reject:
            "거부, 취소, 중지처럼 반대되는 동작에 적합합니다."
        case .submit:
            "공장 기본값은 Backspace이며, 삭제나 입력 취소, 현재 내용 정리에 적합합니다."
        }
    }
}

enum ShortcutModifier: String, CaseIterable, Codable, Identifiable {
    case control
    case option
    case shift
    case command

    var id: String { rawValue }

    var title: String {
        switch self {
        case .control:
            "Control"
        case .option:
            "Option"
        case .shift:
            "Shift"
        case .command:
            "Command"
        }
    }

    var symbol: String {
        switch self {
        case .control:
            "⌃"
        case .option:
            "⌥"
        case .shift:
            "⇧"
        case .command:
            "⌘"
        }
    }

    var hidCode: UInt8 {
        switch self {
        case .control:
            HIDUsage.leftControl
        case .option:
            HIDUsage.leftAlt
        case .shift:
            HIDUsage.leftShift
        case .command:
            HIDUsage.leftGUI
        }
    }

    static let displayOrder: [ShortcutModifier] = [.control, .option, .shift, .command]
}

struct ShortcutBinding: Codable, Equatable {
    var modifiers: [ShortcutModifier]
    var keyCode: UInt8

    init(modifiers: [ShortcutModifier] = [], keyCode: UInt8 = 0) {
        self.modifiers = Self.normalized(modifiers)
        self.keyCode = keyCode
    }

    var hidCodes: [UInt8] {
        orderedModifiers.map(\.hidCode) + (keyCode == 0 ? [] : [keyCode])
    }

    var orderedModifiers: [ShortcutModifier] {
        modifiers.sorted { lhs, rhs in
            let order = ShortcutModifier.displayOrder
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    var displayLabel: String {
        let modifierLabel = orderedModifiers.map(\.symbol).joined()
        let keyLabel = keyCode == 0 ? "" : HIDUsage.name(for: keyCode)
        let combined = modifierLabel + keyLabel
        return combined.isEmpty ? "설정 안 됨" : combined
    }

    var isConfigured: Bool {
        keyCode != 0 || !modifiers.isEmpty
    }

    mutating func setModifier(_ modifier: ShortcutModifier, enabled: Bool) {
        var next = modifiers
        if enabled {
            next.append(modifier)
        } else {
            next.removeAll { $0 == modifier }
        }
        modifiers = Self.normalized(next)
    }

    private static func normalized(_ modifiers: [ShortcutModifier]) -> [ShortcutModifier] {
        var seen = Set<ShortcutModifier>()
        var result: [ShortcutModifier] = []
        for modifier in ShortcutModifier.displayOrder where modifiers.contains(modifier) {
            if seen.insert(modifier).inserted {
                result.append(modifier)
            }
        }
        return result
    }
}

enum VoicePreset: String, CaseIterable, Codable, Identifiable {
    case macOSNative
    case typeless
    case wechat
    case claudeCode
    case kimiCode
    case codex
    case doubao
    case custom

    var id: String { rawValue }

    /// claudeCode / kimiCode는 내부 라우팅이 macOSNative와 완전히 같으므로 하나의 옵션으로 합쳐 표시합니다.
    /// 열거형 case를 남겨 둔 것은 이미 저장된 설정 데이터와의 하위 호환을 위한 것이며, 마이그레이션은 AhaKeyStudioStore에서 처리합니다.
    var isMacOSNativeFamily: Bool {
        self == .macOSNative || self == .claudeCode || self == .kimiCode
    }

    /// Picker에 실제로 표시되는 옵션입니다(WeChat/Doubao는 Fn/Globe로 통합되었고, 이전 case는 마이그레이션용으로 남겨 둡니다).
    static var visibleCases: [VoicePreset] {
        [.macOSNative, .typeless, .custom]
    }

    var title: String {
        switch self {
        case .macOSNative, .claudeCode, .kimiCode:
            "macOS 기본 음성 변환"
        case .typeless:
            "Fn/Globe"
        case .wechat:
            "WeChat 음성"
        case .codex:
            "Codex"
        case .doubao:
            "Doubao 입력기"
        case .custom:
            "사용자 지정 단축키"
        }
    }

    var detail: String {
        switch self {
        case .macOSNative, .claudeCode, .kimiCode:
            "Apple 기본 음성 변환을 호출하고, 인식이 끝나면 ⌘V로 현재 커서 위치에 입력합니다. Claude Code, Kimi Code, Codex 같은 CLI 터미널과 모든 입력란에 적합합니다. 한 번 누르면 시작하고, 다시 누르면 종료합니다."
        case .typeless:
            "대응하는 단축키 프리셋입니다. Typeless, WeChat 음성, Doubao 입력기에서도 Fn/Globe를 선택하세요. 이 Studio는 F19를 Fn 트리거 키로 사용하며, 누르면 시스템에 「Fn 누르고 있기」를 전달합니다. 이전 버전의 F18도 계속 호환 감지합니다. 입력 모니터링과 손쉬운 사용 권한을 허용해 주세요."
        case .wechat:
            "AhaKey Studio는 F19를 Fn 트리거 키로 사용하며, 백그라운드에서 음성 키의 누름/떼기를 Fn/Globe로 변환해 WeChat 음성과 연동하기 쉽게 합니다."
        case .doubao:
            "Doubao 입력기 Mac 버전은 실제 음성 키 이벤트를 직접 받아야 합니다. AhaKey Studio는 Doubao 입력 소스로 전환하고, F18을 Doubao의 길게 누르기 음성 단축키로 설정합니다. 음성 키를 누른 채 말하고 떼면 Doubao가 텍스트를 입력합니다."
        case .codex:
            "준비 중이며, 진입점만 남겨 둡니다."
        case .custom:
            "내부 단축키를 직접 지정합니다."
        }
    }

    var availableInV1: Bool {
        switch self {
        case .codex:
            false
        default:
            true
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .macOSNative:
            ShortcutBinding(keyCode: HIDUsage.f18)
        case .typeless:
            // macOS 기본값 F18과 겹치지 않게 합니다. 펌웨어는 Typeless 단계의 음성 키를 F19로 설정할 수 있고, Mode 0에는 F18 공장 호환 라우팅이 따로 있습니다
            ShortcutBinding(keyCode: HIDUsage.f19)
        case .wechat:
            ShortcutBinding(keyCode: HIDUsage.f19)
        case .claudeCode:
            ShortcutBinding(keyCode: HIDUsage.f18)
        case .kimiCode:
            ShortcutBinding(keyCode: HIDUsage.f18)
        case .codex:
            ShortcutBinding(keyCode: HIDUsage.f18)
        case .doubao:
            ShortcutBinding(keyCode: HIDUsage.f18)
        case .custom:
            ShortcutBinding()
        }
    }
}

enum LightBarPreviewState: String, CaseIterable, Codable, Identifiable {
    case aiRunning
    case waitingApproval
    case stopped
    case taskCompleted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aiRunning:
            "AI 실행 중"
        case .waitingApproval:
            "승인 대기"
        case .stopped:
            "중지됨"
        case .taskCompleted:
            "작업 완료"
        }
    }

    var detail: String {
        switch self {
        case .aiRunning:
            "기본 효과는 좌우로 흐르는 조명입니다."
        case .waitingApproval:
            "지금 확인이 필요하다고 알립니다."
        case .stopped:
            "기본적으로 빨간색 상시 점등으로 멈춥니다."
        case .taskCompleted:
            "이번 실행이 완료되었음을 나타냅니다."
        }
    }

    var ideState: IDEState {
        switch self {
        case .aiRunning:
            .preToolUse
        case .waitingApproval:
            .permissionRequest
        case .stopped:
            .stop
        case .taskCompleted:
            .taskCompleted
        }
    }
}

enum LightEffectStyle: String, CaseIterable, Codable, Identifiable {
    case off
    case middleLight
    case singleMove
    case breathing
    case rainbowMove
    case rainbowWave
    case rainbowWaveSlow
    case typingRipple
    case comet
    case scanBar
    case pulseCenter
    case warningBlink
    case successSweep
    case blueThinking
    case lowBattery
    case chargingFlow
    case approvalWait

    var id: String { rawValue }

    var firmwareIndex: UInt8 {
        switch self {
        case .off: 0
        case .singleMove: 1
        case .rainbowMove: 2
        case .rainbowWave: 3
        case .rainbowWaveSlow: 4
        case .breathing: 5
        case .middleLight: 6
        case .typingRipple: 7
        case .comet: 8
        case .scanBar: 9
        case .pulseCenter: 10
        case .warningBlink: 11
        case .successSweep: 12
        case .blueThinking: 13
        case .lowBattery: 14
        case .chargingFlow: 15
        case .approvalWait: 16
        }
    }

    init?(firmwareIndex: UInt8) {
        guard let match = Self.allCases.first(where: { $0.firmwareIndex == firmwareIndex }) else {
            return nil
        }
        self = match
    }

    var title: String {
        switch self {
        case .off: "꺼짐"
        case .middleLight: "중앙 정지"
        case .singleMove: "좌우 흐름"
        case .breathing: "전체 호흡"
        case .rainbowMove: "무지개 흐름"
        case .rainbowWave: "무지개 파도"
        case .rainbowWaveSlow: "무지개 느린 파도"
        case .typingRipple: "타이핑 물결"
        case .comet: "혜성 꼬리"
        case .scanBar: "스캔 바"
        case .pulseCenter: "중앙 펄스"
        case .warningBlink: "경고 점멸"
        case .successSweep: "성공 스윕"
        case .blueThinking: "파란색 사고 중"
        case .lowBattery: "배터리 부족"
        case .chargingFlow: "충전 흐름"
        case .approvalWait: "승인 대기"
        }
    }

    var detail: String {
        switch self {
        case .off: "라이트 바를 켜지 않습니다."
        case .middleLight: "중앙이 가장 밝고 양쪽으로 점점 어두워져, 정지 상태를 알리기에 적합합니다."
        case .singleMove: "한 점이 좌우로 움직여 실행 중 상태에 적합합니다."
        case .breathing: "전체가 고르게 밝아지고 어두워져 확인 대기에 적합합니다."
        case .rainbowMove: "색이 있는 한 점이 흘러 더 활기찬 느낌을 줍니다."
        case .rainbowWave: "전체가 색으로 흘러 더 눈에 잘 띕니다."
        case .rainbowWaveSlow: "일반 무지개 파도보다 느려 분위기 연출에 적합합니다."
        case .typingRipple: "중앙에서 양쪽으로 퍼지는 물결 효과입니다."
        case .comet: "꼬리를 남기며 한 방향으로 지나가는, 혜성 같은 효과입니다."
        case .scanBar: "3개 조명이 한 조로 좌우를 스캔합니다."
        case .pulseCenter: "중앙에서 빠르게 펄스가 퍼집니다."
        case .warningBlink: "주황색으로 빠르게 점멸하여 경고에 적합합니다."
        case .successSweep: "초록색이 왼쪽에서 오른쪽으로 차례로 켜집니다."
        case .blueThinking: "파란색 호흡 파도로 사고 중 상태에 적합합니다."
        case .lowBattery: "빨간색으로 느리게 점멸하여 배터리 부족을 나타냅니다."
        case .chargingFlow: "초록색이 채워지며 흘러 충전 중임을 나타냅니다."
        case .approvalWait: "호박색 호흡과 중앙 점멸로 사용자 조작을 기다립니다."
        }
    }
}

struct AhaKeyLightStateDraft: Codable, Equatable, Identifiable {
    var state: IDEState
    var effect: LightEffectStyle

    var id: UInt8 { state.rawValue }

    private enum CodingKeys: String, CodingKey {
        case state, effect
    }

    init(state: IDEState, effect: LightEffectStyle) {
        self.state = state
        self.effect = effect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        effect = try container.decode(LightEffectStyle.self, forKey: .effect)
        if let ideState = try? container.decode(IDEState.self, forKey: .state) {
            state = ideState
        } else if let legacy = try? container.decode(LightBarPreviewState.self, forKey: .state) {
            state = legacy.ideState
        } else {
            state = .notification
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(effect, forKey: .effect)
    }
}

struct AhaKeyLightBarDraft: Codable, Equatable {
    var stateMappings: [AhaKeyLightStateDraft]
    var brightness: Int

    func effect(for state: IDEState) -> LightEffectStyle {
        stateMappings.first(where: { $0.state == state })?.effect ?? .singleMove
    }

    private enum CodingKeys: String, CodingKey {
        case stateMappings, brightness
    }

    init(stateMappings: [AhaKeyLightStateDraft], brightness: Int = 35) {
        self.stateMappings = stateMappings
        self.brightness = brightness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawMappings = try container.decode([AhaKeyLightStateDraft].self, forKey: .stateMappings)
        let rawBrightness = try container.decodeIfPresent(Int.self, forKey: .brightness) ?? 35
        brightness = max(1, min(100, rawBrightness))

        if rawMappings.count >= IDEState.allCases.count {
            stateMappings = rawMappings
        } else {
            let defaults = AhaKeyLightBarDraft.defaultMappings
            var merged = rawMappings
            for defaultMapping in defaults {
                if !merged.contains(where: { $0.state == defaultMapping.state }) {
                    merged.append(defaultMapping)
                }
            }
            stateMappings = merged.sorted { $0.state.rawValue < $1.state.rawValue }
        }
    }

    static let defaultMappings: [AhaKeyLightStateDraft] = [
        AhaKeyLightStateDraft(state: .notification, effect: .pulseCenter),
        AhaKeyLightStateDraft(state: .permissionRequest, effect: .approvalWait),
        AhaKeyLightStateDraft(state: .postToolUse, effect: .successSweep),
        AhaKeyLightStateDraft(state: .preToolUse, effect: .singleMove),
        AhaKeyLightStateDraft(state: .sessionStart, effect: .rainbowWave),
        AhaKeyLightStateDraft(state: .stop, effect: .middleLight),
        AhaKeyLightStateDraft(state: .taskCompleted, effect: .successSweep),
        AhaKeyLightStateDraft(state: .userPromptSubmit, effect: .breathing),
        AhaKeyLightStateDraft(state: .sessionEnd, effect: .off),
    ]

    static func `default`(for mode: AhaKeyModeSlot) -> AhaKeyLightBarDraft {
        _ = mode
        return AhaKeyLightBarDraft(stateMappings: defaultMappings, brightness: 35)
    }
}

/// 펌웨어 매크로 단계의 동작 유형입니다.
/// 기존 Python 클라이언트의 `MacroAction`에 대응하며, 실행 로직은 펌웨어 쪽에 구현되어 있습니다.
enum MacroAction: UInt8, Codable, CaseIterable, Identifiable {
    case noOp = 0
    case downKey = 1
    case upKey = 2
    /// `param`의 단위는 3ms이며(펌웨어 규정), 최대 255 ≈ 765ms입니다.
    case delay = 3
    case upAllKeys = 4

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .noOp: return "동작 없음"
        case .downKey: return "누르기"
        case .upKey: return "떼기"
        case .delay: return "지연"
        case .upAllKeys: return "전체 떼기"
        }
    }

    /// param으로 HID 키 코드가 필요한지 여부입니다.
    var takesKeycodeParam: Bool {
        self == .downKey || self == .upKey
    }

    /// param을 지연 단위(×3ms)로 사용하는지 여부입니다.
    var takesDelayParam: Bool {
        self == .delay
    }
}

/// 매크로 단계 하나입니다. 펌웨어 프로토콜에서는 (action, param) 두 바이트에 해당합니다.
struct MacroStep: Codable, Equatable, Identifiable {
    var id: UUID
    var action: MacroAction
    /// downKey/upKey는 HID keycode, delay는 ×3ms, noOp / upAllKeys는 무시됩니다.
    var param: UInt8

    init(id: UUID = UUID(), action: MacroAction, param: UInt8 = 0) {
        self.id = id
        self.action = action
        self.param = param
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case action
        case param
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.action = try c.decode(MacroAction.self, forKey: .action)
        self.param = try c.decodeIfPresent(UInt8.self, forKey: .param) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(action, forKey: .action)
        try c.encode(param, forKey: .param)
    }

    /// `↓` / `Enter` / `+5ms`처럼 사람이 읽을 수 있는 형태로 표시하며, inspector와 summary에서 함께 사용합니다.
    var displayLabel: String {
        switch action {
        case .noOp:
            return "no-op"
        case .downKey:
            return "↓\(HIDUsage.name(for: param))"
        case .upKey:
            return "↑\(HIDUsage.name(for: param))"
        case .delay:
            let ms = Int(param) * 3
            return "+\(ms)ms"
        case .upAllKeys:
            return "↑ALL"
        }
    }
}

extension Array where Element == MacroStep {
    /// (action, param, action, param, ...) 바이트 스트림으로 펼치며, 길이는 2 × 단계 수입니다.
    /// 펌웨어 상한은 98바이트 ≈ 49단계입니다. 여기서는 자르지 않고 호출하는 쪽에서 확인하거나 안내합니다.
    var flattenedBytes: [UInt8] {
        flatMap { [$0.action.rawValue, $0.param] }
    }

    /// 요약 설명입니다. 연속된 down/up 쌍을 `X`로 합쳐 보기 쉽게 표시합니다.
    /// 모든 세부 정보를 그대로 복원할 수는 없으며, UI summary 전용입니다.
    var displaySummary: String {
        var parts: [String] = []
        var i = 0
        while i < count {
            let step = self[i]
            if step.action == .downKey,
               i + 1 < count,
               self[i + 1].action == .upKey,
               self[i + 1].param == step.param
            {
                parts.append(HIDUsage.name(for: step.param))
                i += 2
            } else {
                parts.append(step.displayLabel)
                i += 1
            }
        }
        return parts.joined(separator: " → ")
    }
}

struct AhaKeyKeyDraft: Codable, Equatable, Identifiable {
    let role: AhaKeyKeyRole
    var shortcut: ShortcutBinding
    /// 비어 있지 않으면 해당 키 전체를 펌웨어 매크로로 전송합니다(`cmdUpdateCustomKey / subMacro`).
    /// 이때 `shortcut`은 무시됩니다. 비어 있으면 `subShortcut`(단일 키/조합 키)을 사용합니다.
    var macro: [MacroStep]
    var description: String
    var voicePreset: VoicePreset?

    init(
        role: AhaKeyKeyRole,
        shortcut: ShortcutBinding,
        macro: [MacroStep] = [],
        description: String,
        voicePreset: VoicePreset? = nil
    ) {
        self.role = role
        self.shortcut = shortcut
        self.macro = macro
        self.description = description
        self.voicePreset = voicePreset
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case shortcut
        case macro
        case description
        case voicePreset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try c.decode(AhaKeyKeyRole.self, forKey: .role)
        self.shortcut = try c.decode(ShortcutBinding.self, forKey: .shortcut)
        self.macro = try c.decodeIfPresent([MacroStep].self, forKey: .macro) ?? []
        self.description = try c.decode(String.self, forKey: .description)
        self.voicePreset = try c.decodeIfPresent(VoicePreset.self, forKey: .voicePreset)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(shortcut, forKey: .shortcut)
        if !macro.isEmpty {
            try c.encode(macro, forKey: .macro)
        }
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(voicePreset, forKey: .voicePreset)
    }

    var id: Int { role.rawValue }

    var title: String { role.title }

    /// 현재 키를 "매크로" 형태로 전송하는지 여부입니다.
    var usesMacro: Bool { !macro.isEmpty }

    var displaySummary: String {
        if role == .voice, let voicePreset {
            return voicePreset.title
        }
        if usesMacro {
            return "매크로: \(macro.displaySummary)"
        }
        return shortcut.displayLabel
    }
}

struct AhaKeyOLEDDraft: Codable, Equatable {
    var localAssetPath: String?
    var statusLine: String
    var framesPerSecond: Int

    private enum CodingKeys: String, CodingKey {
        case localAssetPath
        case statusLine
        case framesPerSecond
    }

    init(localAssetPath: String?, statusLine: String, framesPerSecond: Int = 12) {
        self.localAssetPath = localAssetPath
        self.statusLine = statusLine
        self.framesPerSecond = framesPerSecond
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localAssetPath = try container.decodeIfPresent(String.self, forKey: .localAssetPath)
        statusLine = try container.decode(String.self, forKey: .statusLine)
        let storedFPS = try container.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? 12
        framesPerSecond = min(30, max(1, storedFPS))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(localAssetPath, forKey: .localAssetPath)
        try container.encode(statusLine, forKey: .statusLine)
        try container.encode(framesPerSecond, forKey: .framesPerSecond)
    }

    static func `default`(for mode: AhaKeyModeSlot) -> AhaKeyOLEDDraft {
        let statusLine: String
        switch mode {
        case .mode0:
            statusLine = "Claude Code · 터미널 권한 메뉴 Y/N."
        case .mode1:
            statusLine = "Cursor · ↵ 변경 수락 / ⌫ 변경 거부."
        case .mode2:
            statusLine = "Codex · 승인 ↵ / Esc."
        case .mode3:
            statusLine = "사용자 지정 모드."
        }
        return AhaKeyOLEDDraft(
            localAssetPath: DefaultOLEDAssets.bundledAssetPath(for: mode),
            statusLine: statusLine,
            framesPerSecond: 12
        )
    }
}

struct AhaKeyModeDraft: Codable, Equatable, Identifiable {
    let mode: AhaKeyModeSlot
    var keys: [AhaKeyKeyDraft]
    var oled: AhaKeyOLEDDraft
    var lightBar: AhaKeyLightBarDraft

    var id: Int { mode.rawValue }

    init(mode: AhaKeyModeSlot, keys: [AhaKeyKeyDraft], oled: AhaKeyOLEDDraft, lightBar: AhaKeyLightBarDraft) {
        self.mode = mode
        self.keys = keys
        self.oled = oled
        self.lightBar = lightBar
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case keys
        case oled
        case lightBar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(AhaKeyModeSlot.self, forKey: .mode)
        keys = try container.decode([AhaKeyKeyDraft].self, forKey: .keys)
        oled = try container.decodeIfPresent(AhaKeyOLEDDraft.self, forKey: .oled) ?? .default(for: mode)
        lightBar = try container.decodeIfPresent(AhaKeyLightBarDraft.self, forKey: .lightBar) ?? .default(for: mode)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(keys, forKey: .keys)
        try container.encode(oled, forKey: .oled)
        try container.encode(lightBar, forKey: .lightBar)
    }

    func key(for role: AhaKeyKeyRole) -> AhaKeyKeyDraft {
        keys.first { $0.role == role } ?? AhaKeyModeDraft.default(for: mode).keys[role.rawValue]
    }

    mutating func updateKey(_ updated: AhaKeyKeyDraft) {
        if let index = keys.firstIndex(where: { $0.role == updated.role }) {
            keys[index] = updated
        }
    }

    /// Claude CLI 신규 메뉴 "1. Yes / 2. Yes, allow all / 3. No":
    /// 커서가 기본적으로 Yes에 있으므로, No는 ↓를 두 번 누른 뒤 Enter를 입력해야 합니다.
    /// 펌웨어 기본 매크로(action/param pairs)로, 키보드가 직접 세 개의 HID 이벤트를 순차적으로 전송합니다.
    static let claudeNoMacroSteps: [MacroStep] = [
        .init(action: .downKey, param: HIDUsage.downArrow),
        .init(action: .upKey, param: HIDUsage.downArrow),
        .init(action: .delay, param: 5),
        .init(action: .downKey, param: HIDUsage.downArrow),
        .init(action: .upKey, param: HIDUsage.downArrow),
        .init(action: .delay, param: 5),
        .init(action: .downKey, param: HIDUsage.enter),
        .init(action: .upKey, param: HIDUsage.enter),
    ]

    static func `default`(for mode: AhaKeyModeSlot) -> AhaKeyModeDraft {
        let voicePreset: VoicePreset = .macOSNative
        let approveShortcut: ShortcutBinding
        let rejectShortcut: ShortcutBinding
        var rejectMacro: [MacroStep] = []
        let approveDescription: String
        let rejectDescription: String

        switch mode {
        case .mode0:
            // Yes는 Enter를 누르고, No는 펌웨어 기본 매크로 ↓↓⏎를 사용합니다.
            approveShortcut = ShortcutBinding(keyCode: HIDUsage.enter)
            rejectShortcut = ShortcutBinding()
            rejectMacro = claudeNoMacroSteps
            approveDescription = "Yes"
            rejectDescription = "No"
        case .mode1:
            // 펌웨어의 `defult_key_0_1` 같은 단순 HID 방식과 동일하게 단일 키 Enter / Backspace를 사용합니다. Composer 기본 ⌘ 조합을 쓰려면 사용자가 편집기에서 ⌘를 선택하거나 Cursor 단축키를 변경합니다.
            approveShortcut = ShortcutBinding(keyCode: HIDUsage.enter)
            rejectShortcut = ShortcutBinding(keyCode: HIDUsage.backspace)
            approveDescription = "Accept"
            rejectDescription = "Reject"
        case .mode2:
            approveShortcut = ShortcutBinding(keyCode: HIDUsage.enter)
            rejectShortcut = ShortcutBinding(keyCode: HIDUsage.escape)
            approveDescription = "Accept"
            rejectDescription = "Reject"
        case .mode3:
            approveShortcut = ShortcutBinding(keyCode: HIDUsage.enter)
            rejectShortcut = ShortcutBinding(keyCode: HIDUsage.escape)
            approveDescription = "Accept"
            rejectDescription = "Reject"
        }

        return AhaKeyModeDraft(
            mode: mode,
            keys: [
                AhaKeyKeyDraft(
                    role: .voice,
                    shortcut: voicePreset.defaultBinding,
                    description: AhaKeyKeyRole.voice.defaultDescription,
                    voicePreset: voicePreset
                ),
                AhaKeyKeyDraft(
                    role: .approve,
                    shortcut: approveShortcut,
                    description: approveDescription,
                    voicePreset: nil
                ),
                AhaKeyKeyDraft(
                    role: .reject,
                    shortcut: rejectShortcut,
                    macro: rejectMacro,
                    description: rejectDescription,
                    voicePreset: nil
                ),
                AhaKeyKeyDraft(
                    role: .submit,
                    shortcut: ShortcutBinding(keyCode: HIDUsage.backspace),
                    description: AhaKeyKeyRole.submit.defaultDescription,
                    voicePreset: nil
                ),
            ],
            oled: .default(for: mode),
            lightBar: .default(for: mode)
        )
    }
}

struct AhaKeyStudioDraft: Codable, Equatable {
    var modes: [AhaKeyModeDraft]

    static let `default` = AhaKeyStudioDraft(
        modes: AhaKeyModeSlot.allCases.map { AhaKeyModeDraft.default(for: $0) }
    )

    func draft(for mode: AhaKeyModeSlot) -> AhaKeyModeDraft {
        modes.first(where: { $0.mode == mode }) ?? AhaKeyModeDraft.default(for: mode)
    }

    mutating func updateMode(_ updated: AhaKeyModeDraft) {
        if let index = modes.firstIndex(where: { $0.mode == updated.mode }) {
            modes[index] = updated
        }
    }
}

enum AhaKeyStudioStore {
    private static let key = "ahakey.studio.draft.v1"

    static func load() -> AhaKeyStudioDraft? {
        guard let data = UserDefaults.standard.data(forKey: key),
              var draft = try? JSONDecoder().decode(AhaKeyStudioDraft.self, from: data) else {
            return nil
        }
        let existingSlots = Set(draft.modes.map(\.mode))
        for slot in AhaKeyModeSlot.allCases where !existingSlots.contains(slot) {
            draft.modes.append(AhaKeyModeDraft.default(for: slot))
        }
        return migratedDraft(from: draft)
    }

    static func save(_ draft: AhaKeyStudioDraft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func migratedDraft(from draft: AhaKeyStudioDraft) -> AhaKeyStudioDraft {
        var next = draft
        var mode0 = next.draft(for: .mode0)
        let legacyDescriptions: [AhaKeyKeyRole: String] = [
            .voice: "语音",
            .approve: "批准",
            .reject: "拒绝",
            .submit: "回车",
        ]

        for role in AhaKeyKeyRole.allCases {
            var key = mode0.key(for: role)
            if key.description.isEmpty || key.description == legacyDescriptions[role] {
                key.description = role.defaultDescription
            }
            if role == .voice,
               key.voicePreset == .macOSNative,
               key.shortcut.keyCode == HIDUsage.f17,
               key.shortcut.modifiers.isEmpty
            {
                key.shortcut = ShortcutBinding(keyCode: HIDUsage.f18)
            }
            mode0.updateKey(key)
        }
        next.updateMode(mode0)

        // claudeCode / kimiCode는 macOSNative로 통합되었으므로, 모든 mode의 이전 preset을 마이그레이션합니다.
        for modeSlot in AhaKeyModeSlot.allCases {
            var modeDraft = next.draft(for: modeSlot)
            var voiceKey = modeDraft.key(for: .voice)
            if voiceKey.voicePreset == .claudeCode || voiceKey.voicePreset == .kimiCode {
                voiceKey.voicePreset = .macOSNative
                modeDraft.updateKey(voiceKey)
                next.updateMode(modeDraft)
            }
        }

        // 이전 Mode 0 = Cursor / 이전 Mode 1 = Claude를 쓰던 사용자는 새 기본 배치로 자동 교체합니다.
        // 두 mode의 approve/reject가 모두 이전 기본값과 완전히 같을 때만 실행하여, 직접 변경한 설정을 보호합니다.
        let cursorApproveBinding = ShortcutBinding(modifiers: [.command], keyCode: HIDUsage.enter)
        let cursorRejectBinding = ShortcutBinding(modifiers: [.command], keyCode: HIDUsage.backspace)
        let claudeApproveBinding = ShortcutBinding(keyCode: 0x1C)
        let claudeRejectBinding = ShortcutBinding(keyCode: 0x11)

        let legacyMode0 = next.draft(for: .mode0)
        let legacyMode1 = next.draft(for: .mode1)
        let mode0LooksLikeCursor =
            legacyMode0.key(for: .approve).shortcut == cursorApproveBinding
            && legacyMode0.key(for: .approve).description == "Accept"
            && legacyMode0.key(for: .reject).shortcut == cursorRejectBinding
            && legacyMode0.key(for: .reject).description == "Reject"
        let mode1LooksLikeClaude =
            legacyMode1.key(for: .approve).shortcut == claudeApproveBinding
            && legacyMode1.key(for: .approve).description == "Yes"
            && legacyMode1.key(for: .reject).shortcut == claudeRejectBinding
            && legacyMode1.key(for: .reject).description == "No"

        if mode0LooksLikeCursor, mode1LooksLikeClaude {
            let m1Def = AhaKeyModeDraft.default(for: .mode1)
            var newMode0 = legacyMode0
            var newMode1 = legacyMode1
            var approve0 = newMode0.key(for: .approve)
            approve0.shortcut = claudeApproveBinding
            approve0.description = "Yes"
            newMode0.updateKey(approve0)
            var reject0 = newMode0.key(for: .reject)
            reject0.shortcut = claudeRejectBinding
            reject0.description = "No"
            newMode0.updateKey(reject0)
            var approve1 = newMode1.key(for: .approve)
            approve1.shortcut = m1Def.key(for: .approve).shortcut
            approve1.description = "Accept"
            newMode1.updateKey(approve1)
            var reject1 = newMode1.key(for: .reject)
            reject1.shortcut = m1Def.key(for: .reject).shortcut
            reject1.macro = m1Def.key(for: .reject).macro
            reject1.description = "Reject"
            newMode1.updateKey(reject1)
            next.updateMode(newMode0)
            next.updateMode(newMode1)
        }

        let legacyOLEDStatusLines: Set<String> = [
            "当前仅支持动图",
            "切换模式时会先显示按键描述，再回到 Mode 1 默认动图。",
            "当前模式还未上传动图，后续可替换成你的自定义 GIF。",
            "Cursor · ⌘↵ 接受改动 / ⌘⌫ 拒绝改动。",
            "Cursor · ↵ 接受改动 / ⌫ 拒绝改动。",
            "Claude Code · 终端权限菜单 Y/N。",
            "Codex · 审批 ↵ / Esc。",
            "自定义模式。",
        ]
        let legacyApproveBinding = ShortcutBinding(keyCode: HIDUsage.enter)
        let legacyRejectBinding = ShortcutBinding(keyCode: HIDUsage.escape)
        let legacyApproveDescriptions: Set<String> = ["Accept", "批准", ""]
        let legacyRejectDescriptions: Set<String> = ["Reject", "拒绝", ""]

        for mode in AhaKeyModeSlot.allCases {
            var modeDraft = next.draft(for: mode)
            let target = AhaKeyModeDraft.default(for: mode)

            if legacyOLEDStatusLines.contains(modeDraft.oled.statusLine) {
                modeDraft.oled.statusLine = AhaKeyOLEDDraft.default(for: mode).statusLine
            }

            // LCD 소재 경로 자동 복구: 사용자가 사용자 지정 GIF를 선택하지 않았거나(nil), 이전 bundle 경로를 참조하는 경우,
            // 현재 빌드의 내장 GIF 절대 경로로 갱신합니다. 사용자가 직접 선택한 외부 경로는 그대로 유지합니다.
            if let bundled = DefaultOLEDAssets.bundledAssetPath(for: mode) {
                if modeDraft.oled.localAssetPath == nil
                    || (modeDraft.oled.localAssetPath.map(DefaultOLEDAssets.isBundledPath) ?? false)
                {
                    modeDraft.oled.localAssetPath = bundled
                }
            } else if let existing = modeDraft.oled.localAssetPath,
                      DefaultOLEDAssets.isBundledPath(existing) {
                modeDraft.oled.localAssetPath = nil
            }

            var voiceKey = modeDraft.key(for: .voice)
            if voiceKey.voicePreset == .wechat || voiceKey.voicePreset == .doubao {
                voiceKey.voicePreset = .typeless
                modeDraft.updateKey(voiceKey)
            }
            voiceKey = modeDraft.key(for: .voice)
            if voiceKey.voicePreset == .macOSNative,
               voiceKey.shortcut.keyCode == HIDUsage.f17,
               voiceKey.shortcut.modifiers.isEmpty
            {
                voiceKey.shortcut = ShortcutBinding(keyCode: HIDUsage.f18)
                modeDraft.updateKey(voiceKey)
            }
            if (voiceKey.voicePreset == .typeless || voiceKey.voicePreset == .wechat),
               voiceKey.shortcut.keyCode == HIDUsage.f18,
               voiceKey.shortcut.modifiers.isEmpty
            {
                voiceKey.shortcut = ShortcutBinding(keyCode: HIDUsage.f19)
                modeDraft.updateKey(voiceKey)
            }

            var submitKey = modeDraft.key(for: .submit)
            if submitKey.macro.isEmpty,
               submitKey.shortcut == ShortcutBinding(keyCode: HIDUsage.enter),
               (submitKey.description == "Enter" || submitKey.description == "回车" || submitKey.description.isEmpty)
            {
                let targetSubmit = target.key(for: .submit)
                submitKey.shortcut = targetSubmit.shortcut
                submitKey.description = targetSubmit.description
                modeDraft.updateKey(submitKey)
            }

            submitKey = modeDraft.key(for: .submit)
            if submitKey.shortcut == ShortcutBinding(keyCode: HIDUsage.backspace),
               submitKey.macro.isEmpty,
               ["", "backspace", "Back space", "Back Space", "删除", "删除键"].contains(submitKey.description)
            {
                submitKey.description = AhaKeyKeyRole.submit.defaultDescription
                modeDraft.updateKey(submitKey)
            }

            if modeDraft.lightBar.brightness == 50 {
                modeDraft.lightBar.brightness = 35
            }

            // 이전 버전의 「전체 모드 공용」 템플릿은 기본 키 ↵/Esc와 Accept/Reject 문구를 사용했습니다. Codex 및 다른 mode의 업그레이드에는 여전히 필요합니다.
            // Mode 1(Cursor)은 사용자가 **의도적으로** 조합 키를 변경할 수 있으므로, 아래 규칙을 계속 적용하면 실행할 때마다 공장 기본값 ↵/⌫로 되돌아가 변경한 키가 저장되지 않는 것처럼 보입니다.
            if mode != .mode1 {
                var approveKey = modeDraft.key(for: .approve)
                if approveKey.shortcut == legacyApproveBinding,
                   legacyApproveDescriptions.contains(approveKey.description)
                {
                    let targetApprove = target.key(for: .approve)
                    approveKey.shortcut = targetApprove.shortcut
                    approveKey.description = targetApprove.description
                    modeDraft.updateKey(approveKey)
                }

                var rejectKey = modeDraft.key(for: .reject)
                if rejectKey.shortcut == legacyRejectBinding,
                   legacyRejectDescriptions.contains(rejectKey.description)
                {
                    let targetReject = target.key(for: .reject)
                    rejectKey.shortcut = targetReject.shortcut
                    rejectKey.description = targetReject.description
                    // 현재 mode의 기본값과 반드시 일치해야 합니다. Mode 0의 No는 펌웨어 매크로 ↓↓⏎에 의존하므로 shortcut만 복사할 수 없습니다(매크로가 비면 UI가 단일 키 표시로 바뀝니다).
                    rejectKey.macro = targetReject.macro
                    modeDraft.updateKey(rejectKey)
                }
            }

            // Mode 0 (Claude) 전용 업그레이드 경로:
            //   이전 초안 1: reject = "N" (0x11)            → 펌웨어 기본 매크로 ↓↓⏎로 업그레이드
            //   이전 초안 2: reject = "F20" (0x6F) 대리 키   → 펌웨어 기본 매크로 ↓↓⏎로 업그레이드
            // 동시에 approve를 0x1C (Y)에서 Enter로 업그레이드합니다.
            // 업그레이드 조건: 사용자가 설명을 직접 변경하지 않았을 때(비어 있거나 기본값 "Yes" / "No"일 때)입니다.
            if mode == .mode0 {
                var approve0 = modeDraft.key(for: .approve)
                if approve0.shortcut == ShortcutBinding(keyCode: 0x1C),
                   approve0.description == "Yes" || approve0.description.isEmpty,
                   approve0.macro.isEmpty
                {
                    approve0.shortcut = ShortcutBinding(keyCode: HIDUsage.enter)
                    approve0.description = "Yes"
                    modeDraft.updateKey(approve0)
                }
                var reject0 = modeDraft.key(for: .reject)
                let wasLegacyN = reject0.shortcut == ShortcutBinding(keyCode: 0x11)
                let wasF20Proxy = reject0.shortcut == ShortcutBinding(keyCode: HIDUsage.f20)
                if (wasLegacyN || wasF20Proxy),
                   reject0.description == "No" || reject0.description.isEmpty,
                   reject0.macro.isEmpty
                {
                    reject0.shortcut = ShortcutBinding()
                    reject0.macro = AhaKeyModeDraft.claudeNoMacroSteps
                    reject0.description = "No"
                    modeDraft.updateKey(reject0)
                }

                // 자동 복구: 이전 버전 마이그레이션에서 Esc를 No로 바꿀 때 macro 복사가 누락된 경우, 또는 사용자가 Inspector에서 「매크로」를 「단일 키/조합 키」로 바꿔 매크로가 비워진 경우입니다. No의 올바른 설정은 빈 shortcut + ↓↓⏎입니다.
                var rejectNo = modeDraft.key(for: .reject)
                if rejectNo.description == "No",
                   rejectNo.macro.isEmpty,
                   rejectNo.shortcut == ShortcutBinding()
                    || rejectNo.shortcut == ShortcutBinding(keyCode: HIDUsage.enter)
                {
                    rejectNo.shortcut = ShortcutBinding()
                    rejectNo.macro = AhaKeyModeDraft.claudeNoMacroSteps
                    modeDraft.updateKey(rejectNo)
                }
            }

            // Mode 1(Cursor)의 취소 키는 「단일 키 Backspace」 HID 단축키입니다. 초안에 비어 있지 않은 macro가 남아 있으면(예: 다른 mode에서 잘못 따라왔거나, UI에서 매크로로 바꾼 뒤 깨끗히 지워지지 않은 경우),
            // `usesMacro`가 true가 되어 전체 동기화 시 0x74가 0x73을 덮어쓰고, 기기 동작이 화면의 ⌫와 달라집니다(ble-comm에서 「취소 키 매크로: …」로 확인할 수 있습니다).
            if mode == .mode1 {
                let oldDefaultApprove = ShortcutBinding(modifiers: [.command], keyCode: HIDUsage.enter)
                let oldDefaultReject = ShortcutBinding(modifiers: [.command], keyCode: HIDUsage.backspace)
                var approve1 = modeDraft.key(for: .approve)
                var reject1 = modeDraft.key(for: .reject)
                // 한 버전은 공장 기본값이 ⌘↵/⌘⌫였습니다. 현재 공장 기본값과 같을 때(기본 문구를 유지하고 매크로가 없을 때) 단일 키 ↵/⌫로 올립니다.
                if approve1.shortcut == oldDefaultApprove,
                   reject1.shortcut == oldDefaultReject,
                   approve1.description == "Accept",
                   reject1.description == "Reject",
                   approve1.macro.isEmpty,
                   reject1.macro.isEmpty
                {
                    let t = AhaKeyModeDraft.default(for: .mode1)
                    approve1.shortcut = t.key(for: .approve).shortcut
                    modeDraft.updateKey(approve1)
                    reject1.shortcut = t.key(for: .reject).shortcut
                    reject1.macro = t.key(for: .reject).macro
                    modeDraft.updateKey(reject1)
                }

                reject1 = modeDraft.key(for: .reject)
                let defaultCursorReject = AhaKeyModeDraft.default(for: .mode1).key(for: .reject)
                if !reject1.macro.isEmpty,
                   reject1.shortcut == defaultCursorReject.shortcut
                {
                    reject1.macro = []
                    modeDraft.updateKey(reject1)
                }
            }

            next.updateMode(modeDraft)
        }

        return next
    }
}
