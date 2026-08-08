import Foundation

// 플러그인 디렉터리의 매니페스트 파일(`plugin.json`)이며, 호스트가 이 플러그인을 어떻게 발견하고 시작하고 신뢰할지 결정합니다.
//
// 디렉터리 규칙:
//   ~/Library/Application Support/AhaKeyConfig/plugins/<id>/plugin.json
//
// 최소 예시:
// ```json
// {
//   "id": "com.example.hello",
//   "name": "Hello Plugin",
//   "version": "0.1.0",
//   "entrypoint": {
//     "command": "python3",
//     "args": ["${pluginDir}/main.py"]
//   },
//   "permissions": ["host/log", "host/getInfo"]
// }
// ```
//
// 설계 판단:
// - `entrypoint.command`는 절대 경로가 아니어도 됩니다. 호스트는 항상 `/usr/bin/env <command>` 형태로 실행하므로
//   시스템 PATH를 따릅니다. 실행 파일을 고정하고 싶다면 절대 경로를 쓰면 되고, env도 그대로 전달합니다.
// - `${pluginDir}`는 args / env에 쓰는 문자열 자리표시자이며, 해석 시 매니페스트가 있는 디렉터리의 절대 경로로 치환됩니다.
// - `permissions`는 허용 목록입니다. 이 목록에 있는 `host/*` method만 해당 플러그인이 호출할 수 있고,
//   선언되지 않은 것은 곧바로 method-not-found(-32601)로 응답합니다.

public struct PluginManifest: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let entrypoint: Entrypoint
    public let permissions: [String]

    /// 매니페스트 파일이 있는 디렉터리입니다(해석 시 loader가 주입하며, JSON으로 직렬화되지 않습니다).
    public var directory: URL = URL(fileURLWithPath: "/")

    public struct Entrypoint: Codable, Sendable, Equatable {
        public let command: String
        public let args: [String]
        public let env: [String: String]?

        public init(command: String, args: [String] = [], env: [String: String]? = nil) {
            self.command = command
            self.args = args
            self.env = env
        }
    }

    public init(
        id: String,
        name: String,
        version: String,
        entrypoint: Entrypoint,
        permissions: [String] = [],
        directory: URL = URL(fileURLWithPath: "/")
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.entrypoint = entrypoint
        self.permissions = permissions
        self.directory = directory
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, entrypoint, permissions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        entrypoint = try c.decode(Entrypoint.self, forKey: .entrypoint)
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        directory = URL(fileURLWithPath: "/")
    }
}

// MARK: - 로드

public enum PluginManifestError: Error, Sendable {
    case fileNotFound(URL)
    case decode(URL, String)
}

public extension PluginManifest {
    /// 디렉터리에서 `plugin.json`을 로드합니다. 해석에 실패하면 `PluginManifestError`를 던집니다.
    static func load(from directory: URL) throws -> PluginManifest {
        let url = directory.appendingPathComponent("plugin.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PluginManifestError.fileNotFound(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PluginManifestError.decode(url, "\(error)")
        }
        do {
            var manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            manifest.directory = directory
            return manifest
        } catch {
            throw PluginManifestError.decode(url, "\(error)")
        }
    }

    /// 문자열에 있는 모든 `${pluginDir}`를 매니페스트가 있는 디렉터리의 절대 경로로 치환합니다.
    func substitute(_ s: String) -> String {
        s.replacingOccurrences(of: "${pluginDir}", with: directory.path)
    }

    /// 해석이 끝나 `Process`에 바로 넘길 수 있는 자식 프로세스 정보입니다.
    var resolvedEntrypoint: ResolvedEntrypoint {
        ResolvedEntrypoint(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [entrypoint.command] + entrypoint.args.map(substitute),
            environment: entrypoint.env?.mapValues(substitute),
            workingDirectory: directory
        )
    }
}

public struct ResolvedEntrypoint: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let workingDirectory: URL
}
