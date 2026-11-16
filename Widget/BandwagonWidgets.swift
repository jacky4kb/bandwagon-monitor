import SwiftUI
import WidgetKit

struct MonitorEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var preview = false
}
struct MonitorProvider: TimelineProvider {
    func placeholder(in context: Context) -> MonitorEntry { MonitorEntry(date: Date(), snapshot: .sample, preview: true) }
    func getSnapshot(in context: Context, completion: @escaping (MonitorEntry) -> Void) {
        completion(MonitorEntry(date: Date(), snapshot: context.isPreview ? .sample : WidgetStore.read(), preview: context.isPreview))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MonitorEntry>) -> Void) {
        let entry = MonitorEntry(date: Date(), snapshot: WidgetStore.read())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
    }
}
private let mint = Color(red: 0.25, green: 0.85, blue: 0.68)

struct MonitorWidgetView: View {
    @Environment(\.widgetFamily) var systemFamily
    var previewFamily: WidgetFamily? = nil
    var family: WidgetFamily { previewFamily ?? systemFamily }
    var entry: MonitorEntry
    var category: String
    var s: WidgetSnapshot { entry.snapshot }
    var fraction: Double { guard let t = s.total, t > 0, let used = s.used else { return 0 }; return used / t }
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 8) {
            HStack {
                Label(category == "traffic" ? "搬瓦工流量" : category == "resources" ? "CPU 与内存走势" : category == "history" ? "流量走势" : "VPS 网络", systemImage: "server.rack").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if entry.preview { Text("示例").font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            if !s.configured {
                Spacer(minLength: 0)
                Text("连接你的 VPS").font(.system(size: 18, weight: .semibold))
                Text("点击打开应用，填写 VEID 和 API Key。") .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                switch category {
                case "resources": resourceContent
                case "network": networkContent
                case "history": historyContent
                default: trafficContent
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if s.error != nil || (category == "resources" && s.resourceError == true) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    if let date = category == "history" ? s.trendUpdated : category == "resources" ? s.resourceUpdated : s.updated { Text(date, style: .time); Text(entry.date.timeIntervalSince(date) > 20 * 60 ? "数据较旧" : "更新") }
                    else { Text("等待应用同步") }
                    Spacer(minLength: 0)
                    if family != .systemSmall { Text("点击查看详情") }
                }.font(.system(size: 9)).foregroundStyle(.secondary)
                if family != .systemSmall, let date = s.updated, entry.date.timeIntervalSince(date) > 20 * 60 {
                    Text("数据较旧，请打开应用刷新").font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .containerBackground(for: .widget) { Rectangle().fill(Color(red: 0.055, green: 0.085, blue: 0.11).gradient) }
        .widgetURL(URL(string: "bandwagon-monitor://\(category)"))
    }
    var usageBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(fraction > 0.9 ? Color.orange : mint).frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }.frame(height: 5)
    }
    @ViewBuilder var trafficContent: some View {
        if family == .systemSmall {
            Text(widgetBytes(s.remaining)).font(.system(size:26,weight:.bold,design:.rounded)).lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(mint)
            Text("剩余流量 · 近 7 天趋势").font(.system(size:9)).foregroundStyle(.secondary)
            UsageTrend(points:s.trend ?? [],compact:true).frame(height:24)
            HStack {
                Text(s.total == nil ? "—" : String(format:"已用 %.0f%%",fraction * 100)).font(.system(size:9)).foregroundStyle(.secondary)
                Spacer(minLength:0); resetLine
            }
        } else {
            HStack(alignment:.top,spacing:16) {
                VStack(alignment:.leading,spacing:5) {
                    Text("剩余流量").font(.system(size:10)).foregroundStyle(.secondary)
                    Text(widgetBytes(s.remaining)).font(.system(size:27,weight:.bold,design:.rounded)).lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(mint)
                    resetLine
                }.frame(maxWidth:.infinity,alignment:.leading)
                VStack(alignment:.leading,spacing:4) {
                    Text("近 7 天 · GiB / 日").font(.system(size:9)).foregroundStyle(.secondary)
                    UsageTrend(points:s.trend ?? [],compact:true).frame(height:40)
                }.frame(maxWidth:.infinity)
            }
            if family == .systemLarge {
                usageBar
                row("已用 / 总额", "\(widgetBytes(s.used)) / \(widgetBytes(s.total))")
                Divider()
                UsageTrend(points:s.trend ?? [],compact:false).frame(height:100)
                row("已用内存 / 使用率", "\(widgetBytes(s.memory?.used)) / \(memoryPercent(s.memory))")
                row("CPU / 磁盘限速", "\(flag(s.cpuThrottled)) / \(flag(s.diskThrottled))")
            }
        }
    }
    var historyContent: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing:12) {
                dailyMetric("昨天流量", offset:-1)
                dailyMetric("今天流量 · 累计", offset:0)
            }
            Text("最近 7 天 · 每日流量（GiB）").font(.system(size:10)).foregroundStyle(.secondary)
            UsageTrend(points:s.trend ?? [],compact:family != .systemLarge).frame(height:family == .systemLarge ? 155 : 24)
        }
    }
    func dailyMetric(_ title: String, offset: Int) -> some View {
        VStack(alignment:.leading,spacing:2) {
            Text(title).font(.system(size:9)).foregroundStyle(.secondary)
            Text(widgetBytes(UsageHistory.dayTotal(s.trend ?? [],offset:offset,now:entry.date)))
                .font(.system(size:family == .systemLarge ? 22 : 17,weight:.semibold,design:.rounded))
                .foregroundStyle(mint).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    var resetLine: some View {
        HStack(spacing: 3) {
            Text("重置")
            if let reset = s.reset { Text(Date(timeIntervalSince1970: reset), format: .dateTime.month(.twoDigits).day(.twoDigits)) }
            else { Text("—") }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }
    var resourceContent: some View {
        VStack(alignment:.leading,spacing:family == .systemLarge ? 8 : 4) {
            Text("近 24 小时 · 每 5 分钟采样").font(.system(size:9)).foregroundStyle(.secondary)
            if family == .systemLarge {
                resourcePlot(memory:false)
                resourcePlot(memory:true)
                row("状态 / 内存额度", "\(s.state) / \(widgetBytes(s.totalRAM))")
                row("CPU / 磁盘限速", "\(flag(s.cpuThrottled)) / \(flag(s.diskThrottled))")
            } else {
                HStack(alignment:.top,spacing:12) {
                    resourcePlot(memory:false)
                    resourcePlot(memory:true)
                }
            }
        }
    }
    func resourcePlot(memory: Bool) -> some View {
        let points = ((memory ? s.resourceTrend : s.cpuTrend) ?? []).filter { $0.time >= entry.date.addingTimeInterval(-86400) }
        let latest = points.last
        return VStack(alignment:.leading,spacing:3) {
            HStack {
                Text(memory ? "已用内存 · 使用率" : "CPU 使用率 · %")
                if family == .systemLarge { Spacer(minLength:0) }
            }.font(.system(size:9)).foregroundStyle(.secondary)
            Text(memory ? "\(widgetBytes(latest?.memory?.used)) · \(memoryPercent(latest?.memory))" : latest?.cpuPercent.map { String(format:"%.1f%%",$0) } ?? "—")
                .font(.system(size:17,weight:.semibold,design:.rounded)).foregroundStyle(memory ? Color.blue : mint).lineLimit(1).minimumScaleFactor(0.6)
            ResourceTrend(points:points,memory:memory,compact:true).frame(height:family == .systemLarge ? 48 : 23)
            if let date = latest?.time { Text(date,style:.time).font(.system(size:8)).foregroundStyle(.secondary) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    var networkContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(s.hostname).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            row("机房", s.location)
            ForEach(Array(s.addresses.prefix(family == .systemLarge ? 5 : 1).enumerated()), id: \.offset) { _, address in
                Text(address).font(.system(size: 12, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.65)
            }
            if family == .systemLarge {
                Divider()
                row("SSH 端口", s.sshPort)
                row("状态", s.state)
                row("服务暂停", flag(s.suspended))
                row("待处理违规", flag(s.violation))
                row("套餐", s.plan)
            }
        }
    }
    func flag(_ value: Bool?) -> String { value.map { $0 ? "是" : "否" } ?? "未知" }
    func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title).foregroundStyle(.secondary); Spacer(minLength: 8); Text(value).lineLimit(2).multilineTextAlignment(.trailing).minimumScaleFactor(0.8) }.font(.system(size: 11))
    }
    func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 10)).foregroundStyle(.secondary); Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(mint) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct TrafficWidget: Widget {
    let kind = "BandwagonTraffic"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MonitorProvider()) { MonitorWidgetView(entry: $0, category: "traffic") }
            .configurationDisplayName("搬瓦工流量").description("剩余流量、用量比例与重置日期；大尺寸展示运行概况。")
            .supportedFamilies([.systemSmall,.systemMedium,.systemLarge])
    }
}
struct HistoryWidget: Widget {
    let kind = "BandwagonHistory"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind:kind,provider:MonitorProvider()) { MonitorWidgetView(entry:$0,category:"history") }
            .configurationDisplayName("流量走势图").description("最近七天每日入站与出站流量趋势。")
            .supportedFamilies([.systemMedium,.systemLarge])
    }
}
struct ResourcesWidget: Widget {
    let kind = "BandwagonResources"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MonitorProvider()) { MonitorWidgetView(entry: $0, category: "resources") }
            .configurationDisplayName("CPU 与内存走势图").description("最近 24 小时 CPU 使用率与内存使用率走势、已用内存；每 5 分钟刷新。")
            .supportedFamilies([.systemMedium,.systemLarge])
    }
}
struct NetworkWidget: Widget {
    let kind = "BandwagonNetwork"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MonitorProvider()) { MonitorWidgetView(entry: $0, category: "network") }
            .configurationDisplayName("VPS 网络").description("IP、机房与网络相关状态。")
            .supportedFamilies([.systemMedium,.systemLarge])
    }
}
#if !WIDGET_PREVIEW
@main struct BandwagonWidgets: WidgetBundle {
    var body: some Widget { TrafficWidget(); ResourcesWidget(); NetworkWidget(); HistoryWidget() }
}

#endif
