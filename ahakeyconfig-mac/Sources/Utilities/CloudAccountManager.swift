import Foundation

@MainActor
final class CloudAccountManager: ObservableObject {
    static let shared = CloudAccountManager()

    @Published var phone = ""
    @Published var password = ""
    @Published var rememberPassword = false
    @Published var couponCode = ""
    @Published private(set) var isLoggedIn = false
    @Published private(set) var isBusy = false
    @Published private(set) var profile: [String: Any]?
    @Published private(set) var paymentOrder: CloudPaymentOrder?
    @Published private(set) var statusMessage = "아직 로그인하지 않았습니다."
    @Published var alertMessage: String?

    private let fallbackAPIBase = "https://956798.xyz/prod-api"
    private let tokenKey = "lab.jawa.ahakeyconfig.cloud.accessToken"
    private let rememberKey = "lab.jawa.ahakeyconfig.cloud.remember"
    private let phoneKey = "lab.jawa.ahakeyconfig.cloud.phone"
    private let passwordKey = "lab.jawa.ahakeyconfig.cloud.password"

    private init() {
        let defaults = UserDefaults.standard
        rememberPassword = defaults.bool(forKey: rememberKey)
        phone = defaults.string(forKey: phoneKey) ?? ""
        if rememberPassword {
            password = defaults.string(forKey: passwordKey) ?? ""
        }
        isLoggedIn = !accessToken.isEmpty
        if isLoggedIn {
            statusMessage = "로그인되었습니다. 사용자 정보 갱신을 기다리는 중입니다."
        }
    }

    func login() {
        authenticate(path: "api/v1/auth/login", successMessage: "로그인 성공.", fallbackError: "로그인 실패.")
    }

    func register() {
        authenticate(path: "api/v1/auth/register", successMessage: "회원가입 성공.", fallbackError: "회원가입 실패.")
    }

    func logout() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        AhaTypeTextOptimizer.shared.clearSessionKeepToggle()
        profile = nil
        isLoggedIn = false
        statusMessage = "로그아웃되었습니다."
    }

    func prepareForRelogin() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        profile = nil
        isLoggedIn = false
        statusMessage = "계정과 비밀번호를 입력해 다시 로그인하세요."
    }

    func refreshProfile(showAlertOnFailure: Bool = true) {
        guard !accessToken.isEmpty else {
            logout()
            return
        }
        isBusy = true
        statusMessage = "사용자 정보를 갱신하는 중…"
        Task {
            defer { Task { @MainActor in self.isBusy = false } }
            do {
                let object = try await request(path: "api/v1/auth/users/me", method: "GET", body: nil, authorized: true)
                let data = try payloadData(from: object, fallbackError: "사용자 정보 가져오기 실패")
                await MainActor.run {
                    self.applyProfile(data)
                    self.statusMessage = "사용자 정보를 갱신했습니다."
                }
            } catch {
                await MainActor.run {
                    if showAlertOnFailure {
                        self.alertMessage = error.localizedDescription
                        self.statusMessage = "갱신 실패."
                    } else {
                        self.statusMessage = "로그인되었습니다. 사용자 정보는 나중에 갱신할 수 있습니다."
                    }
                    if showAlertOnFailure, (error as? CloudAccountError)?.statusCode == 401 {
                        self.logout()
                    }
                }
            }
        }
    }

    func redeemCoupon() {
        let code = couponCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            alertMessage = "교환 코드를 입력하세요."
            return
        }
        isBusy = true
        statusMessage = "무료 쿠폰을 교환하는 중…"
        Task {
            defer { Task { @MainActor in self.isBusy = false } }
            do {
                let object = try await request(path: "api/v1/coupon/redeem", method: "POST", body: ["code": code], authorized: true)
                let data = try payloadData(from: object, fallbackError: "교환 실패")
                await MainActor.run {
                    self.couponCode = ""
                    self.applyProfile(data)
                    self.statusMessage = "교환 성공."
                    self.alertMessage = "무료 쿠폰이 적용되었습니다."
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = error.localizedDescription
                    self.statusMessage = "교환 실패."
                }
            }
        }
    }

    func createWechatOrder(plan: CloudRechargePlan) {
        guard isLoggedIn else {
            alertMessage = "먼저 로그인한 뒤 충전해 주세요."
            return
        }
        isBusy = true
        statusMessage = "위챗페이 결제 주문을 생성하는 중…"
        Task {
            defer { Task { @MainActor in self.isBusy = false } }
            do {
                let object = try await request(
                    path: "api/v1/payment/wechat/native",
                    method: "POST",
                    body: ["plan": plan.rawValue, "description": plan.orderDescription],
                    authorized: true
                )
                let data = try payloadData(from: object, fallbackError: "결제 주문 생성 실패")
                let codeURL = firstString(in: data, keys: ["code_url", "codeUrl"])
                let h5URL = firstString(in: data, keys: ["h5_url", "h5Url", "mweb_url", "mwebUrl"])
                let outTradeNo = firstString(in: data, keys: ["out_trade_no", "outTradeNo"])
                guard !outTradeNo.isEmpty else { throw CloudAccountError("클라우드에서 주문 번호를 반환하지 않아 결제 상태를 조회할 수 없습니다.") }
                guard !codeURL.isEmpty || !h5URL.isEmpty else { throw CloudAccountError("클라우드에서 결제 가능한 링크를 반환하지 않았습니다.") }
                let amountFen = firstInt(in: data, keys: ["amount_fen", "amountFen"])
                await MainActor.run {
                    self.paymentOrder = CloudPaymentOrder(
                        plan: plan,
                        amountFen: amountFen,
                        outTradeNo: outTradeNo,
                        codeURL: codeURL,
                        h5URL: h5URL,
                        status: "pending"
                    )
                    self.statusMessage = "주문이 생성되었습니다. 위챗에서 QR 코드를 스캔해 결제하세요."
                    self.pollPaymentStatus(outTradeNo: outTradeNo)
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = error.localizedDescription
                    self.statusMessage = "결제 주문 생성 실패."
                }
            }
        }
    }

    func clearPaymentOrder() {
        paymentOrder = nil
        statusMessage = "결제 주문을 닫았습니다."
    }

    func refreshCurrentPaymentOrder() {
        guard let order = paymentOrder else {
            refreshProfile()
            return
        }
        isBusy = true
        statusMessage = "주문 상태를 조회하는 중…"
        Task {
            defer { Task { @MainActor in self.isBusy = false } }
            do {
                let status = try await fetchPaymentStatus(outTradeNo: order.outTradeNo)
                await MainActor.run {
                    _ = self.applyPaymentStatus(status, outTradeNo: order.outTradeNo, notifyPending: true)
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = error.localizedDescription
                    self.statusMessage = "주문 상태 조회 실패."
                }
            }
        }
    }

    var profileSummary: String {
        guard let profile else { return isLoggedIn ? "로그인되었습니다. 새로고침을 눌러 사용자 정보를 가져오세요." : "로그인하면 AhaType 클라우드 정리를 사용할 수 있습니다." }
        let phone = stringValue(profile["phone"])
        let validUntil = stringValue(profile["token_valid_until"])
        return [
            phone.isEmpty ? "" : "휴대폰 번호: \(phone)",
            validUntil.isEmpty ? "유효 기간: 없음" : "유효 기간: \(validUntil)",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func quotaText(_ period: String) -> String {
        guard let profile else { return "없음" }
        let used = intValue(profile["used_\(period)"])
        let limit = intValue(profile["limit_\(period)"])
        if limit <= 0 {
            return used > 0 ? "\(used) 사용 · 무제한" : "없음"
        }
        return "\(used) / \(limit)"
    }

    func priceText(for plan: CloudRechargePlan) -> String {
        let fallback = plan.fallbackAmountFen
        guard let prices = (profile?["policy"] as? [String: Any])?["recharge_prices_fen"] as? [String: Any] else {
            return formatFen(fallback)
        }
        let amount = intValue(prices[plan.rawValue])
        return formatFen(amount > 0 ? amount : fallback)
    }

    private func pollPaymentStatus(outTradeNo: String) {
        Task {
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.paymentOrder?.outTradeNo != outTradeNo { return }
                do {
                    let status = try await fetchPaymentStatus(outTradeNo: outTradeNo)
                    let finished = await MainActor.run {
                        self.applyPaymentStatus(status, outTradeNo: outTradeNo, notifyPending: false)
                    }
                    if finished {
                        return
                    }
                } catch {
                    // 폴링 중 한 번의 실패는 허용해 네트워크 불안정으로 결제 흐름이 끊기지 않도록 합니다.
                    continue
                }
            }
            await MainActor.run {
                if self.paymentOrder?.outTradeNo == outTradeNo {
                    self.statusMessage = "결제 대기 시간이 초과되었습니다. 나중에 사용자 정보를 갱신해 입금을 확인할 수 있습니다."
                }
            }
        }
    }

    private func fetchPaymentStatus(outTradeNo: String) async throws -> String {
        let encoded = outTradeNo.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? outTradeNo
        let path = "api/v1/payment/wechat/order-status?outTradeNo=\(encoded)"
        let object = try await request(path: path, method: "GET", body: nil, authorized: true)
        let data = try payloadData(from: object, fallbackError: "주문 상태 조회 실패")
        return normalizedPaymentStatus(from: data)
    }

    @discardableResult
    private func applyPaymentStatus(_ status: String, outTradeNo: String, notifyPending: Bool) -> Bool {
        let normalized = status.isEmpty ? "pending" : status
        if var order = paymentOrder, order.outTradeNo == outTradeNo {
            order.status = normalized
            paymentOrder = order
        }
        if isPaidPaymentStatus(normalized) {
            statusMessage = "충전 성공. 사용 한도를 갱신하는 중입니다."
            paymentOrder = nil
            refreshProfile()
            return true
        }
        if isFailedPaymentStatus(normalized) {
            statusMessage = "주문 결제 실패."
            alertMessage = "주문이 실패로 표시되었습니다. 충전을 다시 시작해 주세요."
            return true
        }
        statusMessage = "주문 입금이 아직 확인되지 않았습니다. 잠시 후 다시 새로고침하세요."
        if notifyPending {
            alertMessage = "현재 주문의 입금이 아직 확인되지 않았습니다. 위챗페이 결제가 완료되었는지 확인한 뒤 새로고침하세요."
        }
        return false
    }

    private func authenticate(path: String, successMessage: String, fallbackError: String) {
        let p = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !password.isEmpty else {
            alertMessage = "휴대폰 번호와 비밀번호를 입력하세요."
            return
        }
        isBusy = true
        statusMessage = "클라우드 계정에 요청하는 중…"
        Task {
            defer { Task { @MainActor in self.isBusy = false } }
            do {
                let object = try await request(path: path, method: "POST", body: ["phone": p, "password": password], authorized: false)
                let data = try payloadData(from: object, fallbackError: fallbackError)
                let token = firstString(in: data, keys: ["access_token", "token"])
                guard !token.isEmpty else { throw CloudAccountError("클라우드에서 access_token을 반환하지 않았습니다.") }
                await MainActor.run {
                    self.saveLogin(token: token, authData: data)
                    self.statusMessage = successMessage
                }
                await MainActor.run {
                    self.refreshProfile(showAlertOnFailure: false)
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = error.localizedDescription
                    self.statusMessage = "계정 요청 실패."
                }
            }
        }
    }

    private func saveLogin(token: String, authData: [String: Any] = [:]) {
        let defaults = UserDefaults.standard
        defaults.set(token, forKey: tokenKey)
        defaults.set(rememberPassword, forKey: rememberKey)
        defaults.set(phone.trimmingCharacters(in: .whitespacesAndNewlines), forKey: phoneKey)
        if rememberPassword {
            defaults.set(password, forKey: passwordKey)
        } else {
            defaults.removeObject(forKey: passwordKey)
        }
        AhaTypeTextOptimizer.shared.patchCloudToken(token)
        seedLocalProfile(token: token, authData: authData)
        isLoggedIn = true
    }

    private func applyProfile(_ profile: [String: Any]) {
        let normalized = normalizedProfile(profile)
        self.profile = normalized
        isLoggedIn = true
        AhaTypeTextOptimizer.shared.patchCloudToken(accessToken)
        AhaTypeTextOptimizer.shared.setUserProfile(normalized)
    }

    private func seedLocalProfile(token: String, authData: [String: Any]) {
        var profile = normalizedProfile(authData)
        let phoneValue = firstString(in: authData, keys: ["phone", "mobile", "username"])
        profile["phone"] = phoneValue.isEmpty ? phone.trimmingCharacters(in: .whitespacesAndNewlines) : phoneValue
        let userID = firstString(in: authData, keys: ["id", "user_id", "userId"])
        if !userID.isEmpty {
            profile["user_id"] = userID
            profile["id"] = userID
        }
        if let validUntil = jwtExpirationString(token) {
            profile["token_valid_until"] = validUntil
        }
        profile["limit_daily"] = firstInt(in: authData, keys: ["limit_daily", "limitDaily"])
        profile["limit_weekly"] = firstInt(in: authData, keys: ["limit_weekly", "limitWeekly"])
        profile["limit_monthly"] = firstInt(in: authData, keys: ["limit_monthly", "limitMonthly"])
        profile["used_daily"] = firstInt(in: authData, keys: ["used_daily", "usedDaily"])
        profile["used_weekly"] = firstInt(in: authData, keys: ["used_weekly", "usedWeekly"])
        profile["used_monthly"] = firstInt(in: authData, keys: ["used_monthly", "usedMonthly"])
        self.profile = profile
        AhaTypeTextOptimizer.shared.setUserProfile(profile)
    }

    private func normalizedProfile(_ raw: [String: Any]) -> [String: Any] {
        var profile = raw
        let aliases: [(String, String)] = [
            ("id", "userId"),
            ("user_id", "userId"),
            ("token_valid_until", "tokenValidUntil"),
            ("limit_daily", "limitDaily"),
            ("limit_weekly", "limitWeekly"),
            ("limit_monthly", "limitMonthly"),
            ("used_daily", "usedDaily"),
            ("used_weekly", "usedWeekly"),
            ("used_monthly", "usedMonthly"),
        ]
        for (snake, camel) in aliases where profile[snake] == nil {
            if let value = raw[camel] {
                profile[snake] = value
            }
        }
        if stringValue(profile["token_valid_until"]).isEmpty, let validUntil = jwtExpirationString(accessToken) {
            profile["token_valid_until"] = validUntil
        }
        if var policy = profile["policy"] as? [String: Any] {
            let policyAliases: [(String, String)] = [
                ("recharge_prices_fen", "rechargePricesFen"),
                ("default_limit_daily", "defaultLimitDaily"),
                ("default_limit_weekly", "defaultLimitWeekly"),
                ("default_limit_monthly", "defaultLimitMonthly"),
                ("enable_daily", "enableDaily"),
                ("enable_weekly", "enableWeekly"),
                ("enable_monthly", "enableMonthly"),
            ]
            for (snake, camel) in policyAliases where policy[snake] == nil {
                if let value = policy[camel] {
                    policy[snake] = value
                }
            }
            profile["policy"] = policy
        }
        return profile
    }

    private func request(path: String, method: String, body: [String: Any]?, authorized: Bool) async throws -> [String: Any] {
        guard let url = URL(string: "\(apiBase)/\(path)") else {
            throw CloudAccountError("클라우드 주소가 유효하지 않습니다.")
        }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudAccountError(networkMessage(for: error))
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudAccountError("서버가 JSON이 아닌 응답을 반환했습니다.", statusCode: statusCode)
        }
        if statusCode != 200 {
            throw CloudAccountError(responseMessage(object).isEmpty ? "요청 실패(HTTP \(statusCode))." : responseMessage(object), statusCode: statusCode)
        }
        return object
    }

    private func payloadData(from object: [String: Any], fallbackError: String) throws -> [String: Any] {
        let code = intValue(object["code"])
        guard code == 0 || code == 200 else {
            let msg = responseMessage(object)
            throw CloudAccountError(msg.isEmpty ? fallbackError : msg)
        }
        return object["data"] as? [String: Any] ?? [:]
    }

    private var accessToken: String {
        UserDefaults.standard.string(forKey: tokenKey) ?? ""
    }

    private var apiBase: String {
        for key in ["VIBE_TYPELESS_API_BASE", "VIBE_API_BASE"] {
            let v = normalizeAPIBase(ProcessInfo.processInfo.environment[key] ?? "")
            if !v.isEmpty { return v }
        }
        return normalizeAPIBase(fallbackAPIBase)
    }

    private func normalizeAPIBase(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if !value.isEmpty, !value.contains("://") {
            value = "https://\(value)"
        }
        return value
    }

    private func stringValue(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String {
        for key in keys {
            let value = stringValue(object[key]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return ""
    }

    private func firstInt(in object: [String: Any], keys: [String]) -> Int {
        for key in keys {
            let value = intValue(object[key])
            if value != 0 { return value }
        }
        return 0
    }

    private func normalizedPaymentStatus(from data: [String: Any]) -> String {
        firstString(in: data, keys: ["status", "tradeState", "trade_state", "payStatus", "pay_status", "orderStatus", "order_status"])
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private func isPaidPaymentStatus(_ status: String) -> Bool {
        let normalized = status.lowercased().replacingOccurrences(of: "-", with: "_")
        return [
            "paid",
            "success",
            "succeeded",
            "complete",
            "completed",
            "pay_success",
            "trade_success",
            "wechat_success",
            "finished",
            "done",
            "1",
        ].contains(normalized)
    }

    private func isFailedPaymentStatus(_ status: String) -> Bool {
        let normalized = status.lowercased().replacingOccurrences(of: "-", with: "_")
        return [
            "failed",
            "failure",
            "fail",
            "closed",
            "cancelled",
            "canceled",
            "expired",
            "timeout",
            "trade_closed",
            "pay_error",
            "2",
        ].contains(normalized)
    }

    private func responseMessage(_ object: [String: Any]) -> String {
        firstString(in: object, keys: ["errorMsg", "msg", "message", "error"])
    }

    private func jwtExpirationString(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let exp = Double(intValue(object["exp"]))
        guard exp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: exp)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func intValue(_ value: Any?) -> Int {
        switch value {
        case let int as Int: return int
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string) ?? 0
        default: return 0
        }
    }

    private func formatFen(_ fen: Int) -> String {
        String(format: "%.2f 위안", Double(max(0, fen)) / 100.0)
    }

    private func networkMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "클라우드 연결 실패: \(error.localizedDescription)"
        }
        switch urlError.code {
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            return "클라우드 연결 실패: TLS/SSL 검증을 통과하지 못했습니다. 시스템 시간과 네트워크 프록시/인증서를 확인하거나, 클라우드 HTTPS 인증서 설정이 정상인지 확인하세요."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost, .timedOut:
            return "클라우드 연결 실패: 현재 네트워크에서 AhaType 서비스에 접속할 수 없습니다. 네트워크를 확인한 뒤 다시 시도하세요."
        default:
            return "클라우드 연결 실패: \(urlError.localizedDescription)"
        }
    }
}

struct CloudAccountError: LocalizedError {
    let message: String
    let statusCode: Int?

    init(_ message: String, statusCode: Int? = nil) {
        self.message = message
        self.statusCode = statusCode
    }

    var errorDescription: String? { message }
}

enum CloudRechargePlan: String, CaseIterable, Identifiable {
    case monthly
    case quarterly
    case yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthly: return "월간 구독"
        case .quarterly: return "분기 구독"
        case .yearly: return "연간 구독"
        }
    }

    var subtitle: String {
        switch self {
        case .monthly: return "30일"
        case .quarterly: return "90일"
        case .yearly: return "365일"
        }
    }

    var orderDescription: String {
        switch self {
        case .monthly: return "월간 충전"
        case .quarterly: return "분기 충전"
        case .yearly: return "연간 충전"
        }
    }

    var fallbackAmountFen: Int {
        switch self {
        case .monthly: return 100
        case .quarterly: return 270
        case .yearly: return 999
        }
    }
}

struct CloudPaymentOrder: Equatable {
    let plan: CloudRechargePlan
    let amountFen: Int
    let outTradeNo: String
    let codeURL: String
    let h5URL: String
    var status: String

    var paymentURL: String {
        codeURL.isEmpty ? h5URL : codeURL
    }

    var amountText: String {
        String(format: "%.2f 위안", Double(max(0, amountFen)) / 100.0)
    }
}
