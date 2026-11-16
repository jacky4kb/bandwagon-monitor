import Foundation
import SwiftUI

struct LocalCounter: Codable {
    var index: UInt32
    var uploaded: UInt64
    var downloaded: UInt64
}
struct LocalDay: Codable {
    var uploaded: Double = 0
    var downloaded: Double = 0
    var estimated = false
}
struct LocalTrafficArchive: Codable {
    var started: Date
    var sampled: Date
    var boot: String
    var timeZoneID: String
    var counters: [String:LocalCounter]
    var days: [String:LocalDay] = [:]
    var discontinuities = 0
    var calendar: Calendar {
        var c = Calendar(identifier:.gregorian)
        c.timeZone = TimeZone(identifier:timeZoneID) ?? .current
        return c
    }
    func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year,.month,.day],from:date)
        return String(format:"%04d-%02d-%02d",c.year!,c.month!,c.day!)
    }
    mutating func record(_ next: [String:LocalCounter], boot newBoot: String, at now: Date) {
        defer { counters = next; boot = newBoot; sampled = now }
        guard newBoot == boot, now > sampled else { discontinuities += 1; return }
        var up: Double = 0, down: Double = 0
        for (name,value) in next {
            guard let previous = counters[name], previous.index == value.index else { discontinuities += 1; continue }
            guard value.uploaded >= previous.uploaded, value.downloaded >= previous.downloaded else { discontinuities += 1; continue }
            up += Double(value.uploaded - previous.uploaded)
            down += Double(value.downloaded - previous.downloaded)
        }
        if !Set(counters.keys).subtracting(next.keys).isEmpty { discontinuities += 1 }
        let duration = now.timeIntervalSince(sampled)
        var cursor = sampled
        let crossesDay = dayKey(sampled) != dayKey(now.addingTimeInterval(-0.001))
        while cursor < now {
            guard let midnight = calendar.dateInterval(of:.day,for:cursor)?.end, midnight > cursor else { break }
            let end = min(now,midnight)
            let weight = end.timeIntervalSince(cursor) / duration
            let key = dayKey(cursor)
            var day = days[key] ?? LocalDay()
            day.uploaded += up * weight; day.downloaded += down * weight
            day.estimated = day.estimated || (crossesDay && (up > 0 || down > 0))
            days[key] = day
            cursor = end
        }
    }
    func summary(now: Date = Date()) -> LocalTrafficSummary {
        let key = dayKey(now), month = String(dayKey(now).prefix(7))
        let today = days[key] ?? LocalDay()
        let monthly = days.filter { $0.key.hasPrefix(month + "-") }.values
        return LocalTrafficSummary(started:started,updated:sampled,todayUpload:today.uploaded,todayDownload:today.downloaded,monthUpload:monthly.reduce(0){$0+$1.uploaded},monthDownload:monthly.reduce(0){$0+$1.downloaded},estimated:today.estimated || monthly.contains{$0.estimated},discontinuities:discontinuities,timeZoneID:timeZoneID,interfaceCount:counters.count)
    }
}
struct LocalTrafficSummary: Codable {
    var started: Date
    var updated: Date
    var todayUpload: Double
    var todayDownload: Double
    var monthUpload: Double
    var monthDownload: Double
    var estimated: Bool
    var discontinuities: Int
    var timeZoneID: String
    var interfaceCount: Int
    static var sample: LocalTrafficSummary {
        LocalTrafficSummary(started:Date().addingTimeInterval(-3*86400),updated:Date(),todayUpload:1.25*1073741824,todayDownload:8.5*1073741824,monthUpload:4.5*1073741824,monthDownload:28.75*1073741824,estimated:false,discontinuities:0,timeZoneID:TimeZone.current.identifier,interfaceCount:1)
    }
}
enum LocalTrafficStore {
    static var path: URL? { WidgetStore.directory?.appendingPathComponent("local-traffic-history.json") }
    static func read() throws -> LocalTrafficArchive? {
        guard let path else { throw NSError(domain:"LocalTraffic",code:1) }
        guard FileManager.default.fileExists(atPath:path.path) else { return nil }
        return try JSONDecoder().decode(LocalTrafficArchive.self,from:Data(contentsOf:path))
    }
    static func write(_ value: LocalTrafficArchive) throws {
        guard let path else { throw NSError(domain:"LocalTraffic",code:1) }
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(value).write(to:path,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
    }
    static func test() throws {
        let start = Date(timeIntervalSince1970:1738367990) // 2025-01-31 23:59:50 UTC
        let baseline = LocalCounter(index:1,uploaded:1000,downloaded:2000)
        var a = LocalTrafficArchive(started:start,sampled:start,boot:"boot-a",timeZoneID:"GMT",counters:["en0":baseline])
        guard a.summary(now:start).todayUpload == 0 else { throw NSError(domain:"Baseline",code:1) }
        a.record(["en0":LocalCounter(index:1,uploaded:1200,downloaded:2400)],boot:"boot-a",at:start.addingTimeInterval(20))
        let summary = a.summary(now:start.addingTimeInterval(20))
        guard summary.todayUpload == 100, summary.monthDownload == 200, summary.estimated else { throw NSError(domain:"Month split",code:1) }
        let encoded = try JSONEncoder().encode(a)
        a = try JSONDecoder().decode(LocalTrafficArchive.self,from:encoded)
        a.record(["en0":LocalCounter(index:1,uploaded:1300,downloaded:2600)],boot:"boot-a",at:start.addingTimeInterval(50))
        guard a.summary(now:start.addingTimeInterval(50)).todayUpload == 200 else { throw NSError(domain:"Restart resume",code:1) }
        a.record(["en0":LocalCounter(index:1,uploaded:10,downloaded:20)],boot:"boot-b",at:start.addingTimeInterval(80))
        a.record(["en0":LocalCounter(index:1,uploaded:1,downloaded:2)],boot:"boot-b",at:start.addingTimeInterval(110))
        guard a.summary(now:start.addingTimeInterval(110)).todayUpload == 200, a.discontinuities == 2 else { throw NSError(domain:"Counter reset",code:1) }
        a.record(["en0":LocalCounter(index:2,uploaded:999999,downloaded:999999)],boot:"boot-b",at:start.addingTimeInterval(140))
        guard a.summary(now:start.addingTimeInterval(140)).todayUpload == 200 else { throw NSError(domain:"Interface replacement",code:1) }
        print("PASS: 本机基线不追溯、跨日跨月分配、持久化恢复、重启与计数器重置、接口替换")
    }
}
struct LocalTrafficCard: View {
    var summary: LocalTrafficSummary?
    var error: String? = nil
    var compact = false
    var body: some View {
        VStack(alignment:.leading,spacing:compact ? 6 : 12) {
            HStack {
                DashboardMetric(title:"今日上传",value:widgetBytes(summary?.todayUpload),compact:compact)
                DashboardMetric(title:"今日下载",value:widgetBytes(summary?.todayDownload),compact:compact)
            }
            HStack {
                DashboardMetric(title:"本月上传",value:widgetBytes(summary?.monthUpload),compact:compact)
                DashboardMetric(title:"本月下载",value:widgetBytes(summary?.monthDownload),compact:compact)
            }
            if compact { Text("本机网卡 · 从开始记录起").font(.system(size:8)).foregroundStyle(.secondary) }
            else {
                if let summary {
                    Text("开始记录：\(summary.started.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary)
                    Text("仅含开始记录后的用量；Wi-Fi / 有线网卡，包含局域网流量。与 VPS 统计独立，不代表本机经 VPS 的用量。").font(.caption).foregroundStyle(.secondary)
                    if summary.estimated { Text("跨日采样按时间比例分配，日/月归属含估算。").font(.caption).foregroundStyle(.orange) }
                    if summary.discontinuities > 0 { Text("曾遇到重启、网卡更换或计数重置；无法恢复的区间未补算。").font(.caption).foregroundStyle(.orange) }
                    if summary.interfaceCount == 0 { Text("当前没有可统计的 Wi-Fi / 有线网卡。").font(.caption).foregroundStyle(.orange) }
                } else { Text("等待本机首次采样，无需配置 VPS。").font(.caption).foregroundStyle(.secondary) }
            }
            if let error { Text(error).font(.system(size:compact ? 8 : 11)).foregroundStyle(.orange).lineLimit(compact ? 1 : nil) }
        }
    }
}
