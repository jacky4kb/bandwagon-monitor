import Foundation
import SwiftUI
import Charts

struct LocalDailyPoint: Codable, Identifiable {
    var date: Date
    var uploaded: Double
    var downloaded: Double
    var estimated: Bool
    var id: Date { date }
}
enum LocalDailyHistory {
    static func calendar(_ summary: LocalTrafficSummary?) -> Calendar {
        var c = Calendar(identifier:.gregorian)
        c.timeZone = summary.flatMap { TimeZone(identifier:$0.timeZoneID) } ?? .current
        return c
    }
    static func range(summary: LocalTrafficSummary?, days: Int, now: Date) -> ClosedRange<Date> {
        let c = calendar(summary)
        let start = c.date(byAdding:.day,value:1-days,to:c.startOfDay(for:now))!
        return start...c.dateInterval(of:.day,for:now)!.end
    }
    static func points(summary: LocalTrafficSummary?, days: Int, now: Date) -> [LocalDailyPoint] {
        let domain = range(summary:summary,days:days,now:now)
        return (summary?.dailyPoints ?? []).filter { $0.date >= domain.lowerBound && $0.date < domain.upperBound }
    }
}
struct LocalTrafficLegend: View {
    var compact = false
    var days: Int? = nil
    var body: some View {
        HStack(spacing:10) {
            Label("上传",systemImage:"circle.fill").foregroundStyle(Color.mint)
            Label("下载",systemImage:"circle.fill").foregroundStyle(Color.blue)
            Spacer(minLength:0)
            Text(days.map { "近 \($0) 天 · GiB/日" } ?? "每日 · GiB").foregroundStyle(.secondary)
        }.font(.system(size:compact ? 9 : 11))
    }
}
struct LocalTrafficTrend: View {
    var summary: LocalTrafficSummary?
    var days = 7
    var now = Date()
    var compact = false
    var points: [LocalDailyPoint] { LocalDailyHistory.points(summary:summary,days:days,now:now) }
    func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = LocalDailyHistory.calendar(summary).timeZone
        formatter.dateFormat = "MM-dd"
        return formatter.string(from:date)
    }
    var body: some View {
        if points.isEmpty {
            Text("等待首次流量记录").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            Chart(points) { p in
                BarMark(x:.value("日期",p.date,unit:.day),y:.value("GiB",p.uploaded/1073741824),width:.ratio(0.7))
                    .position(by:.value("方向","上传")).foregroundStyle(by:.value("方向","上传"))
                BarMark(x:.value("日期",p.date,unit:.day),y:.value("GiB",p.downloaded/1073741824),width:.ratio(0.7))
                    .position(by:.value("方向","下载")).foregroundStyle(by:.value("方向","下载"))
            }
            .chartXScale(domain:LocalDailyHistory.range(summary:summary,days:days,now:now))
            .chartYScale(domain:0...max(0.001,(points.map{max($0.uploaded,$0.downloaded)}.max() ?? 0)/1073741824*1.1))
            .chartForegroundStyleScale(["上传":Color.mint,"下载":Color.blue])
            .chartXAxis {
                if !compact { AxisMarks(values:.automatic(desiredCount:days==7 ? 7 : 5)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let date = value.as(Date.self) { Text(dateLabel(date)).font(.system(size:9)) } }
                } }
            }
            .chartYAxis { if !compact { AxisMarks(position:.leading,values:.automatic(desiredCount:3)) } }
            .chartLegend(.hidden)
            .environment(\.calendar,LocalDailyHistory.calendar(summary))
            .environment(\.timeZone,LocalDailyHistory.calendar(summary).timeZone)
        }
    }
}
