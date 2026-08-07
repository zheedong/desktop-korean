import Foundation

// 플러그인 디렉터리를 스캔해 매니페스트를 로드하고 모든 플러그인을 시작한 뒤 생명주기를 관리합니다.
//
// 기본 플러그인 디렉터리:
//   ~/Library/Application Support/AhaKeyConfig/plugins/<id>/plugin.json
//
// 환경 변수 `AHAKEY_PLUGINS_DIR`로 임시로 덮어쓸 수 있습니다(디버깅용).
//
// 플러그인 하나가 로드에 실패해도 다른 플러그인에는 영향을 주지 않습니다. 오류를 stderr에 기록하고 해당 id를 failed로 표시합니다.

public actor PluginManager {
    public struct LoadedPlugin: Sendable {
        public let manifest: PluginManifest
        public let host: PluginHost
        public let initialize: PluginInitializeResult?
    }

    public struct LoadFailure: Sendable {
        public let manifestDirectory: URL
        public let error: String
    }

    private let pluginsRoot: URL
    private let appInfo: HostAppInfo
    private var loaded: [String: LoadedPlugin] = [:]
    private(set) public var failures: [LoadFailure] = []

    public init(
        pluginsRoot: URL = PluginManager.defaultPluginsRoot,
        appInfo: HostAppInfo = .current()
    ) {
        self.pluginsRoot = pluginsRoot
        self.appInfo = appInfo
    }

    public static var defaultPluginsRoot: URL {
        if let override = ProcessInfo.processInfo.environment["AHAKEY_PLUGINS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/AhaKeyConfig/plugins",
                isDirectory: true
            )
    }

    // MARK: - Discover

    /// `pluginsRoot` 아래의 1단계 하위 디렉터리를 모두 스캔해 `plugin.json`이 있는 것만 골라냅니다.
    /// 오류를 던지지 않습니다(루트 디렉터리가 없으면 빈 배열).
    public func discover() -> [PluginManifest] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: pluginsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var out: [PluginManifest] = []
        for dir in entries {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            do {
                let manifest = try PluginManifest.load(from: dir)
                out.append(manifest)
            } catch {
                failures.append(.init(manifestDirectory: dir, error: "\(error)"))
                FileHandle.standardError.write(
                    Data("[PluginManager] skip \(dir.lastPathComponent): \(error)\n".utf8)
                )
            }
        }
        return out
    }

    // MARK: - Load / Unload

    /// 발견한 플러그인을 모두 로드합니다. 성공한 개수를 반환하며, 실패한 항목은 `failures`와 stderr에 기록합니다.
    @discardableResult
    public func loadAll() async -> Int {
        let manifests = discover()
        var ok = 0
        for m in manifests {
            do {
                try await load(manifest: m)
                ok += 1
            } catch {
                failures.append(.init(manifestDirectory: m.directory, error: "\(error)"))
                FileHandle.standardError.write(
                    Data("[PluginManager] load \(m.id) failed: \(error)\n".utf8)
                )
            }
        }
        return ok
    }

    public func load(manifest: PluginManifest) async throws {
        if loaded[manifest.id] != nil { return } // 멱등

        let ep = manifest.resolvedEntrypoint
        let client = PluginClient(
            executable: ep.executable,
            arguments: ep.arguments,
            environment: ep.environment,
            workingDirectory: ep.workingDirectory
        )
        let host = PluginHost(
            client: client,
            appInfo: appInfo,
            permissions: Set(manifest.permissions)
        )
        await host.registerDefaultHandlers()
        try await client.start()

        // 핸드셰이크
        let info = try await client.initialize(
            host: appInfo,
            hostMethods: PluginHost.availableHostMethods
        )
        try await client.sendInitialized()

        loaded[manifest.id] = LoadedPlugin(manifest: manifest, host: host, initialize: info)
    }

    public func unloadAll() async {
        for (_, p) in loaded {
            await p.host.client.shutdown()
            await p.host.client.stop()
        }
        loaded.removeAll()
    }

    // MARK: - 조회

    public func allLoaded() -> [LoadedPlugin] {
        Array(loaded.values)
    }

    public func plugin(id: String) -> LoadedPlugin? {
        loaded[id]
    }
}
