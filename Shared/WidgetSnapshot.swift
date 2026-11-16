import Foundation

struct WidgetSnapshot: Codable {
    var configured = false
    var updated: Date?
    var hostname = "搬瓦工 VPS"
    var remaining: Double?
    var total: Double?
    var used: Double?
    var reset: Double?
    var state = "—"
    var load = "—"
    var availableRAM: Double?
    var totalRAM: Double?
    var availableSwap: Double?
    var totalSwap: Double?
    var mappedDisk: Double?
    var diskQuota: Double?
    var cpuThrottled: Bool?
    var diskThrottled: Bool?
    var suspended: Bool?
    var violation: Bool?
    var location = "—"
    var addresses: [String] = []
    var sshPort = "—"
    var plan = "—"
    var os = "—"
    var error: String?
    var instanceID: String?
    var trend: [UsagePoint]?
    var trendUpdated: Date?
    static var sample: WidgetSnapshot {
        var s = WidgetSnapshot()
        s.configured = true; s.updated = Date(); s.hostname = "示例 VPS"
        s.total = 1000 * 1073741824; s.used = 270 * 1073741824; s.remaining = 730 * 1073741824
        s.reset = Date().addingTimeInterval(12 * 86400).timeIntervalSince1970
        s.state = "运行中"; s.load = "0.08 0.12 0.09"
        s.availableRAM = 1.4 * 1073741824; s.totalRAM = 2 * 1073741824
        s.mappedDisk = 12 * 1073741824; s.diskQuota = 40 * 1073741824
        s.cpuThrottled = false; s.diskThrottled = false; s.suspended = false; s.violation = false
        s.location = "US, Los Angeles"; s.addresses = ["192.0.2.10"]; s.sshPort = "22"
        s.trend = []
        for i in 0..<7 {
            let date = Calendar.current.startOfDay(for:Date().addingTimeInterval(Double(i - 6)*86400))
            let incoming = Double([2,4,1,5,3,7,2][i]) * 1073741824.0
            let outgoing = Double([4,5,3,6,8,4,3][i]) * 1073741824.0
            s.trend?.append(UsagePoint(time:date,incoming:incoming,outgoing:outgoing))
        }
        s.trendUpdated = Date()
        return s
    }
}
enum WidgetStore {
    static var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "MonitorAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
    static func read() -> WidgetSnapshot {
        guard let path = directory?.appendingPathComponent("widget-snapshot.json"), let data = try? Data(contentsOf: path), let value = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return WidgetSnapshot() }
        return value
    }
    static func write(_ snapshot: WidgetSnapshot) throws {
        guard let dir = directory else { throw NSError(domain: "BandwagonWidget", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问小组件共享容器，请检查应用签名。"] ) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("widget-snapshot.json")
        try JSONEncoder().encode(snapshot).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
func widgetBytes(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    var n = value; var index = 0
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    while n >= 1024 && index < 4 { n /= 1024; index += 1 }
    return String(format: index == 0 ? "%.0f %@" : "%.3f %@", n, units[index])
}
