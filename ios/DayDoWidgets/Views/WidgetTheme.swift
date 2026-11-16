import SwiftUI
import WidgetKit
import DayDoCore

enum WidgetPalette {
    static let background = color("#1A1B1D")
    static let border = color("#26282A")
    static let divider = color("#26282A")
    static let dividerSoft = color("#2A2C2E")
    static let text = color("#F1F3F2")
    static let textSecondary = color("#9BA3A0")
    static let textTertiary = color("#8A928F")
    static let textMuted = color("#737B78")
    static let textSection = color("#C9CFCC")
    static let textDay = color("#E6E9E8")
    static let doneBackground = color("#26282A")
    static let doneText = color("#7A827F")
    static let overdue = color("#FF7A70")

    static func priority(_ p: Priority) -> Color {
        switch p {
        case .high: return color("#F2555A")
        case .medium: return color("#F7B500")
        case .low: return color("#4E8BF7")
        case .none: return color("#7C8582")
        }
    }

    static func listColor(_ hex: String?) -> Color {
        color(hex ?? "#5B6461")
    }

    static func mixedWithWhite(_ hex: String?, amount: Double) -> Color {
        let (r, g, b) = parseRGB(hex ?? "#5B6461")
        let p = max(0, min(1, amount))
        return Color(.sRGB, red: r * (1 - p) + p, green: g * (1 - p) + p, blue: b * (1 - p) + p)
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

    var text: Color { WidgetPalette.mixedWithWhite(hex, amount: 0.1) }

    var onAccent: Color {
        let lin = { (c: Double) in c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = WidgetPalette.parseRGB(hex)
        let l = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return l > 0.3 ? WidgetPalette.color("#1A1206") : .white
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
