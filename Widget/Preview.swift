import AppKit
import SwiftUI
import WidgetKit
@main struct WidgetPreview {
    @MainActor static func main() {
        let path = CommandLine.arguments[1]
        let variants: [(String, WidgetFamily, CGFloat, CGFloat)] = [("traffic",.systemSmall,164,164),("traffic",.systemMedium,344,164),("traffic",.systemLarge,344,344),("resources",.systemMedium,344,164),("resources",.systemLarge,344,344),("network",.systemMedium,344,164),("network",.systemLarge,344,344),("history",.systemMedium,344,164),("history",.systemLarge,344,344),("budget",.systemMedium,344,164),("budget",.systemLarge,344,344),("today",.systemMedium,344,164),("today",.systemLarge,344,344)]
        for (i, v) in variants.enumerated() {
            let renderer = ImageRenderer(content: MonitorWidgetView(previewFamily: v.1, entry: MonitorEntry(date: Date(), snapshot: .sample, preview: true), category: v.0).padding(16).frame(width: v.2,height:v.3).background(Color(red:0.055,green:0.085,blue:0.11)).clipShape(RoundedRectangle(cornerRadius:20)))
            renderer.scale = 2
            if let image = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: image)
                try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path).appendingPathComponent("widget-\(i).png"))
            }
        }
        let snapshot = WidgetSnapshot.sample
        let data = try! JSONEncoder().encode(snapshot)
        let decoded = try! JSONDecoder().decode(WidgetSnapshot.self,from:data)
        precondition(decoded.remaining == snapshot.remaining)
        let json = String(data:data,encoding:.utf8)!
        precondition(!json.contains("api_key") && !json.contains("email") && !json.contains("secret"))
        print("PASS: widget snapshot round-trip; no credentials or email fields")
    }
}
