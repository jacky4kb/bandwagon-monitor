import SwiftUI

struct LocalTrafficHistoryView: View {
    var summary: LocalTrafficSummary?
    @State private var days = 7
    var points: [LocalDailyPoint] { LocalDailyHistory.points(summary:summary,days:days,now:Date()) }
    func label(_ point: LocalDailyPoint) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = LocalDailyHistory.calendar(summary).timeZone
        formatter.dateFormat = "MM-dd"
        return formatter.string(from:point.date)
    }
    var body: some View {
        Panel(title:"本机每日上传 / 下载") {
            Picker("时间范围",selection:$days) { Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90) }.pickerStyle(.segmented)
            LocalTrafficLegend()
            LocalTrafficTrend(summary:summary,days:days).frame(height:190)
            Text("仅展示已保存的用量；今天持续累计，首日可能不完整。缺失日期留空，不补零。标记“估算”的日期包含跨日分配。").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("每日明细（\(points.count) 天）") {
                VStack(spacing:8) {
                    HStack { Text("日期"); Spacer(); Text("上传 / 下载") }.foregroundStyle(.secondary)
                    ForEach(points.reversed()) { point in
                        HStack {
                            Text(label(point) + (point.estimated ? " · 估算" : ""))
                            Spacer()
                            Text("\(widgetBytes(point.uploaded)) / \(widgetBytes(point.downloaded))").monospacedDigit()
                        }
                    }
                }.font(.system(size:11)).padding(.top,8)
            }.font(.caption)
        }
    }
}
