import Foundation
import SwiftUI
import Charts

struct MemoryUsage {
    let total: Double
    let available: Double
    var used: Double { total - available }
    var percent: Double { used / total * 100 }
    init?(total: Double?, available: Double?) {
        guard let total, let available, total.isFinite, available.isFinite, total > 0, available >= 0, available <= total else { return nil }
        self.total = total; self.available = available
    }
}
func memoryPercent(_ usage: MemoryUsage?) -> String { usage.map { String(format:"%.1f%%",$0.percent) } ?? "—" }

struct ResourcePoint: Codable, Identifiable {
    var time: Date
    var load: Double?
    var availableRAM: Double?
    var totalRAM: Double? = nil
    var cpuPercent: Double? = nil
    var memory: MemoryUsage? { MemoryUsage(total:totalRAM,available:availableRAM) }
    var id: Date { time }
}
struct ResourceArchive: Codable {
    var instanceID: String
    var points: [ResourcePoint]
    var cpuPoints: [ResourcePoint]? = nil
}
enum ResourceHistory {
    static let retention: TimeInterval = 30 * 86400
    static func sample(_ live: [String: Any], now: Date = Date()) -> ResourcePoint? {
        guard (live["ve_status"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() == "running" else { return nil }
        let load = (live["load_average"] as? String)?.split(whereSeparator: { $0.isWhitespace }).first.flatMap { Double($0) }
        let raw = live["mem_available_kb"]
        let memory = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init)
        func valid(_ n: Double?) -> Double? { n.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        let point = ResourcePoint(time: now, load: valid(load), availableRAM: valid(memory.map { $0 * 1024 }), totalRAM: valid((live["plan_ram"] as? NSNumber)?.doubleValue ?? (live["plan_ram"] as? String).flatMap(Double.init)))
        return point.load == nil && point.availableRAM == nil ? nil : point
    }
    static func append(_ point: ResourcePoint, to points: [ResourcePoint]) -> [ResourcePoint] {
        let bucket = floor(point.time.timeIntervalSince1970 / 300)
        return (points.filter { $0.time >= point.time.addingTimeInterval(-retention) && $0.time <= point.time && floor($0.time.timeIntervalSince1970 / 300) != bucket } + [point]).sorted { $0.time < $1.time }
    }
    static func read(instanceID: String, now: Date = Date()) -> [ResourcePoint] {
        guard let dir = WidgetStore.directory,
              let data = try? Data(contentsOf: dir.appendingPathComponent("resource-history.json")),
              let points = decode(data,instanceID:instanceID,now:now) else { return [] }
        return points
    }
    static func decode(_ data: Data, instanceID: String, now: Date) -> [ResourcePoint]? {
        guard let archive = try? JSONDecoder().decode(ResourceArchive.self,from:data), archive.instanceID == instanceID else { return nil }
        return archive.points.filter { $0.time >= now.addingTimeInterval(-retention) && $0.time <= now }.sorted { $0.time < $1.time }
    }
    static func write(_ points: [ResourcePoint], instanceID: String, cpuPoints: [ResourcePoint] = []) throws {
        guard let dir = WidgetStore.directory else { throw NSError(domain:"ResourceHistory",code:1) }
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let path = dir.appendingPathComponent("resource-history.json")
        try JSONEncoder().encode(ResourceArchive(instanceID:instanceID,points:points,cpuPoints:cpuPoints)).write(to:path,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
    }
    static func cpuSamples(_ payload: [String:Any], now: Date = Date()) -> [ResourcePoint] {
        let rows = payload["data"] as? [[String:Any]] ?? Array((payload["data"] as? [String:[String:Any]] ?? [:]).values)
        var points: [Date:ResourcePoint] = [:]
        func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
        for row in rows {
            guard let stamp = number(row["timestamp"]), stamp.isFinite, stamp > 0,
                  let cpu = number(row["cpu_usage"]), cpu.isFinite, cpu >= 0 else { continue }
            let time = Date(timeIntervalSince1970:stamp)
            guard time <= now, time >= now.addingTimeInterval(-retention) else { continue }
            points[time] = ResourcePoint(time:time,load:nil,availableRAM:nil,cpuPercent:cpu)
        }
        return points.values.sorted { $0.time < $1.time }
    }
    static func mergeCPU(_ fresh: [ResourcePoint], previous: [ResourcePoint], now: Date = Date()) -> [ResourcePoint] {
        var merged: [Date:ResourcePoint] = [:]
        for p in previous + fresh where p.time >= now.addingTimeInterval(-retention) && p.time <= now { merged[p.time] = p }
        return merged.values.sorted { $0.time < $1.time }
    }
    static func readCPU(instanceID: String, now: Date = Date()) -> [ResourcePoint] {
        guard let dir = WidgetStore.directory,
              let data = try? Data(contentsOf:dir.appendingPathComponent("resource-history.json")),
              let archive = try? JSONDecoder().decode(ResourceArchive.self,from:data), archive.instanceID == instanceID else { return [] }
        return mergeCPU([],previous:archive.cpuPoints ?? [],now:now)
    }
    static var demo: [ResourcePoint] {
        let now = Date()
        return (0..<49).map { i in
            ResourcePoint(time:now.addingTimeInterval(Double(i - 48)*300),load:0.2 + abs(sin(Double(i)*0.3))*0.7,availableRAM:(1.2 + cos(Double(i)*0.2)*0.2)*1073741824,totalRAM:2*1073741824,cpuPercent:12 + abs(sin(Double(i)*0.3))*25)
        }
    }
    static func test() throws {
        let now = Date(timeIntervalSince1970:1800000000)
        let live: [String:Any] = ["ve_status":"running","load_average":"0.50 0.25 0.10 1/100 1234","mem_available_kb":"1024"]
        guard let point = sample(live,now:now), point.load == 0.5, point.availableRAM == 1048576,
              sample(["ve_status":"Stopped","load_average":"1 2 3"]) == nil,
              sample(["ve_status":"Running","load_average":"nan","mem_available_kb":-1]) == nil,
              sample(["ve_status":"Running","load_average":"0 0 0"])?.load == 0 else { throw NSError(domain:"Resource parse",code:1) }
        let old = ResourcePoint(time:now.addingTimeInterval(-retention-1),load:1,availableRAM:nil)
        let first = append(point,to:[old])
        let second = append(ResourcePoint(time:now.addingTimeInterval(60),load:0.7,availableRAM:nil),to:first)
        guard first.count == 1, second.count == 1, second[0].load == 0.7 else { throw NSError(domain:"Resource retention",code:1) }
        let encoded = try JSONEncoder().encode(ResourceArchive(instanceID:"demo",points:second))
        guard decode(encoded,instanceID:"demo",now:now.addingTimeInterval(60))?.count == 1,
              decode(encoded,instanceID:"another-vps",now:now) == nil,
              decode(Data("invalid".utf8),instanceID:"demo",now:now) == nil else { throw NSError(domain:"Resource cache",code:1) }
        guard let memory = MemoryUsage(total:2048,available:512), memory.used == 1536, memory.percent == 75,
              MemoryUsage(total:0,available:0) == nil, MemoryUsage(total:1024,available:2048) == nil,
              MemoryUsage(total:1024,available:nil) == nil else { throw NSError(domain:"Memory calculation",code:1) }
        let cpu = cpuSamples(["data":[["timestamp":now.timeIntervalSince1970,"cpu_usage":"12.5"], ["timestamp":now.timeIntervalSince1970-300,"cpu_usage":0], ["timestamp":now.timeIntervalSince1970-600,"cpu_usage":-1], ["timestamp":now.timeIntervalSince1970-900]]],now:now)
        guard cpu.count == 2, cpu.last?.cpuPercent == 12.5, cpu.first?.cpuPercent == 0,
              mergeCPU(cpu,previous:cpu,now:now).count == 2 else { throw NSError(domain:"CPU history",code:1) }
        let legacy = Data("{\"instanceID\":\"demo\",\"points\":[]}".utf8)
        guard decode(legacy,instanceID:"demo",now:now)?.isEmpty == true else { throw NSError(domain:"Legacy history",code:1) }
        print("PASS: CPU 原始百分比、有效零值、缺失值、历史去重与旧缓存兼容")
        print("PASS: 已用内存、使用率、缺失数据与无效额度处理")
        print("PASS: 资源采样解析、停机与缺失值、有效零值、五分钟去重、30天保留及缓存编码")
    }
}
struct ResourceTrend: View {
    var points: [ResourcePoint]
    var memory = false
    var compact = false
    private struct PlotPoint: Identifiable {
        var time: Date
        var value: Double
        var segment: Int
        var id: Date { time }
    }
    private var plotted: [PlotPoint] {
        var result: [PlotPoint] = []
        var segment = 0
        var previous: Date?
        for point in points {
            guard let value = memory ? point.memory?.percent : point.cpuPercent else { segment += 1; previous = nil; continue }
            if let previous, point.time.timeIntervalSince(previous) > 450 { segment += 1 }
            result.append(PlotPoint(time:point.time,value:value,segment:segment))
            previous = point.time
        }
        return result
    }
    var body: some View {
        if plotted.isEmpty {
            Text("等待采样").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            Chart(plotted) { point in
                LineMark(x:.value("时间",point.time),y:.value("%",point.value),series:.value("连续段",point.segment))
                    .foregroundStyle(memory ? Color.blue : Color.mint)
                PointMark(x:.value("时间",point.time),y:.value("数值",point.value)).foregroundStyle(memory ? Color.blue : Color.mint).symbolSize(compact ? 5 : 10)
            }
            .chartYScale(domain:0...(memory ? 100 : max(100,(plotted.map(\.value).max() ?? 0)*1.1)))
            .chartXAxis { if !compact { AxisMarks(values:.automatic(desiredCount:4)) { _ in AxisGridLine(); AxisValueLabel(format:.dateTime.hour().minute()) } } }
            .chartYAxis { if !compact { AxisMarks(position:.leading,values:.automatic(desiredCount:3)) } }
            .chartLegend(.hidden)
        }
    }
}
