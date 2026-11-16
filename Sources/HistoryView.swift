import SwiftUI
struct HistoryView: View {
    @ObservedObject var model: Monitor
    @State private var days = 7
    var points: [UsagePoint] { UsageHistory.aggregate(model.usageSamples, days: days) }
    var body: some View {
        VStack(spacing:16) {
        Panel(title:"流量走势") {
            HStack {
                Metric(title:"昨天流量",value:bytes(UsageHistory.dayTotal(model.usageSamples,offset:-1)))
                Metric(title:"今天流量",value:bytes(UsageHistory.dayTotal(model.usageSamples,offset:0)))
            }
            Text("入站 + 出站；今天为截至统计更新的累计值。无记录显示 —。") .font(.caption).foregroundStyle(.secondary)
            Divider()
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
        ResourceHistoryPanel(points:model.resourceSamples)
        }
    }
}

struct ResourceHistoryPanel: View {
    var points: [ResourcePoint]
    var recent: [ResourcePoint] { points.filter { $0.time >= Date().addingTimeInterval(-86400) } }
    var body: some View {
        Panel(title:"CPU 负载与内存走势") {
            Text("最近 24 小时 · 每 5 分钟采样").font(.caption).foregroundStyle(.secondary)
            HStack {
                Metric(title:"CPU 系统负载 · 1 分钟",value:recent.last?.load.map { String(format:"%.3f",$0) } ?? "—")
                Metric(title:"可用内存",value:bytes(recent.last?.availableRAM))
            }
            Text("CPU 系统负载（非使用率 %）").font(.caption).foregroundStyle(.secondary)
            ResourceTrend(points:recent).frame(height:140)
            Text("可用内存 · GiB").font(.caption).foregroundStyle(.secondary)
            ResourceTrend(points:recent,memory:true).frame(height:140)
            if let date = recent.last?.time { Text("采样更新：\(date.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary) }
            Text("历史从启用后累积，本机保留 30 天；休眠、退出或请求失败期间不补点。首个采样显示为单点。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
