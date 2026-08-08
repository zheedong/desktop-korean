import Foundation

/// 로컬 개발 전용: scripts/fix-debug-permissions.sh를 호출해
/// 안정적인 자체 서명 인증서로 dist/AhaKey Studio.app을 재서명하고 TCC 권한을 초기화한다.
///
/// "로컬 개발 환경"을 판별하는 방법: app bundle의 형제 디렉터리에
/// scripts/fix-debug-permissions.sh가 있는지 확인한다. 소스에서 빌드한 dev 빌드만
/// 이 조건을 만족한다 —— /Applications에 정식 릴리스된 .app에는 형제
/// scripts/ 디렉터리가 없으므로 `isAvailable`이 false를 반환하고, UI에 버튼이 표시되지 않는다.
///
/// 이렇게 하면 `#if DEBUG` 매크로에 의존하지 않고 어떤 빌드 구성에서도 코드가 컴파일되지만,
/// 실제 진입점은 개발 환경에서만 노출된다.
enum DebugSigningFixer {
    struct Result {
        let success: Bool
        let output: String
    }

    /// 소스에 있는 수정 스크립트를 찾을 수 있을 때만 "사용 가능"으로 간주한다.
    /// 이것이 "개발 환경 vs 설치된 릴리스"를 런타임에 구분하는 기준이다.
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: scriptURL.path)
    }

    private static var scriptURL: URL {
        URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()  // .../dist/ 또는 설치 디렉터리
            .deletingLastPathComponent()  // .../ 프로젝트 루트 또는 /Applications
            .appendingPathComponent("scripts")
            .appendingPathComponent("fix-debug-permissions.sh")
    }

    static func run(completion: @escaping (Result) -> Void) {
        let script = scriptURL
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            completion(Result(
                success: false,
                output: "실행 가능한 스크립트를 찾을 수 없습니다: \(script.path)\n\n이 기능은 소스에서 실행하는 개발 빌드에서만 사용할 수 있습니다."
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let ok = process.terminationStatus == 0
                DispatchQueue.main.async {
                    completion(Result(
                        success: ok,
                        output: ok
                            ? output + "\n지금 바로 AhaKey Studio를 종료한 뒤 다시 실행하고, 시스템 안내에 따라 권한을 다시 허용해 주세요."
                            : "스크립트 실행 실패 (exit=\(process.terminationStatus))\n\n\(output)"
                    ))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(Result(
                        success: false,
                        output: "수정 스크립트를 실행할 수 없습니다: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }
}
