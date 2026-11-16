import Foundation
import SwiftUI
import Charts

struct UsagePoint: Codable, Identifiable {
    var time: Date
    var incoming: Double
    var outgoing: Double
    var segment: Int = 0
    var id: Date { time }
    var total: Double { incoming + outgoing }
}
enum UsageHistory {
    static func parse(_ payload: [String: Any]) -> [UsagePoint] {
        let rows: [[String: Any]]
        if let list = payload["data"] as? [[String: Any]] { rows = list }
        else if let map = payload["data"] as? [String: [String: Any]] { rows = Array(map.values) }
        else { return [] }
        func number(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }
        var unique: [Double: UsagePoint] = [:]
        for row in rows {
            guard let stamp = number(row["timestamp"]), stamp.isFinite, stamp > 0,
                  let incoming = number(row["network_in_bytes"]), incoming.isFinite, incoming >= 0,
                  let outgoing = number(row["network_out_bytes"]), outgoing.isFinite, outgoing >= 0 else { continue }
            unique[stamp] = UsagePoint(time: Date(timeIntervalSince1970: stamp), incoming: incoming, outgoing: outgoing)
        }
        return unique.values.sorted { $0.time < $1.time }
    }
    static func aggregate(_ samples: [UsagePoint], days: Int, now: Date = Date(), calendar: Calendar = .current) -> [UsagePoint] {
        let component: Calendar.Component = days == 1 ? .hour : .day
        let start = days == 1 ? now.addingTimeInterval(-86400) : calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!
        var bins: [Date: UsagePoint] = [:]
        for sample in samples where sample.time >= start && sample.time <= now {
            guard let date = calendar.dateInterval(of: component, for: sample.time)?.start else { continue }
            var point = bins[date] ?? UsagePoint(time: date, incoming: 0, outgoing: 0)
            point.incoming += sample.incoming; point.outgoing += sample.outgoing
            bins[date] = point
        }
        var points = bins.values.sorted { $0.time < $1.time }
        var segment = 0
        for i in points.indices {
            if i > 0, let expected = calendar.date(byAdding: component, value: 1, to: points[i-1].time), points[i].time > expected { segment += 1 }
            points[i].segment = segment
        }
        return points
    }
    static func test() throws {
        let rows: [String: Any] = ["data": [["timestamp":"1700000000", "network_in_bytes":"10", "network_out_bytes":20], ["timestamp":1700000000,"network_in_bytes":10,"network_out_bytes":20], ["timestamp":1700003600,"network_in_bytes":30,"network_out_bytes":40], ["timestamp":1700007200,"network_in_bytes":-1,"network_out_bytes":2], ["timestamp":1700007200,"network_out_bytes":5]]]
        let parsed = parse(rows)
        guard parsed.count == 2, parsed.reduce(0, {$0 + $1.total}) == 100 else { throw NSError(domain:"History test",code:1) }
        let buckets = aggregate(parsed, days: 1, now: Date(timeIntervalSince1970:1700007300))
        guard buckets.reduce(0, {$0 + $1.total}) == 100 else { throw NSError(domain:"History test",code:2) }
        let sparse = [parsed[0],UsagePoint(time: parsed[0].time.addingTimeInterval(4*3600),incoming:1,outgoing:1)]
        let gap = aggregate(sparse,days:1,now:sparse[1].time.addingTimeInterval(60))
        guard gap.count == 2, gap[1].segment == 1 else { throw NSError(domain:"History test",code:3) }
        let data = try JSONEncoder().encode(parsed)
        guard try JSONDecoder().decode([UsagePoint].self,from:data).count == 2 else { throw NSError(domain:"History test",code:4) }
        print("PASS: 历史解析、字符串数值、去重、无效记录、分桶汇总、缺口断线及缓存编码")
    }
}
struct UsageTrend: View {
    var points: [UsagePoint]
    var compact = false
    var hourly = false
    var body: some View {
        if points.isEmpty {
            Text("暂无历史流量数据").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            Chart {
                ForEach(points) { point in
                    if compact {
                        LineMark(x:.value("时间",point.time),y:.value("GiB",point.total / 1073741824),series:.value("段",point.segment)).foregroundStyle(Color.mint).lineStyle(StrokeStyle(lineWidth:2))
                        PointMark(x:.value("时间",point.time),y:.value("GiB",point.total / 1073741824)).foregroundStyle(Color.mint).symbolSize(10)
                    } else {
                        LineMark(x:.value("时间",point.time),y:.value("GiB",point.incoming / 1073741824),series:.value("段","入站-\(point.segment)")).foregroundStyle(by:.value("方向","入站"))
                        LineMark(x:.value("时间",point.time),y:.value("GiB",point.outgoing / 1073741824),series:.value("段","出站-\(point.segment)")).foregroundStyle(by:.value("方向","出站"))
                        PointMark(x:.value("时间",point.time),y:.value("GiB",point.incoming / 1073741824)).foregroundStyle(by:.value("方向","入站")).symbolSize(14)
                        PointMark(x:.value("时间",point.time),y:.value("GiB",point.outgoing / 1073741824)).foregroundStyle(by:.value("方向","出站")).symbolSize(14)
                    }
                }
            }
            .chartYScale(domain: 0...max(0.001, (points.map { compact ? $0.total : max($0.incoming,$0.outgoing) }.max() ?? 0) / 1073741824 * 1.1))
            .chartForegroundStyleScale(["入站":Color.mint,"出站":Color.blue])
            .chartXAxis {
                if !compact { AxisMarks(values:.automatic(desiredCount:5)) { value in AxisGridLine(); AxisValueLabel(format: hourly ? .dateTime.hour() : .dateTime.month().day()) } }
            }
            .chartYAxis { if !compact { AxisMarks(position:.leading,values:.automatic(desiredCount:4)) } }
            .chartLegend(compact ? .hidden : .visible)
        }
    }
}
