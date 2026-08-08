import Foundation

/// 키보드 레버를 Codex `~/.codex/config.toml` 최상단의 **`approval_policy`** 와 맞춘다:
/// **자동 단계 → `"never"`**(승인 창을 띄우지 않고 바로 실행), **수동 단계 → `"untrusted"`**(순수 읽기 전용의
/// "이미 안전하다고 알려진" 명령을 제외하면 모두 멈추고 사용자에게 확인을 요청).
///
/// 주의: 프로젝트 수준의 `[projects."<path>"].trust_level` 은 해당 프로젝트 로컬의 `.codex/`
/// 설정 계층(config / hooks / rules)을 불러올지 여부만 제어하며, 승인 확인 창을 띄울지는 **결정하지 않는다**.
/// 그것은 `approval_policy` 의 역할이다(공식 문서: https://developers.openai.com/codex/config-reference 참고).
/// 초기 버전에서는 `trust_level` 만 바꾸면 레버가 Codex 를 제어할 수 있다고 잘못 판단했지만, 실제 테스트에서
/// 효과가 없어 `approval_policy` 로 변경했다.
///
/// `approval_policy` 의 값별 의미는 Codex 오픈소스 저장소의 소스 코드로 확인했다
/// (codex-rs/protocol/src/protocol.rs 의 `enum AskForApproval` 문서 주석):
///   - `untrusted`(UnlessTrusted): `is_safe_command()` 가 "이미 안전하다고 알려졌고 파일을 읽기만 하는" 명령으로
///     판정한 것만 자동으로 통과시키고, 나머지는 모두 사용자에게 확인한다. 이것이 "수동 단계에서 매 건 확인 요청"에 해당하는 값이다.
///   - `on-request`(OnRequest, 기본값): 모델이 언제 사용자에게 확인 요청할지 스스로 결정하며, 일반적인 샌드박스 내
///     명령은 확인 요청을 유발하지 않는다. 실제 테스트에서 이 값은 "수동 단계에서 매번 확인이 필요하다"는 요구를 만족하지 못했다(초기 버전에서 잘못 사용했다).
///   - `never`: 절대 확인 요청하지 않고, 실패해도 사용자에게 보고하지 않는다. 자동 단계에 해당한다.
/// Codex 의 `PermissionRequest` 훅 프로토콜 자체는 `ask`/`deny` 를 지원하지 않는다. 따라서
/// `KimiConfigLeverSync` 가 `default_yolo` 를 고쳐 쓰는 것과 마찬가지로, Codex 자체의 승인 정책
/// 스위치를 직접 고쳐 써야 레버가 실제로 제어권을 가질 수 있다.
enum CodexConfigLeverSync {
    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml", isDirectory: false)
    }

    static func apply(switchStateAuto: Bool) {
        let desired = switchStateAuto ? "never" : "untrusted"
        let desiredLine = "approval_policy = \"\(desired)\""

        let fm = FileManager.default
        guard fm.fileExists(atPath: configURL.path),
              let data = fm.contents(atPath: configURL.path),
              let raw = String(data: data, encoding: .utf8) else { return }

        var lines = raw.components(separatedBy: .newlines)

        // approval_policy 는 최상위 키이므로 첫 번째 `[section]` 보다 앞에 있어야 한다.
        var firstSectionIdx = lines.count
        for (idx, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                firstSectionIdx = idx
                break
            }
        }

        let pattern = #"^\s*approval_policy\s*="#
        let regex = try? NSRegularExpression(pattern: pattern)
        for idx in 0..<firstSectionIdx {
            let line = lines[idx]
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex?.firstMatch(in: line, range: range) != nil {
                if line.trimmingCharacters(in: .whitespaces) == desiredLine { return }
                lines[idx] = desiredLine
                write(lines.joined(separator: "\n"))
                return
            }
        }

        lines.insert(desiredLine, at: firstSectionIdx)
        write(lines.joined(separator: "\n"))
    }

    private static func write(_ raw: String) {
        guard let data = raw.data(using: .utf8) else { return }
        try? data.write(to: configURL, options: .atomic)
    }
}
