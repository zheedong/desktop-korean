import SwiftUI

/// 개별 키의 매핑 설정
struct KeyConfig: Codable {
    var hidCode: UInt8 = 0
    var description: String = ""

    var displayName: String {
        hidCode == 0 ? "설정 안 됨" : HIDUsage.name(for: hidCode)
    }
}

/// 키 배열 설정 영구 저장
enum KeyConfigStore {
    private static let key = "keyMappingConfig"

    static func save(_ keys: [KeyConfig]) {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> [KeyConfig]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let configs = try? JSONDecoder().decode([KeyConfig].self, from: data),
              configs.count == 4 else { return nil }
        return configs
    }
}

struct KeyMappingView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager

    @State private var selectedKey = 0
    @State private var keys: [KeyConfig] = KeyConfigStore.load() ?? [
        KeyConfig(hidCode: HIDUsage.capsLock, description: "녹음"),
        KeyConfig(hidCode: HIDUsage.enter, description: "Enter"),
        KeyConfig(hidCode: HIDUsage.escape, description: "취소"),
        KeyConfig(hidCode: HIDUsage.backspace, description: "Backspace"),
    ]
    @State private var showWriteSuccess = false

    private let keyLabels = ["Key 1\n🎤", "Key 2\n✓", "Key 3\n✗", "Key 4\n⌫"]

    var body: some View {
        Form {
            // MARK: - 키 선택
            Section("키 매핑") {
                HStack(spacing: 12) {
                    ForEach(0..<4) { index in
                        Button {
                            selectedKey = index
                        } label: {
                            VStack(spacing: 4) {
                                Text(keyLabels[index])
                                    .font(.system(.body, design: .rounded))
                                    .multilineTextAlignment(.center)
                                Text(keys[index].displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedKey == index
                                          ? Color.accentColor.opacity(0.15)
                                          : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selectedKey == index
                                                  ? Color.accentColor
                                                  : Color.primary.opacity(0.1), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // MARK: - 선택한 키 편집
            Section("Key \(selectedKey + 1) 설정") {
                Picker("키 코드", selection: $keys[selectedKey].hidCode) {
                    Text("설정 안 됨").tag(UInt8(0))
                    ForEach(HIDUsage.allOptions, id: \.code) { option in
                        Text("\(option.name)  (\(String(format: "0x%02X", option.code)))")
                            .tag(option.code)
                    }
                }

                CompatLabeledContent("설명") {
                    TextField("키보드 LCD에 표시됩니다", text: $keys[selectedKey].description)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }

            // MARK: - 프리셋
            Section {
                HStack {
                    Button("EchoWrite 추천") {
                        applyEchoWritePreset()
                    }
                    .buttonStyle(.bordered)
                    .help("Key1=F18(EchoWrite) Key2=Enter Key3=Escape Key4=Enter")

                    Button("기본값 복원") {
                        applyDefaultPreset()
                    }
                    .buttonStyle(.bordered)
                    .help("공장 기본 키 배열로 복원")
                }
            } header: {
                Text("프리셋")
            } footer: {
                Text("EchoWrite 추천: Key1은 F18을 전송해 EchoWrite 녹음을 시작하고, Key2/4는 확인, Key3은 취소입니다.")
                    .font(.caption)
            }

            // MARK: - 기기에 쓰기
            if bleManager.isConnected {
                Section {
                    HStack {
                        Button("모든 키 배열을 기기에 적용") {
                            writeAllKeys()
                        }
                        .buttonStyle(.borderedProminent)

                        if showWriteSuccess {
                            Label("전송 완료", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                }
            } else {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("먼저 AhaKey 기기를 연결하세요")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }

    }

    // MARK: - Actions

    private func applyEchoWritePreset() {
        keys = [
            KeyConfig(hidCode: HIDUsage.f18, description: "EchoWrite"),
            KeyConfig(hidCode: HIDUsage.enter, description: "Enter"),
            KeyConfig(hidCode: HIDUsage.escape, description: "Cancel"),
            KeyConfig(hidCode: HIDUsage.enter, description: "Enter"),
        ]
        KeyConfigStore.save(keys)
    }

    private func applyDefaultPreset() {
        keys = [
            KeyConfig(hidCode: HIDUsage.capsLock, description: "CapsLock"),
            KeyConfig(hidCode: HIDUsage.enter, description: "Enter"),
            KeyConfig(hidCode: HIDUsage.escape, description: "Escape"),
            KeyConfig(hidCode: HIDUsage.enter, description: "Enter"),
        ]
        KeyConfigStore.save(keys)
    }

    private func writeAllKeys() {
        for (index, key) in keys.enumerated() {
            guard key.hidCode != 0 else { continue }
            let keyIndex = UInt8(index)
            bleManager.setKeyMapping(keyIndex: keyIndex, hidCodes: [key.hidCode])
            if !key.description.isEmpty {
                bleManager.setKeyDescription(keyIndex: keyIndex, text: key.description)
            }
        }
        // 쓰기 완료 후 Flash에 저장 + 로컬 영구 저장
        bleManager.saveConfig()
        KeyConfigStore.save(keys)
        showWriteSuccess = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Double(3) * 1_000_000_000))
            showWriteSuccess = false
        }
    }
}
