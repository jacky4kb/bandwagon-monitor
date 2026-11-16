import AppKit
import SwiftUI
import Combine
import WidgetKit
import ServiceManagement

enum Page: String, CaseIterable, Identifiable {
    case overview = "总览", resources = "资源", network = "网络", history = "统计", backups = "备份", events = "日志", api = "API"
    var id: String { rawValue }
    var endpoints: [Endpoint] {
        switch self {
        case .overview, .resources: return [.info, .live]
        case .network: return [.info]
        case .history: return [.usage]
        case .backups: return [.snapshots, .backups]
        case .events: return [.audit, .policies, .suspensions]
        case .api: return [.rate]
        }
    }
}

@MainActor final class Monitor: ObservableObject {
    @Published var data: [Endpoint: [String: Any]] = [:]
    @Published var errors: [Endpoint: String] = [:]
    @Published var updated: [Endpoint: Date] = [:]
    @Published var loading = false
    @Published var page: Page = .overview
    @Published var showSettings = false
    @Published var compact = false
    @Published var pinned = false
    @Published var veid = ""
    @Published var message: String?
    @Published var interval = 5
    @Published var usageSamples: [UsagePoint] = []
    @Published var showMenuBar = true
    @Published var loginEnabled = false
    @Published var loginStatus = "已关闭"
    func setMenuBar(_ visible: Bool) {
        showMenuBar = visible
        if !demo { UserDefaults.standard.set(visible,forKey:"showMenuBar") }
        onUpdate?()
    }
    func setLogin(_ enabled: Bool) {
        guard !demo else { return }
        Task { @MainActor in
            do {
                if enabled { try BackgroundService.service.register() }
                else { try await BackgroundService.service.unregister() }
            } catch { message = "自动启动设置失败：" + error.localizedDescription }
            refreshLoginStatus()
        }
    }
    func refreshLoginStatus() { guard !demo else { return }; loginEnabled = BackgroundService.service.status == .enabled; loginStatus = BackgroundService.statusText }
    var key = ""
    var demo = false
    var timer: Timer?
    var task: Task<Void, Never>?
    var onUpdate: (() -> Void)?
    var info: [String: Any] { data[.info] ?? [:] }
    var live: [String: Any] { data[.live] ?? [:] }
    var traffic: Traffic? { Traffic(info) }
    var configured: Bool { !veid.isEmpty && !key.isEmpty }
    init(demo: Bool) {
        self.demo = demo
        if demo { seedDemo(); return }
        pinned = UserDefaults.standard.bool(forKey:"pinned")
        veid = UserDefaults.standard.string(forKey:"veid") ?? ""
        interval = max(5, UserDefaults.standard.integer(forKey:"interval"))
        showMenuBar = UserDefaults.standard.object(forKey:"showMenuBar") as? Bool ?? true
        refreshLoginStatus()
        do { key = try Vault.read(veid) ?? "" } catch { message = error.localizedDescription }
        showSettings = !configured
        startTimer()
    }
    func startTimer() {
        timer?.invalidate()
        guard !demo else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(interval * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func configure(id: String, secret: String, minutes: Int) throws {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }), !secret.isEmpty else {
            throw MonitorError.message("请填写数字 VEID 和 API Key。")
        }
        try Vault.save(secret, account: id)
        if !veid.isEmpty && veid != id { try? Vault.delete(veid) }
        veid = id; key = secret; interval = minutes
        UserDefaults.standard.set(id, forKey: "veid"); UserDefaults.standard.set(minutes, forKey: "interval")
        data = [:]; errors = [:]; updated = [:]; usageSamples = []; message = nil; showSettings = false
        startTimer(); refresh()
    }
    func disconnect() throws {
        guard !demo else { return }
        try Vault.delete(veid)
        key = ""; veid = ""; data = [:]; errors = [:]; updated = [:]; usageSamples = []
        UserDefaults.standard.removeObject(forKey: "veid"); onUpdate?()
    }
    func select(_ page: Page) {
        self.page = page
        if !loading { refresh(missingOnly: true, includeOverview: false) }
    }
    func refresh(missingOnly: Bool = false, includeOverview: Bool = true) {
        guard !loading, configured, !demo else { return }
        var endpoints: [Endpoint] = includeOverview ? [.info, .live, .usage] : []
        for ep in page.endpoints where !endpoints.contains(ep) { endpoints.append(ep) }
        if missingOnly { endpoints = endpoints.filter { data[$0] == nil && errors[$0] == nil } }
        guard !endpoints.isEmpty else { return }
        loading = true
        let selected = page, id = veid, secret = key
        task = Task {
            for endpoint in endpoints {
                do {
                    let result = try await APIClient.fetch(endpoint, veid: id, key: secret)
                    guard !Task.isCancelled else { break }
                    data[endpoint] = result; errors[endpoint] = nil; updated[endpoint] = Date()
                    if endpoint == .usage { usageSamples = UsageHistory.parse(result) }
                } catch {
                    guard !Task.isCancelled else { break }
                    errors[endpoint] = error.localizedDescription.replacingOccurrences(of: secret, with: "[已隐藏]")
                }
                onUpdate?()
            }
            loading = false; onUpdate?()
            if selected != page { refresh(missingOnly: true, includeOverview: false) }
        }
    }
    func publishWidgetSnapshot() {
        guard !demo else { return }
        if configured && data[.info] == nil { return }
        var snapshot = WidgetSnapshot()
        snapshot.configured = configured
        if configured {
            snapshot.updated = updated[.info]
            snapshot.instanceID = veid
            snapshot.trend = UsageHistory.aggregate(usageSamples, days: 7)
            snapshot.trendUpdated = updated[.usage]
            if usageSamples.isEmpty && updated[.usage] == nil {
                let previous = WidgetStore.read()
                if previous.instanceID == veid { snapshot.trend = previous.trend; snapshot.trendUpdated = previous.trendUpdated }
            }
            snapshot.hostname = info["hostname"] as? String ?? "搬瓦工 VPS"
            snapshot.remaining = traffic?.remaining; snapshot.total = traffic?.total; snapshot.used = traffic?.used
            snapshot.reset = numeric(info["data_next_reset"])
            let state = live["ve_status"] as? String ?? "—"
            snapshot.state = ["Running":"运行中", "Stopped":"已关机", "Starting":"启动中"][state] ?? state
            snapshot.load = live["load_average"] as? String ?? "—"
            snapshot.availableRAM = numeric(live["mem_available_kb"]).map { $0 * 1024 }
            snapshot.totalRAM = numeric(info["plan_ram"])
            snapshot.availableSwap = numeric(live["swap_available_kb"]).map { $0 * 1024 }
            snapshot.totalSwap = numeric(live["swap_total_kb"]).map { $0 * 1024 }
            snapshot.mappedDisk = numeric(live["ve_used_disk_space_b"]); snapshot.diskQuota = numeric(info["plan_disk"])
            snapshot.cpuThrottled = numeric(live["is_cpu_throttled"]).map { $0 != 0 }
            snapshot.diskThrottled = numeric(live["is_disk_throttled"]).map { $0 != 0 }
            snapshot.suspended = numeric(info["suspended"]).map { $0 != 0 }
            snapshot.violation = numeric(info["policy_violation"]).map { $0 != 0 }
            snapshot.location = info["node_location"] as? String ?? "—"
            snapshot.addresses = info["ip_addresses"] as? [String] ?? []
            snapshot.sshPort = live["ssh_port"].map { String(describing: $0) } ?? "—"
            snapshot.plan = info["plan"] as? String ?? "—"; snapshot.os = info["os"] as? String ?? "—"
            if errors[.info] != nil || errors[.live] != nil { snapshot.error = "更新失败" }
        }
        do { try WidgetStore.write(snapshot); WidgetCenter.shared.reloadAllTimelines() }
        catch { message = error.localizedDescription }
    }
    func seedDemo() {
        veid = "1234567"
        data[.info] = ["error":0,"hostname":"My Bandwagon VPS","node_alias":"v1234","node_location":"US, Los Angeles","vm_type":"kvm","plan":"KVM • 2 GB / 40 GB","plan_ram":2147483648.0,"plan_swap":1073741824,"plan_disk":42949672960.0,"plan_monthly_data":1073741824000.0,"data_counter":289910292480.0,"monthly_data_multiplier":1,"data_next_reset":Date().addingTimeInterval(12*86400).timeIntervalSince1970,"ip_addresses":["192.0.2.10","2001:db8::/64"],"private_ip_addresses":[],"os":"debian-12-x86_64","suspended":0,"policy_violation":0,"ptr":["192.0.2.10":"vps.example.com"],"ip_nullroutes":[:],"email":"demo@example.com"]
        data[.live] = ["error":0,"ve_status":"Running","load_average":"0.08 0.12 0.09","mem_available_kb":1468006,"swap_total_kb":1048576,"swap_available_kb":1048576,"ve_used_disk_space_b":12884901888.0,"ve_disk_quota_gb":40,"is_cpu_throttled":0,"is_disk_throttled":0,"ssh_port":22,"live_hostname":"my-vps"]
        data[.rate] = ["error":0,"remaining_points_15min":95,"remaining_points_24h":1800]
        data[.usage] = ["error":0,"data":[["timestamp":Date().timeIntervalSince1970,"network_in_bytes":12345678,"network_out_bytes":87654321]]]
        data[.snapshots] = ["error":0,"snapshots":[["description":"升级前备份","size":12884901888.0,"os":"debian-12-x86_64","sticky":true]]]
        data[.backups] = ["error":0,"backups":[]]
        data[.audit] = ["error":0,"entries":[["timestamp":Date().timeIntervalSince1970,"action":"示例：查看服务状态"]]]
        data[.policies] = ["error":0,"policy_violations":[],"total_abuse_points":0]
        data[.suspensions] = ["error":0,"suspensions":[],"suspension_count":0]
        usageSamples = []
        for index in 0..<720 {
            let time = Date().addingTimeInterval(Double(index - 719) * 3600)
            let incoming = Double(2 + (index * 7 % 19)) * 13000000.0
            let outgoing = Double(5 + (index * 3 % 31)) * 23000000.0
            usageSamples.append(UsagePoint(time:time,incoming:incoming,outgoing:outgoing))
        }
        for ep in Endpoint.allCases { updated[ep] = Date() }
    }
}

let accent = Color(red: 0.35, green: 0.91, blue: 0.75)
let backdrop = Color(red: 0.055, green: 0.075, blue: 0.10)
let labels: [String: String] = [
    "hostname":"主机名", "node_alias":"节点编号", "node_location":"机房位置", "vm_type":"虚拟化类型", "plan":"套餐", "os":"操作系统", "email":"账户邮箱", "ip_addresses":"公网 IP", "private_ip_addresses":"内网 IP", "ptr":"反向 DNS", "ip_nullroutes":"IP 黑洞记录", "location_ipv6_ready":"机房支持 IPv6", "plan_max_ipv6s":"IPv6 /64 配额", "rdns_api_available":"可设置反向 DNS", "plan_private_network_available":"套餐支持内网", "location_private_network_available":"机房支持内网", "snapshots":"快照", "backups":"自动备份", "size":"大小（字节）", "description":"说明", "timestamp":"时间戳", "suspensions":"暂停记录", "policy_violations":"违规记录", "suspension_count":"本年暂停次数", "total_abuse_points":"累计违规分", "max_abuse_points":"年度违规分上限", "remaining_points_15min":"15 分钟剩余点数", "remaining_points_24h":"24 小时剩余点数", "plan_monthly_data":"周期额度（原始字节）", "data_counter":"周期用量（原始字节）", "monthly_data_multiplier":"流量换算系数", "data_next_reset":"下次重置时间戳", "plan_ram":"内存额度（字节）", "plan_swap":"Swap 额度（字节）", "plan_disk":"磁盘额度（字节）", "load_average":"系统负载", "mem_available_kb":"可用内存（KiB）", "swap_total_kb":"Swap 总量（KiB）", "swap_available_kb":"可用 Swap（KiB）", "ssh_port":"SSH 端口", "ve_status":"运行状态", "is_cpu_throttled":"CPU 限速", "is_disk_throttled":"磁盘 I/O 限速", "ve_used_disk_space_b":"已映射磁盘（字节）", "ve_disk_quota_gb":"虚拟磁盘大小（GB）", "live_hostname":"实时主机名", "ve_mac1":"网卡 MAC", "suspended":"服务暂停", "policy_violation":"待处理违规"
]

struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
            content
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.065)))
    }
}
struct Metric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.font(.system(size: 12))
    }
}

struct RootView: View {
    @ObservedObject var model: Monitor
    func value(_ key: String, live: Bool = false) -> String {
        let dict = live ? model.live : model.info
        guard let v = dict[key] else { return "—" }
        return String(describing: v)
    }
    func flag(_ key: String, live: Bool = false) -> String {
        guard let n = numeric((live ? model.live : model.info)[key]) else { return "未知" }
        return n == 0 ? "否" : "是"
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if model.demo { Text("演示数据 · 未连接真实 VPS").font(.caption).foregroundStyle(.orange).padding(.bottom, 8) }
            if !model.compact {
                HStack(spacing: 4) {
                    ForEach(Page.allCases) { page in
                        Button { model.select(page) } label: {
                            Text(page.rawValue).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(model.page == page ? accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                                .foregroundStyle(model.page == page ? accent : .secondary)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 18).padding(.bottom, 12)
            }
            ScrollView {
                VStack(spacing: 12) {
                    if !model.configured && !model.demo {
                        Panel(title: "连接你的搬瓦工 VPS") {
                            Text("填入 KiwiVM 的 VEID 和 API Key，即可查看流量与运行状态。")
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                            Button("配置连接") { model.showSettings = true }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                        }
                    }
                    if model.compact { trafficCard }
                    else {
                        switch model.page {
                        case .overview: overview
                        case .resources: resources
                        case .network: network
                        case .history:
                            HistoryView(model:model)
                            endpoint(.usage)
                        case .backups: endpoint(.snapshots); endpoint(.backups)
                        case .events: endpoint(.policies); endpoint(.suspensions); endpoint(.audit)
                        case .api:
                            Panel(title: "调用配置") {
                                InfoRow(label: "VEID", value: model.veid.isEmpty ? "未配置" : model.veid)
                                InfoRow(label: "自动刷新", value: "每 \(model.interval) 分钟")
                                InfoRow(label: "数据接口", value: "api.64clouds.com")
                                Text("总览与当前页面自动更新；其他页面在打开时加载。调用失败保留上次成功数据，并标明错误。") .font(.caption).foregroundStyle(.secondary)
                            }
                            endpoint(.rate)
                            endpoint(.info)
                            endpoint(.live)
                        }
                    }
                }.padding(.horizontal, 18).padding(.bottom, 16)
            }
            footer
        }.background(backdrop).preferredColorScheme(.dark)
            .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
    }
    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 19)).foregroundStyle(accent)
                .frame(width: 38, height: 38).background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("搬瓦工监控").font(.system(size: 16, weight: .semibold))
                Text(model.info["hostname"] as? String ?? "BANDWAGON MONITOR").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { model.pinned.toggle(); model.onUpdate?() } label: { Image(systemName: model.pinned ? "pin.fill" : "pin") }.help("窗口置顶")
            Button { model.compact.toggle(); model.onUpdate?() } label: { Image(systemName: model.compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left") }.help("切换迷你窗口")
            Button { model.showSettings = true } label: { Image(systemName: "gearshape") }.help("设置")
        }.buttonStyle(.plain).padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
    }
    var trafficCard: some View {
        Panel(title: "本周期剩余流量") {
            HStack(alignment: .firstTextBaseline) {
                Text(bytes(model.traffic?.remaining)).font(.system(size: model.compact ? 32 : 42, weight: .semibold, design: .rounded)).foregroundStyle(accent)
                Spacer()
                if let t = model.traffic { Text(String(format: "已用 %.1f%%", t.fraction * 100)).font(.system(size: 12)).foregroundStyle(t.fraction > 0.9 ? .orange : .secondary) }
            }
            ProgressView(value: min(1, max(0, model.traffic?.fraction ?? 0))).tint((model.traffic?.fraction ?? 0) > 0.9 ? .orange : accent)
            HStack {
                Metric(title: "已用 / 总额", value: "\(bytes(model.traffic?.used)) / \(bytes(model.traffic?.total))")
            }
            InfoRow(label: "下次重置", value: dateText(model.info["data_next_reset"]))
            if let reset = numeric(model.info["data_next_reset"]) {
                let days = Int(ceil((reset - Date().timeIntervalSince1970) / 86400))
                Text(days > 0 ? "距重置约 \(days) 天" : "等待服务端重置计数") .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if model.traffic == nil && model.data[.info] != nil { Text("流量字段不完整，无法计算剩余量。") .font(.caption).foregroundStyle(.orange) }
            if let err = model.errors[.info] { Text("更新失败 · \(err)").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let last = model.updated[.info] { Text("流量更新于 \(last.formatted(date: .omitted, time: .standard))").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }
    var overview: some View {
        Group {
            trafficCard
            Panel(title: "运行概况") {
                HStack {
                    Metric(title: "运行状态", value: stateText)
                    Metric(title: "系统负载", value: value("load_average", live: true))
                    Metric(title: "可用内存", value: bytes(numeric(model.live["mem_available_kb"]).map { $0 * 1024 }))
                }
                Divider()
                InfoRow(label: "CPU / 磁盘限速", value: "\(flag("is_cpu_throttled", live: true)) / \(flag("is_disk_throttled", live: true))")
                InfoRow(label: "服务暂停 / 待处理违规", value: "\(flag("suspended")) / \(flag("policy_violation"))")
                if let err = model.errors[.live] { Text(err).font(.caption).foregroundStyle(.orange) }
            }
            Panel(title: "实例信息") {
                InfoRow(label: "机房", value: value("node_location"))
                InfoRow(label: "套餐", value: value("plan"))
                InfoRow(label: "操作系统", value: value("os"))
                InfoRow(label: "节点 / 虚拟化", value: "\(value("node_alias")) / \(value("vm_type"))")
            }
        }
    }
    var stateText: String {
        let status = value("ve_status", live: true)
        return ["Running":"运行中","Stopped":"已关机","Starting":"启动中"][status] ?? status
    }
    var resources: some View {
        Group {
            Panel(title: "内存与存储") {
                InfoRow(label: "内存额度", value: bytes(numeric(model.info["plan_ram"])))
                InfoRow(label: "可用内存", value: bytes(numeric(model.live["mem_available_kb"]).map { $0 * 1024 }))
                InfoRow(label: "Swap 额度", value: bytes(numeric(model.info["plan_swap"])))
                InfoRow(label: "Swap 可用 / 总量", value: "\(bytes(numeric(model.live["swap_available_kb"]).map { $0 * 1024 })) / \(bytes(numeric(model.live["swap_total_kb"]).map { $0 * 1024 }))")
                InfoRow(label: "磁盘套餐额度", value: bytes(numeric(model.info["plan_disk"])))
                InfoRow(label: "已映射磁盘空间", value: bytes(numeric(model.live["ve_used_disk_space_b"])))
                Text("已映射空间来自宿主机，不等同于系统内 df 显示的文件用量。") .font(.caption).foregroundStyle(.secondary)
            }
            Panel(title: "实时运行信息") {
                InfoRow(label: "状态", value: stateText)
                InfoRow(label: "系统负载", value: value("load_average", live: true))
                InfoRow(label: "CPU 限速", value: flag("is_cpu_throttled", live: true))
                InfoRow(label: "磁盘 I/O 限速", value: flag("is_disk_throttled", live: true))
                InfoRow(label: "SSH 端口", value: value("ssh_port", live: true))
                InfoRow(label: "实时主机名", value: value("live_hostname", live: true))
            }
            if let base64 = model.live["screendump_png_base64"] as? String, let d = Data(base64Encoded: base64), let img = NSImage(data: d) {
                Panel(title: "VGA 控制台画面") { Image(nsImage: img).resizable().scaledToFit() }
            }
            endpoint(.live)
        }
    }
    var network: some View {
        Panel(title: "网络信息") {
            ForEach(["ip_addresses","private_ip_addresses","ptr","ip_nullroutes","location_ipv6_ready","plan_max_ipv6s","rdns_api_available","plan_private_network_available","location_private_network_available"], id: \.self) { key in
                JSONNode(name: labels[key] ?? key, value: model.info[key] ?? "未提供", expanded: true)
            }
            InfoRow(label: "网卡 MAC", value: value("ve_mac1", live: true))
            if let err = model.errors[.info] { Text(err).font(.caption).foregroundStyle(.orange) }
        }
    }
    func endpoint(_ ep: Endpoint) -> some View {
        Panel(title: ep.title) {
            if let error = model.errors[ep] { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let payload = model.data[ep] {
                if let date = model.updated[ep] { Text("更新于 \(date.formatted(date: .abbreviated, time: .standard))").font(.system(size: 10)).foregroundStyle(.secondary) }
                ForEach(payload.keys.filter { $0 != "error" }.sorted(), id: \.self) { key in
                    JSONNode(name: labels[key] ?? key, value: payload[key]!, expanded: false)
                }
                if payload.keys.filter({ $0 != "error" }).isEmpty { Text("没有记录").font(.caption).foregroundStyle(.secondary) }
            } else { Text(model.loading ? "正在查询…" : "尚无数据，点击刷新查询。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    var footer: some View {
        HStack {
            Circle().fill(model.errors.isEmpty ? (model.configured || model.demo ? accent : Color.gray) : Color.orange).frame(width: 6, height: 6)
            Text(model.loading ? "正在更新…" : model.errors.isEmpty ? "每 \(model.interval) 分钟刷新" : "部分数据更新失败") .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise").font(.system(size: 11)) }
                .buttonStyle(.plain).disabled(model.loading || !model.configured || model.demo)
        }.padding(.horizontal, 20).padding(.vertical, 12).background(Color.white.opacity(0.025))
    }
}

struct JSONNode: View {
    let name: String
    let value: Any
    @State var expanded: Bool = false
    @State private var limit = 40
    var children: [(String, Any)]? {
        if let dict = value as? [String: Any] { return dict.keys.sorted().map { ($0, dict[$0]!) } }
        if let list = value as? [Any] { return list.enumerated().map { ("#\($0.offset + 1)", $0.element) } }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let entries = children {
                DisclosureGroup(isExpanded: $expanded) {
                    if entries.isEmpty { Text("无记录").font(.caption).foregroundStyle(.secondary) }
                    else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(entries.prefix(limit).enumerated()), id: \.offset) { _, entry in
                                AnyView(JSONNode(name: labels[entry.0] ?? entry.0, value: entry.1))
                            }
                            if entries.count > limit { Button("再显示 40 项（共 \(entries.count) 项）") { limit += 40 }.font(.caption) }
                        }.padding(.leading, 8).padding(.top, 6)
                    }
                } label: { Text("\(name)  ·  \(entries.count)").font(.system(size: 12)) }
            } else if name == "screendump_png_base64" {
                Text("控制台图像见资源页").font(.caption).foregroundStyle(.secondary)
            } else {
                InfoRow(label: name, value: value is NSNull ? "未提供" : String(describing: value))
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: Monitor
    @Environment(\.dismiss) var dismiss
    @State private var id = ""
    @State private var secret = ""
    @State private var interval = 5
    @State private var error: String?
    @State private var confirmDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("连接 KiwiVM").font(.title2.bold())
            Text("桌面右键 → 编辑小组件 → 搜索「搬瓦工监控」。应用在后台运行时会同步数据，小组件刷新时间由 macOS 调度。") .font(.caption).foregroundStyle(.secondary)
            Toggle("登录后自动启动", isOn: Binding(get:{ model.loginEnabled },set:{ model.setLogin($0) })).disabled(model.demo)
            HStack {
                Text("自动启动：" + model.loginStatus).font(.caption).foregroundStyle(.secondary)
                if model.loginStatus == "等待系统允许" { Button("打开系统设置") { SMAppService.openSystemSettingsLoginItems() }.font(.caption) }
            }
            Toggle("在菜单栏显示",isOn:Binding(get:{model.showMenuBar},set:{model.setMenuBar($0)}))
            Text("隐藏图标后仍会后台更新；点击桌面小组件或重新打开应用即可进入设置。") .font(.caption).foregroundStyle(.secondary)
            Text("在 KiwiVM 控制面板的 API 页面获取 VEID 与 API Key。") .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) { Text("VEID").font(.caption); TextField("VPS 数字编号", text: $id) }
            VStack(alignment: .leading, spacing: 6) { Text("API Key").font(.caption); SecureField("只保存在本机钥匙串", text: $secret) }
            Picker("自动刷新", selection: $interval) { ForEach([5,10,15,30,60], id: \.self) { Text("每 \($0) 分钟").tag($0) } }
            Text("应用仅调用查询接口。Key 保存在 macOS 钥匙串中，请勿将它分享给他人。") .font(.caption).foregroundStyle(.secondary)
            if let error = error ?? model.message { Text(error).font(.caption).foregroundStyle(.orange) }
            if model.loading { Text("当前查询结束后即可修改连接。") .font(.caption).foregroundStyle(.secondary) }
            HStack {
                if model.configured && !model.demo { Button("移除连接", role: .destructive) { confirmDelete = true }.disabled(model.loading) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并连接") {
                    do { try model.configure(id: id, secret: secret, minutes: interval) } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black).disabled(model.loading || model.demo).keyboardShortcut(.defaultAction)
            }
            HStack { Spacer(); Button("退出应用") { (NSApp.delegate as? AppDelegate)?.quit() }.font(.caption) }
            Link("打开 KiwiVM 控制面板", destination: URL(string: "https://kiwivm.64clouds.com/")!).font(.caption)
        }.textFieldStyle(.roundedBorder).padding(26).frame(width: 420).preferredColorScheme(.dark)
            .onAppear { id = model.veid; secret = model.key; interval = model.interval }
            .confirmationDialog("移除连接并删除钥匙串中的 API Key？", isPresented: $confirmDelete) {
                Button("移除连接", role: .destructive) { do { try model.disconnect(); secret = ""; id = "" } catch { self.error = error.localizedDescription } }
            }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var status: NSStatusItem!
    var model: Monitor!
    var observer: AnyCancellable?
    var lastCompact = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--preview") || Bundle.main.object(forInfoDictionaryKey:"PreviewOnly") as? Bool == true
        model = Monitor(demo: demo)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 720), styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
        window.title = "搬瓦工监控"; window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden; window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.055, green: 0.075, blue: 0.10, alpha: 1)
        window.contentView = NSHostingView(rootView: RootView(model: model).background(backdrop))
        window.minSize = NSSize(width: 500, height: 470)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center(); if !demo { window.setFrameAutosaveName("BandwagonMonitor.main") }
        let menu = NSMenu()
        menu.addItem(withTitle: "显示监控窗口", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "刷新数据", action: #selector(refresh), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出搬瓦工监控", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.menu = menu
        if CommandLine.arguments.contains("--preview") { window.alphaValue = 0; window.orderBack(nil) }
        model.onUpdate = { [weak self] in self?.updateWindow() }
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(showWindow),name:Notification.Name("local.bandwagon.monitor.show"),object:nil)
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(quit),name:Notification.Name("local.bandwagon.monitor.quit"),object:nil)
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(settings),name:Notification.Name("local.bandwagon.monitor.settings"),object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(refresh),name:NSWorkspace.didWakeNotification,object:nil)
        updateWindow()
        if !CommandLine.arguments.contains("--background") && !CommandLine.arguments.contains("--preview") { showWindow() }
        if !demo { model.refresh() }
        if CommandLine.arguments.contains("--preview") {
            model.showSettings = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.capturePreviews() }
        }
    }
    func updateWindow() {
        status.isVisible = model.showMenuBar && !CommandLine.arguments.contains("--preview")
        let failed = !model.errors.isEmpty
        status.button?.title = (model.demo ? "演示 " : "") + (model.traffic.map { "↓ " + bytes($0.remaining) } ?? "搬瓦工") + (failed ? " ⚠" : "")
        status.button?.toolTip = failed ? "更新失败，显示上次成功数据" : "本周期剩余流量"
        if !model.loading { model.publishWidgetSnapshot() }
        window.level = model.pinned ? .floating : .normal
        if !model.demo { UserDefaults.standard.set(model.pinned, forKey: "pinned") }
        if model.compact != lastCompact {
            lastCompact = model.compact
            window.minSize = model.compact ? NSSize(width: 350, height: 330) : NSSize(width: 500, height: 470)
            window.setContentSize(model.compact ? NSSize(width: 370, height: 410) : NSSize(width: 540, height: 720))
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "bandwagon-monitor" else { return }
        if url.host == "history" { model.select(.history) }
        else if url.host == "resources" { model.select(.resources) }
        else if url.host == "network" { model.select(.network) }
        else { model.select(.overview) }
        showWindow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshLoginStatus() }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func refresh() { model.refresh() }
    @objc func settings() { showWindow(); model.showSettings = true }
    @objc func quit() {
        model.task?.cancel(); model.timer?.invalidate()
        model.showSettings = false
        if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
        DispatchQueue.main.asyncAfter(deadline:.now() + 0.15) { NSApp.terminate(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.task?.cancel(); model?.timer?.invalidate() }
    func capturePreviews() {
        guard let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 else { return }
        let path = CommandLine.arguments[index + 1]
        let pages: [Page] = [.overview, .resources, .network, .history, .backups, .events, .api]
        func capture(_ i: Int) {
            guard i < pages.count + 2 else { exit(0) }
            if i == pages.count { model.compact = true; updateWindow() }
            if i == pages.count + 1 { model.compact = false; updateWindow(); model.showSettings = true }
            if i < pages.count { model.page = pages[i] }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path).appendingPathComponent("preview-\(i).png"))
                    }
                }
                capture(i + 1)
            }
        }
        capture(0)
    }
}

@main struct Main {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--quit") || CommandLine.arguments.contains("--show-settings") {
            let action = CommandLine.arguments.contains("--quit") ? "quit" : "settings"
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.bandwagon.monitor." + action),object:nil,userInfo:nil,deliverImmediately:true)
            return
        }
        if CommandLine.arguments.contains("--enable-login") {
            do { try BackgroundService.service.register(); print("Login service: " + BackgroundService.statusText) }
            catch { print("Login registration failed: " + error.localizedDescription); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--hide-menu") { UserDefaults.standard.set(false,forKey:"showMenuBar"); print("Menu bar hidden"); return }
        if CommandLine.arguments.contains("--runtime-status") {
            let snapshot = WidgetStore.read()
            print("Login: \(BackgroundService.statusText); menu visible: \(UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true); configured: \(snapshot.configured); trend points: \(snapshot.trend?.count ?? 0)")
            return
        }
        if CommandLine.arguments.contains("--widget-check") {
            guard let directory = WidgetStore.directory else { print("FAIL: group container unavailable"); exit(1) }
            do {
                let check = directory.appendingPathComponent(".widget-check-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("ok".utf8).write(to: check)
                guard try String(contentsOf: check, encoding: .utf8) == "ok" else { exit(1) }
                try FileManager.default.removeItem(at: check)
                print("PASS: shared widget container read/write")
                print("Container: \(directory.path)")
            } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try selfTest(); try UsageHistory.test(); try SingleInstance.test(); print("All tests passed.") } catch { fputs("\(error)\n", stderr); exit(1) }
            return
        }
        let preview = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--preview") || Bundle.main.object(forInfoDictionaryKey:"PreviewOnly") as? Bool == true
        if !preview {
            do {
                if try !SingleInstance.acquire() {
                    if !CommandLine.arguments.contains("--background") { DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.bandwagon.monitor.show"),object:nil,userInfo:nil,deliverImmediately:true) }
                    return
                }
            } catch {
                fputs("Unable to acquire instance lock: \(error.localizedDescription)\n",stderr)
                exit(1)
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
