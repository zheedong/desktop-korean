import AhaKeyPluginKit
import Foundation

// AhaKey Plugin 데모 실행 파일입니다. `AhaKeyPluginKit`을 SDK처럼 써서 manager 흐름을 한 번 훑습니다.
//   1. `~/Library/Application Support/AhaKeyConfig/plugins/`를 스캔
//      (또는 환경 변수 `AHAKEY_PLUGINS_DIR`로 지정한 디렉터리)
//   2. 매니페스트에 따라 각 플러그인을 시작하고 핸드셰이크 수행
//   3. 로드 결과 나열
//   4. 잠시 대기(플러그인이 host를 역방향으로 호출할 기회를 줌)
//   5. 전부 shutdown
//
// 실제 메인 앱은 `import AhaKeyPluginKit`으로 `PluginManager`를 바로 사용하며, 이 실행 파일에 의존하지 않습니다.
// 여기서는 `swift run Plugin`으로 실행할 수 있는 진입점을 제공해 로컬에서 골격을 검증하기 쉽게 할 뿐입니다.

@main
struct PluginDemoMain {
    static func main() async {
        let manager = PluginManager()
        let count = await manager.loadAll()

        let plugins = await manager.allLoaded()
        if plugins.isEmpty {
            FileHandle.standardError.write(Data(
                """
                [plugin-demo] no plugins loaded. \
                drop a plugin.json into \(PluginManager.defaultPluginsRoot.path) \
                or set AHAKEY_PLUGINS_DIR=<path> and rerun.

                """.utf8
            ))
        } else {
            FileHandle.standardError.write(Data(
                "[plugin-demo] loaded \(count) plugin(s):\n".utf8
            ))
            for p in plugins {
                let reported = p.initialize?.name ?? "<no name>"
                FileHandle.standardError.write(Data(
                    "  - \(p.manifest.id) v\(p.manifest.version) [plugin says: \(reported)]\n".utf8
                ))
            }
        }

        // 플러그인이 역방향 RPC 등을 할 수 있도록 1초를 준 뒤 shutdown 합니다.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await manager.unloadAll()
    }
}
