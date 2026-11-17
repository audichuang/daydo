import SwiftUI
import UIKit
import WidgetKit
import DayDoCore

enum WidgetPalette {
    private static func dynamic(dark: String, light: String) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light ? uiColor(light) : uiColor(dark)
        })
    }

    private static func uiColor(_ hex: String) -> UIColor {
        let (r, g, b, a) = parseRGBA(hex)
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    static let background = dynamic(dark: "#1A1B1D", light: "#FFFFFF")
    static let border = dynamic(dark: "#26282A", light: "#E3E5E7")
    static let divider = dynamic(dark: "#26282A", light: "#E7E9EB")
    static let dividerSoft = dynamic(dark: "#2A2C2E", light: "#E7E9EB")
    static let text = dynamic(dark: "#F1F3F2", light: "#111314")
    static let textSecondary = dynamic(dark: "#9BA3A0", light: "#5F6764")
    static let textTertiary = dynamic(dark: "#8A928F", light: "#6F7774")
    static let textMuted = dynamic(dark: "#737B78", light: "#767E7B")
    static let textSection = dynamic(dark: "#C9CFCC", light: "#3A403E")
    static let textDay = dynamic(dark: "#E6E9E8", light: "#1D201F")
    static let doneBackground = dynamic(dark: "#26282A", light: "#ECEDEF")
    static let doneText = dynamic(dark: "#7A827F", light: "#7C8481")
    static let overdue = dynamic(dark: "#FF7A70", light: "#D9383E")

    static func priority(_ p: Priority) -> Color {
        switch p {
        case .high: return dynamic(dark: "#F2555A", light: "#E03E43")
        case .medium: return dynamic(dark: "#F7B500", light: "#C98F00")
        case .low: return dynamic(dark: "#4E8BF7", light: "#3270DF")
        case .none: return dynamic(dark: "#7C8582", light: "#8A928F")
        }
    }

    static func listColor(_ hex: String?) -> Color {
        color(hex ?? "#5B6461")
    }

    static func tintedListText(_ hex: String?, darkAmount: Double = 0.45, lightAmount: Double = 0.45) -> Color {
        let (r, g, b) = parseRGB(hex ?? "#5B6461")
        let pd = max(0, min(1, darkAmount))
        let pl = max(0, min(1, lightAmount))
        return Color(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .light {
                return UIColor(red: r * (1 - pl), green: g * (1 - pl), blue: b * (1 - pl), alpha: 1)
            }
            return UIColor(red: r * (1 - pd) + pd, green: g * (1 - pd) + pd, blue: b * (1 - pd) + pd, alpha: 1)
        })
    }

    static func color(_ hex: String) -> Color {
        let (r, g, b, a) = parseRGBA(hex)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    static func parseRGB(_ hex: String) -> (Double, Double, Double) {
        let (r, g, b, _) = parseRGBA(hex)
        return (r, g, b)
    }

    private static func parseRGBA(_ hex: String) -> (Double, Double, Double, Double) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let a = s.count == 8 ? Double(v & 0xFF) / 255 : 1
        if s.count == 8 { v >>= 8 }
        return (
            Double((v >> 16) & 0xFF) / 255,
            Double((v >> 8) & 0xFF) / 255,
            Double(v & 0xFF) / 255,
            a
        )
    }
}

struct WidgetAccent: Equatable, Sendable {
    static let defaultHex = "#FF8A1E"
    static let defaultsKey = "accent"

    var hex: String

    init(hex: String = WidgetAccent.defaultHex) {
        self.hex = hex
    }

    static func fromSharedDefaults() -> WidgetAccent {
        let hex = UserDefaults(suiteName: DayDoStorage.appGroup)?.string(forKey: defaultsKey)
        if let hex, !hex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return WidgetAccent(hex: hex)
        }
        return WidgetAccent(hex: defaultHex)
    }

    var color: Color { WidgetPalette.color(hex) }

    var text: Color { WidgetPalette.tintedListText(hex, darkAmount: 0.1, lightAmount: 0.3) }

    var onAccent: Color {
        let lin = { (c: Double) in c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = WidgetPalette.parseRGB(hex)
        let l = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return l > 0.3 ? WidgetPalette.color("#1A1206") : .white
    }
}

enum WidgetAppearance {
    static func fromSharedDefaults() -> AppAppearance {
        AppAppearance.from(defaults: UserDefaults(suiteName: DayDoStorage.appGroup))
    }
}

private struct WidgetAppearanceModifier: ViewModifier {
    var appearance: AppAppearance

    @ViewBuilder
    func body(content: Content) -> some View {
        switch appearance {
        case .dark:
            content.environment(\.colorScheme, .dark)
        case .light:
            content.environment(\.colorScheme, .light)
        case .system:
            content
        }
    }
}

struct WidgetPriorityBox: View {
    var priority: Priority
    var size: CGFloat
    var cornerRadius: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(WidgetPalette.priority(priority), lineWidth: lineWidth)
            .frame(width: size, height: size)
    }
}

struct WidgetUnavailableView: View {
    var title: String
    var message: String
    var accent: WidgetAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent.text)
            Spacer(minLength: 0)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(WidgetPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension View {
    func widgetAppearance(_ appearance: AppAppearance) -> some View {
        modifier(WidgetAppearanceModifier(appearance: appearance))
    }

    func widgetPadding(for family: WidgetFamily) -> some View {
        let insets: EdgeInsets = switch family {
        case .systemSmall:
            EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        case .systemMedium:
            EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        case .systemLarge:
            EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14)
        default:
            EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        }
        return self.padding(insets)
    }
}
