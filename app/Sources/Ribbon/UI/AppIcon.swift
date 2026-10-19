import SwiftUI
import AppKit

/// The app icon: a soft gradient squircle holding three frosted panels (the ribbon), the middle one in focus.
/// Designed on a 1024pt canvas; `size` scales everything.
struct AppIconView: View {
    var size: CGFloat = 1024

    private let panels: [(width: CGFloat, height: CGFloat, focused: Bool)] = [(150, 400, false), (232, 480, true), (118, 400, false)]

    var body: some View {
        let s = size / 1024
        let body = 824 * s
        let radius = body * 0.2237
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape
                .fill(LinearGradient(stops: [.init(color: Color(hex: 0x6B7CFF), location: 0),
                                             .init(color: Color(hex: 0xB7A6FF), location: 0.42),
                                             .init(color: Color(hex: 0xFFC9B0), location: 0.9)],
                                     startPoint: UnitPoint(x: 0.1, y: 0), endPoint: UnitPoint(x: 0.9, y: 1)))
                .overlay(  // soft light from the top left
                    RadialGradient(colors: [.white.opacity(0.45), .clear], center: UnitPoint(x: 0.2, y: 0.05),
                                   startRadius: 0, endRadius: body * 0.75).clipShape(shape))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.05)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 3 * s))
                .frame(width: body, height: body)
                .shadow(color: Color(hex: 0x2A2F6B).opacity(0.35), radius: 22 * s, x: 0, y: 12 * s)

            HStack(spacing: 34 * s) {
                ForEach(panels.indices, id: \.self) { i in
                    let p = panels[i]
                    panel(width: p.width * s, height: p.height * s, focused: p.focused, s: s)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func panel(width: CGFloat, height: CGFloat, focused: Bool, s: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 58 * s, style: .continuous)
        return shape
            .fill(focused
                  ? LinearGradient(colors: [.white.opacity(0.98), .white.opacity(0.74)], startPoint: .top, endPoint: .bottom)
                  : LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.32)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(focused ? 0.95 : 0.7), .white.opacity(0.12)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 2.5 * s))
            .frame(width: width, height: height)
            .shadow(color: focused ? Color.white.opacity(0.9) : .clear, radius: 46 * s)
            .shadow(color: Color(hex: 0x3A3F9E).opacity(focused ? 0.30 : 0.16), radius: 16 * s, x: 0, y: 10 * s)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// `Ribbon --render-icon <dir>` writes `<dir>/Ribbon.iconset/*.png` (16...1024 at 1x and 2x) for `iconutil`.
@MainActor
enum IconRenderer {
    static func run(dir: String) -> Int32 {
        _ = NSApplication.shared
        let set = URL(fileURLWithPath: dir).appendingPathComponent("Ribbon.iconset")
        try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let r = ImageRenderer(content: AppIconView(size: CGFloat(px)))
                r.scale = 1   // the view is sized in pixels already
                guard let cg = r.cgImage,
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                    print("FAIL \(px)px"); return 1
                }
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? png.write(to: set.appendingPathComponent(name))
            }
        }
        print("wrote \(set.path)")
        return 0
    }
}
