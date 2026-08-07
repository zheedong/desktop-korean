import Foundation

/// app bundle에 내장된 기본 LCD 소재에 접근한다.
/// 리소스는 scripts/build-debug.sh가 프로젝트 루트의 Resources/DefaultOLED/에서
/// AhaKey Studio.app/Contents/Resources/DefaultOLED/로 복사한다.
enum DefaultOLEDAssets {
    private static let subdirectory = "DefaultOLED"

    /// 각 Mode에 프로젝트에서 미리 지정한 공장 기본 GIF 파일 이름(확장자 제외).
    /// 내장 소재가 없는 Mode는 nil을 반환하며, 사용자 지정 또는 펌웨어 측 기본 애니메이션을 사용한다.
    static func bundledFileName(for mode: AhaKeyModeSlot) -> String? {
        switch mode {
        case .mode0:
            return "claude_0"
        case .mode1:
            return "cursor"
        case .mode2:
            return "codex"
        case .mode3:
            return nil
        }
    }

    /// bundle 내 해당 GIF의 절대 파일 경로를 구한다. 리소스가 없으면 nil을 반환한다.
    static func bundledAssetPath(for mode: AhaKeyModeSlot) -> String? {
        guard let name = bundledFileName(for: mode) else { return nil }
        return bundledAssetPath(forName: name)
    }

    /// 이름으로 bundle 안의 .gif를 찾아 절대 경로를 반환한다.
    static func bundledAssetPath(forName name: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: "gif", subdirectory: subdirectory)?.path
    }

    /// 특정 localAssetPath가 bundle 내장 소재를 가리키는지 판단한다.
    /// 마이그레이션 로직용: 사용자의 초안이 더 이상 유효하지 않은 bundle 경로(예: app 위치 변경, mode 변경)를 참조할 때 안전하게 다시 쓸 수 있다.
    static func isBundledPath(_ path: String) -> Bool {
        guard let resourcesURL = Bundle.main.resourceURL else { return false }
        let resourcesPath = resourcesURL.appendingPathComponent(subdirectory).path
        return path.hasPrefix(resourcesPath + "/")
    }
}
