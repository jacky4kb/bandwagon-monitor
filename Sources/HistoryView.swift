import SwiftUI
struct HistoryView: View {
    @ObservedObject var model: Monitor
    @State private var days = 7
    var points: [UsagePoint] { UsageHistory.aggregate(model.usageSamples, days: days) }
    var body: some View {
        Panel(title:"流量走势") {
            Picker("时间范围",selection:$days) { Text("24 小时").tag(1); Text("7 天").tag(7); Text("30 天").tag(30) }.pickerStyle(.segmented)
            HStack {
                Metric(title:"入站合计",value:bytes(points.isEmpty ? nil : points.reduce(0,{$0 + $1.incoming})))
                Metric(title:"出站合计",value:bytes(points.isEmpty ? nil : points.reduce(0,{$0 + $1.outgoing})))
                Metric(title:"总流量",value:bytes(points.isEmpty ? nil : points.reduce(0,{$0 + $1.total})))
            }
            Text(days == 1 ? "每小时流量 · GiB" : "每日流量 · GiB").font(.caption).foregroundStyle(.secondary)
            UsageTrend(points:points,hourly:days == 1).frame(height:220)
            if let updated = model.updated[.usage] { Text("统计更新：\(updated.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary) }
            Text("按 API 原始入站与出站字节汇总，不套用套餐换算系数；当前时段未结束，缺失时段不补零。") .font(.caption).foregroundStyle(.secondary)
        }
    }
}
