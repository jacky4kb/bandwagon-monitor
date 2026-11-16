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
    func dailyPoints(now: Date = Date()) -> [LocalDailyPoint] {
        let first = calendar.date(byAdding:.day,value:-89,to:calendar.startOfDay(for:now))!
        let last = calendar.dateInterval(of:.day,for:now)!.end
        return days.compactMap { key, day in
            let parts = key.split(separator:"-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = calendar.date(from:DateComponents(year:parts[0],month:parts[1],day:parts[2])),
                  dayKey(date) == key, date >= first, date < last,
                  day.uploaded.isFinite, day.downloaded.isFinite, day.uploaded >= 0, day.downloaded >= 0 else { return nil }
            return LocalDailyPoint(date:date,uploaded:day.uploaded,downloaded:day.downloaded,estimated:day.estimated)
        }.sorted { $0.date < $1.date }
    }
    func summary(now: Date = Date()) -> LocalTrafficSummary {
        let key = dayKey(now), month = String(dayKey(now).prefix(7))
        let today = days[key] ?? LocalDay()
        let monthly = days.filter { $0.key.hasPrefix(month + "-") }.values
        return LocalTrafficSummary(started:started,updated:sampled,todayUpload:today.uploaded,todayDownload:today.downloaded,monthUpload:monthly.reduce(0){$0+$1.uploaded},monthDownload:monthly.reduce(0){$0+$1.downloaded},estimated:today.estimated || monthly.contains{$0.estimated},discontinuities:discontinuities,timeZoneID:timeZoneID,interfaceCount:counters.count,dailyPoints:dailyPoints(now:now))
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
    var dailyPoints: [LocalDailyPoint]? = nil
    static var sample: LocalTrafficSummary {
        let now = Date()
        var archive = LocalTrafficArchive(started:Calendar.current.startOfDay(for:now).addingTimeInterval(-6*86400),sampled:now,boot:"demo",timeZoneID:TimeZone.current.identifier,counters:[:])
        let upload = [0.35,0.5,0.8,0.2,0.65,0.75,1.25]
        let download = [3.0,2.5,4.0,1.25,5.0,4.5,8.5]
        for i in 0..<7 {
            let date = archive.calendar.date(byAdding:.day,value:i-6,to:archive.calendar.startOfDay(for:now))!
            archive.days[archive.dayKey(date)] = LocalDay(uploaded:upload[i]*1073741824,downloaded:download[i]*1073741824)
        }
        var summary = archive.summary(now:now)
        summary.interfaceCount = 1
        return summary
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
        a.days["2025-02-03"] = LocalDay()
        a.days["invalid"] = LocalDay(uploaded:99)
        let points = a.dailyPoints(now:start.addingTimeInterval(3*86400))
        guard points.count == 3, points.last?.uploaded == 0,
              points.reduce(0,{$0+$1.uploaded}) == 300,
              !points.contains(where:{a.dayKey($0.date)=="2025-02-02"}) else { throw NSError(domain:"Daily graph",code:1) }
        let snapshotData = try JSONEncoder().encode(a.summary(now:start.addingTimeInterval(3*86400)))
        guard try JSONDecoder().decode(LocalTrafficSummary.self,from:snapshotData).dailyPoints?.count == 3 else { throw NSError(domain:"Daily snapshot",code:1) }
        print("PASS: 本机日图按记录时区排序、真实零值与缺失日期区分、汇总一致及快照编码")
        print("PASS: 本机基线不追溯、跨日跨月分配、持久化恢复、重启与计数器重置、接口替换")
    }
}
struct LocalTrafficCard: View {
    var summary: LocalTrafficSummary?
    var error: String? = nil
    var compact = false
    var details = true
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
            else if details {
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
