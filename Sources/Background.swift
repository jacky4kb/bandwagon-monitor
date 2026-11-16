import Foundation
import ServiceManagement

enum BackgroundService {
    static var service: SMAppService { .agent(plistName:"local.bandwagon.monitor.autostart.plist") }
    static var statusText: String {
        switch service.status {
        case .enabled: return "已开启"
        case .requiresApproval: return "等待系统允许"
        case .notRegistered: return "已关闭"
        case .notFound: return "启动服务未安装"
        @unknown default: return "未知"
        }
    }
}
