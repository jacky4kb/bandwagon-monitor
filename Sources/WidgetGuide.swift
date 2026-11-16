import SwiftUI
import WidgetKit

struct WidgetGuideView: View {
    @Environment(\.dismiss) private var dismiss
    private let cards = [
        ("today","今日概览","中 / 大","今日流量、CPU%、内存%和运行状态。"),
        ("budget","流量预算","中 / 大","每日可用额度、重置倒计时与近期用量预测。"),
        ("traffic","搬瓦工流量","小 / 中 / 大","剩余流量与近七天趋势。"),
        ("resources","CPU 与内存走势图","中 / 大","CPU 和内存使用率走势；原名 VPS 资源。"),
        ("history","流量走势图","中 / 大","昨天、今天的流量及七天曲线。"),
        ("network","VPS 网络","中 / 大","主机、机房与网络信息。")
    ]
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("添加桌面小组件").font(.title3.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("1. 在桌面空白处右键，选择「编辑小组件」。\n2. 搜索并选择「搬瓦工监控」。\n3. 在右侧向下滚动，找到卡片名称，选择尺寸后拖到桌面。").font(.system(size:13)).lineSpacing(5)
            Text("下方均为模拟预览；卡片名称与系统列表一致。更新后若列表未变化，关闭再打开编辑面板。保持应用后台运行才能更新数据。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    ForEach(cards,id:\.0) { card in
                        VStack(alignment:.leading,spacing:6) {
                            HStack { Text(card.1).font(.headline); Spacer(); Text(card.2).font(.caption).foregroundStyle(.secondary) }
                            Text(card.3).font(.caption).foregroundStyle(.secondary)
                            MonitorWidgetView(previewFamily:.systemMedium,entry:MonitorEntry(date:Date(),snapshot:.sample,preview:true),category:card.0)
                                .padding(16).frame(width:344,height:164)
                                .background(Color(red:0.055,green:0.085,blue:0.11))
                                .clipShape(RoundedRectangle(cornerRadius:20))
                                .allowsHitTesting(false)
                                .frame(maxWidth:.infinity)
                        }
                    }
                }.padding(.vertical,8)
            }
        }.padding(22).frame(width:500,height:690).background(backdrop).preferredColorScheme(.dark)
    }
}
