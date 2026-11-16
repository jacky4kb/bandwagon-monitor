import Foundation
import SwiftUI

struct BudgetBasis: Codable {
    var averagePerDay: Double?
    var days: Int = 0
    // Only use sufficiently covered, completed local days; never extrapolate missing days as zero.
    static func calculate(_ samples: [UsagePoint], multiplier: Double?, now: Date = Date(), calendar: Calendar = .current) -> BudgetBasis {
        guard let multiplier, multiplier.isFinite, multiplier > 0 else { return BudgetBasis() }
        let today = calendar.startOfDay(for:now)
        var totals: [Double] = []
        for offset in 1...7 {
            guard let start = calendar.date(byAdding:.day,value:-offset,to:today), let end = calendar.date(byAdding:.day,value:1,to:start) else { continue }
            let rows = samples.filter { $0.time >= start && $0.time < end }.sorted { $0.time < $1.time }
            let slots = Set(rows.map { Int($0.time.timeIntervalSince(start) / 300) })
            guard let first = rows.first, let last = rows.last,
                  first.time.timeIntervalSince(start) <= 900, end.timeIntervalSince(last.time) <= 900,
                  Double(slots.count) * 300 >= end.timeIntervalSince(start) * 0.9,
                  zip(rows,rows.dropFirst()).allSatisfy({ $1.time.timeIntervalSince($0.time) <= 900 }) else { continue }
            let total = rows.reduce(0) { $0 + $1.total } * multiplier
            if total.isFinite && total >= 0 { totals.append(total) }
        }
        return BudgetBasis(averagePerDay:totals.isEmpty ? nil : totals.reduce(0,+)/Double(totals.count),days:totals.count)
    }
}
struct TrafficBudget {
    var remaining: Double?
    var reset: Date?
    var basis: BudgetBasis?
    var now: Date = Date()
    var seconds: Double? { reset.flatMap { $0 > now ? $0.timeIntervalSince(now) : nil } }
    var days: Int? { seconds.map { max(1,Int(ceil(($0 - 1) / 86400))) } }
    var allowance: Double? {
        guard let remaining, remaining.isFinite, remaining >= 0, let seconds else { return nil }
        return remaining / max(1,seconds / 86400)
    }
    var projected: Double? {
        guard allowance != nil, let remaining, let seconds, let average = basis?.averagePerDay, average.isFinite, average >= 0 else { return nil }
        return remaining - average * seconds / 86400
    }
    var status: String {
        guard seconds != nil else { return reset == nil ? "等待重置日期" : "等待服务端重置" }
        guard allowance != nil else { return "等待额度数据" }
        guard let projected else { return "历史覆盖不足，暂不预测" }
        return projected < 0 ? "按近期用量，可能提前耗尽" : "按近期用量，预计够用"
    }
    static func test() throws {
        var cal = Calendar(identifier:.gregorian); cal.timeZone = TimeZone(secondsFromGMT:0)!
        let now = Date(timeIntervalSince1970:1800057600)
        let start = cal.startOfDay(for:now).addingTimeInterval(-86400)
        let rows = (0..<288).map { UsagePoint(time:start.addingTimeInterval(Double($0)*300),incoming:1,outgoing:1) }
        let basis = BudgetBasis.calculate(rows,multiplier:2,now:now,calendar:cal)
        guard basis.days == 1, basis.averagePerDay == 1152,
              BudgetBasis.calculate(Array(rows.prefix(100)),multiplier:1,now:now,calendar:cal).averagePerDay == nil else { throw NSError(domain:"Budget coverage",code:1) }
        let budget = TrafficBudget(remaining:100,reset:now.addingTimeInterval(2*86400),basis:BudgetBasis(averagePerDay:60,days:1),now:now)
        guard budget.allowance == 50, budget.projected == -20,
              TrafficBudget(remaining:100,reset:now,basis:basis,now:now).allowance == nil,
              TrafficBudget(remaining:100,reset:now.addingTimeInterval(3600),now:now).allowance == 100 else { throw NSError(domain:"Budget math",code:1) }
        print("PASS: 流量预算倍率、完整日覆盖、缺失历史、重置边界与预计超额")
    }
}
struct DashboardMetric: View {
    var title: String
    var value: String
    var compact = false
    var body: some View {
        VStack(alignment:.leading,spacing:3) {
            Text(title).font(.system(size:compact ? 9 : 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size:compact ? 17 : 22,weight:.semibold,design:.rounded)).foregroundStyle(Color.mint).lineLimit(1).minimumScaleFactor(0.6)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
struct BudgetCard: View {
    var snapshot: WidgetSnapshot
    var now = Date()
    var compact = false
    var budget: TrafficBudget { TrafficBudget(remaining:snapshot.remaining,reset:snapshot.reset.map(Date.init(timeIntervalSince1970:)),basis:snapshot.budgetBasis,now:now) }
    var body: some View {
        VStack(alignment:.leading,spacing:compact ? 5 : 12) {
            HStack {
                DashboardMetric(title:"每日可用 · 均摊",value:widgetBytes(budget.allowance),compact:compact)
                DashboardMetric(title:"距重置",value:budget.days.map { "约 \($0) 天" } ?? "—",compact:compact)
            }
            Text(budget.status).font(.system(size:compact ? 10 : 12)).foregroundStyle((budget.projected ?? 0) < 0 ? Color.orange : Color.secondary)
            if compact, let projected = budget.projected {
                Text("重置前预计" + (projected < 0 ? "不足 " : "剩余 ") + widgetBytes(abs(projected)) + " · 估算").font(.system(size:9)).foregroundStyle(.secondary)
            }
            if !compact {
                HStack {
                    DashboardMetric(title:"当前剩余",value:widgetBytes(snapshot.remaining))
                    DashboardMetric(title:(budget.projected ?? 0) < 0 ? "预计不足 · 重置前" : "预计剩余 · 重置前",value:widgetBytes(budget.projected.map(abs)))
                }
                Text("按最近 7 天内覆盖充分的 \(snapshot.budgetBasis?.days ?? 0) 个自然日日均用量估算，非保证值。距重置不足一天时，每日预算等于剩余额度。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct TodayCard: View {
    var snapshot: WidgetSnapshot
    var now = Date()
    var compact = false
    var body: some View {
        VStack(alignment:.leading,spacing:compact ? 6 : 12) {
            HStack {
                DashboardMetric(title:"今日流量 · 累计",value:widgetBytes(UsageHistory.dayTotal(snapshot.trend ?? [],offset:0,now:now)),compact:compact)
                DashboardMetric(title:"运行状态",value:snapshot.state,compact:compact)
            }
            HStack {
                DashboardMetric(title:"CPU 使用率",value:snapshot.cpuTrend?.last?.cpuPercent.map { String(format:"%.1f%%",$0) } ?? "—",compact:compact)
                DashboardMetric(title:"内存使用率",value:memoryPercent(snapshot.memory),compact:compact)
            }
            if !compact {
                HStack {
                    DashboardMetric(title:"已用内存",value:widgetBytes(snapshot.memory?.used))
                    DashboardMetric(title:"周期剩余流量",value:widgetBytes(snapshot.remaining))
                }
                Text("今日流量为原始入站＋出站累计；CPU 是接口最近统计值。各项采样时间可能不同。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
