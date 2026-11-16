import Foundation
import Security

enum MonitorError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func numeric(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
}
func bytes(_ n: Double?) -> String {
    guard let n, n.isFinite, n >= 0 else { return "—" }
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var v = n; var index = 0
    while v >= 1024 && index < units.count - 1 { v /= 1024; index += 1 }
    return String(format: index == 0 ? "%.0f %@" : "%.1f %@", v, units[index])
}
func dateText(_ value: Any?) -> String {
    guard let n = numeric(value), n > 0 else { return "—" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: n))
}
struct Traffic {
    let total: Double
    let used: Double
    var remaining: Double { max(0, total - used) }
    var fraction: Double { used / total }
    init?(_ info: [String: Any]) {
        guard let total = numeric(info["plan_monthly_data"]), total > 0,
              let used = numeric(info["data_counter"]), used >= 0,
              let multiplier = numeric(info["monthly_data_multiplier"]), multiplier > 0,
              total.isFinite, used.isFinite, multiplier.isFinite,
              (total * multiplier).isFinite, (used * multiplier).isFinite else { return nil }
        self.total = total * multiplier; self.used = used * multiplier
    }
}

enum Endpoint: String, CaseIterable {
    case info = "getServiceInfo", live = "getLiveServiceInfo", usage = "getRawUsageStats"
    case audit = "getAuditLog", snapshots = "snapshot/list", backups = "backup/list"
    case policies = "getPolicyViolations", suspensions = "getSuspensionDetails", rate = "getRateLimitStatus"
    var title: String {
        switch self {
        case .info: return "基础信息"; case .live: return "实时状态"; case .usage: return "历史用量"
        case .audit: return "操作日志"; case .snapshots: return "快照"; case .backups: return "自动备份"
        case .policies: return "违规记录"; case .suspensions: return "暂停详情"; case .rate: return "API 配额"
        }
    }
}
struct APIClient {
    static func request(_ endpoint: Endpoint, veid: String, key: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.64clouds.com/v1/" + endpoint.rawValue)!)
        req.httpMethod = "POST"; req.timeoutInterval = 35
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed)! }
        req.httpBody = "veid=\(escape(veid))&api_key=\(escape(key))".data(using: .utf8)
        return req
    }
    static func decode(_ data: Data, status: Int) throws -> [String: Any] {
        guard status == 200 else { throw MonitorError.message("服务器返回 HTTP \(status)，请稍后重试。") }
        guard data.count <= 16 * 1024 * 1024 else { throw MonitorError.message("返回内容过大，请在 KiwiVM 查看。") }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any], let code = numeric(dict["error"]) else {
            throw MonitorError.message("API 响应格式不正确，未更新数据。")
        }
        guard code == 0 else { throw MonitorError.message("API 错误 \(Int(code))：\(dict["message"] as? String ?? "请求失败")") }
        return dict
    }
    static func fetch(_ endpoint: Endpoint, veid: String, key: String) async throws -> [String: Any] {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(endpoint, veid: veid, key: key))
        return try decode(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum Vault {
    static let service = "local.bandwagon.monitor"
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read(_ account: String) throws -> String? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw MonitorError.message("无法读取钥匙串（\(status)）。请重新填写 API Key。")
        }
        return text
    }
    static func save(_ key: String, account: String) throws {
        let q = query(account)
        let data = Data(key.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw MonitorError.message("钥匙串保存失败（\(added)）。") }
        } else if status != errSecSuccess { throw MonitorError.message("钥匙串保存失败（\(status)）。") }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MonitorError.message("钥匙串删除失败（\(status)）。") }
    }
}

func selfTest() throws {
    func check(_ ok: @autoclosure () -> Bool, _ name: String) throws {
        guard ok() else { throw MonitorError.message("FAIL: \(name)") }
        print("PASS: \(name)")
    }
    let t = Traffic(["plan_monthly_data": 1000, "data_counter": "250", "monthly_data_multiplier": 0.5])!
    try check(t.remaining == 375 && t.total == 500 && t.fraction == 0.25, "流量倍率同时用于额度与用量")
    try check(Traffic(["plan_monthly_data": 100, "data_counter": 120, "monthly_data_multiplier": 1])!.remaining == 0, "超额流量不显示负数")
    try check(Traffic(["plan_monthly_data": 0]) == nil && Traffic(["plan_monthly_data": 100, "data_counter": 2]) == nil, "缺少字段不伪造零用量")
    let req = APIClient.request(.info, veid: "123", key: "a+b&c=d ?")
    try check(req.url!.query == nil && req.httpMethod == "POST", "凭据不写入 URL")
    try check(String(data: req.httpBody!, encoding: .utf8) == "veid=123&api_key=a%2Bb%26c%3Dd%20%3F", "表单正确编码特殊字符")
    let valid = try APIClient.decode(Data("{\"error\":0,\"data_counter\":10}".utf8), status: 200)
    try check(numeric(valid["data_counter"]) == 10, "解析成功响应")
    for (body, status) in [("{\"error\":700001,\"message\":\"Invalid key\"}",200),("{}",200),("[]",200),("{\"error\":0}",429)] {
        var rejected = false
        do { _ = try APIClient.decode(Data(body.utf8), status: status) } catch { rejected = true }
        try check(rejected, "拒绝错误或无效响应 \(status) \(body)")
    }
    try check(bytes(1073741824) == "1.0 GiB" && bytes(nil) == "—", "字节显示与未知状态")
    try check(Endpoint.allCases.count == 9 && !Endpoint.allCases.contains { $0.rawValue.contains("exec") }, "仅包含九个查询接口")
}
