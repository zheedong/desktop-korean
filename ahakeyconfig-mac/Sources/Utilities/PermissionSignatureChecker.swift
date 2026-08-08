import Foundation

/// 앱 서명 변경을 감지하고 권한 문제를 처리한다.
///
/// 앱 서명이 바뀌면(재설치, 인증서 교체 등) macOS는 이를 새로운 앱으로 간주하지만,
/// 기존 TCC 승인 기록은 그대로 남아 있다. 마이크 권한은 시스템 설정에서 수동으로 추가할 수 있는
/// '+' 버튼이 없기 때문에, 사용자가 새로 서명된 앱을 직접 추가할 수 없다.
///
/// 이 유틸리티는 서명 변경을 감지하고 마이크 권한을 초기화하는 기능을 제공한다.
enum PermissionSignatureChecker {
    
    private static let lastSignatureKey = "AhaKey_LastSignatureHash"
    
    /// 현재 앱의 서명 해시를 가져온다.
    private static func currentSignatureHash() -> String? {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-dv", "--verbose=4", bundlePath]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // 서명 정보(cdhash) 추출
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    if let range = line.range(of: "cdhash=") {
                        let hash = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                        return hash
                    }
                }
            }
        } catch {
            print("Error getting signature: \(error)")
        }
        return nil
    }
    
    /// 서명이 변경되었는지 확인한다.
    static func hasSignatureChanged() -> Bool {
        guard let current = currentSignatureHash() else { return false }
        let last = UserDefaults.standard.string(forKey: lastSignatureKey)
        return last != current
    }
    
    /// 현재 서명을 저장한다.
    static func saveCurrentSignature() {
        if let current = currentSignatureHash() {
            UserDefaults.standard.set(current, forKey: lastSignatureKey)
        }
    }
    
    /// 마이크 권한을 초기화한다(sudo 필요).
    /// - Parameter completion: (success, message)
    static func resetMicrophonePermission(completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let bundleId = Bundle.main.bundleIdentifier ?? "lab.jawa.ahakeyconfig"
            
            print("[PermissionSignatureChecker] 마이크 권한 초기화 시작, bundleId: \(bundleId)")

            // 먼저 일반 모드로 초기화를 시도한다.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "Microphone", bundleId]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                print("[PermissionSignatureChecker] 일반 모드 tccutil 반환: \(task.terminationStatus), 출력: \(output)")

                if task.terminationStatus == 0 {
                    completion(true, "마이크 권한이 초기화되었습니다.")
                    return
                }

                // 일반 모드가 실패하면 sudo로 다시 시도한다.
                let sudoTask = Process()
                sudoTask.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                sudoTask.arguments = ["/usr/bin/tccutil", "reset", "Microphone", bundleId]
                
                let sudoPipe = Pipe()
                sudoTask.standardOutput = sudoPipe
                sudoTask.standardError = sudoPipe
                
                do {
                    try sudoTask.run()
                    sudoTask.waitUntilExit()
                    
                    let sudoData = sudoPipe.fileHandleForReading.readDataToEndOfFile()
                    let sudoOutput = String(data: sudoData, encoding: .utf8) ?? ""
                    
                    print("[PermissionSignatureChecker] sudo 모드 tccutil 반환: \(sudoTask.terminationStatus), 출력: \(sudoOutput)")

                    if sudoTask.terminationStatus == 0 {
                        completion(true, "마이크 권한이 초기화되었습니다(sudo 사용).")
                    } else {
                        completion(false, "초기화 실패:\n일반 모드: \(output)\nsudo 모드: \(sudoOutput)")
                    }
                } catch {
                    print("[PermissionSignatureChecker] sudo 실행 실패: \(error)")
                    completion(false, "sudo 실행 실패: \(error.localizedDescription)")
                }
            } catch {
                print("[PermissionSignatureChecker] 실행 실패: \(error)")
                completion(false, "실행 실패: \(error.localizedDescription)")
            }
        }
    }
    
    /// 서명 변경을 확인하고 처리한다.
    /// - Returns: 서명이 변경되어 처리가 필요하면 true
    static func checkAndHandleSignatureChange() -> Bool {
        if hasSignatureChanged() {
            saveCurrentSignature()
            return true
        }
        return false
    }
    
    /// 서명 변경을 확인하고 마이크 권한을 자동으로 초기화한다.
    static func checkAndResetOnSignatureChange(completion: @escaping (Bool) -> Void) {
        if hasSignatureChanged() {
            saveCurrentSignature()
            resetMicrophonePermission { success, _ in
                completion(success)
            }
        } else {
            completion(false)
        }
    }
}