import SwiftUI
import DayDoCore

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let a = s.count == 8 ? Double(v & 0xFF) / 255 : 1
        if s.count == 8 { v >>= 8 }
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
    }
}

/// Design tokens from the 視覺系統 board (16). Colors each have one job.
enum Palette {
    static let background = Color(hex: "#0E0F10")
    static let card = Color(hex: "#18191B")
    static let raised = Color(hex: "#1F2123")
    static let control = Color(hex: "#232527")
    static let chip = Color(hex: "#2A2C2E")
    static let separator = Color(hex: "#26282A")
    static let separatorSoft = Color(hex: "#2A2C2E")
    static let text = Color(hex: "#F1F3F2")
    static let textBody = Color(hex: "#D3D8D6")
    static let textSecondary = Color(hex: "#9BA3A0")
    static let textTertiary = Color(hex: "#8A928F")
    static let textFaint = Color(hex: "#6E7673")
    static let textMuted = Color(hex: "#B7BEBB")
    static let textNav = Color(hex: "#C9CFCC")
    static let done = Color(hex: "#7A827F")
    static let overdue = Color(hex: "#FF7A70")
    static let conflict = Color(hex: "#F7B500")
    static let danger = Color(hex: "#FF7A70")
    static let handle = Color(hex: "#3A3D40")

    static let accentOptions = ["#FF8A1E", "#4772FA", "#2BB673", "#8B6CE8"]
    static let listColors: [(String, String)] = [("無", "#5B6461"), ("紅", "#F2555A"), ("橘", "#E98A5B"), ("黃", "#E8C14E"), ("綠", "#4FC3A1"), ("天藍", "#4AA8E8"), ("靛", "#4E8BF7"), ("紫", "#C77DDB")]
    static let tagColors = ["#B6C1FF", "#F3C978", "#9FE0C4", "#FFB3A8", "#D6B3FF", "#8FD3FF"]

    static func priority(_ p: Priority) -> Color {
        switch p {
        case .high: Color(hex: "#F2555A")
        case .medium: Color(hex: "#F7B500")
        case .low: Color(hex: "#4E8BF7")
        case .none: Color(hex: "#7C8582")
        }
    }

    static func listColor(_ hex: String?) -> Color { Color(hex: hex ?? "#5B6461") }

    /// Pastel chip colors for a tag (stable per name when no color is set).
    static func tagStyle(_ name: String, color: String?) -> (Color, Color) {
        let fg = Color(hex: color ?? tagColors[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % tagColors.count])
        return (fg.opacity(0.16), fg)
    }
}

/// The user-chosen accent and derived colors (button text adapts to the
/// accent's luminance so it stays readable).
struct AccentTheme: Equatable {
    var hex: String

    var color: Color { Color(hex: hex) }

    private var rgb: (Double, Double, Double) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// Accent mixed 10% toward white, used for text on dark surfaces.
    var text: Color {
        let (r, g, b) = rgb
        return Color(.sRGB, red: r * 0.9 + 0.1, green: g * 0.9 + 0.1, blue: b * 0.9 + 0.1)
    }

    var onAccent: Color {
        let lin = { (c: Double) in c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = rgb
        let l = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return l > 0.3 ? Color(hex: "#1A1206") : .white
    }

    var soft: Color { color.opacity(0.18) }
}

private struct AccentKey: EnvironmentKey { static let defaultValue = AccentTheme(hex: "#FF8A1E") }
private struct ScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var accent: AccentTheme {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
    var textScale: CGFloat {
        get { self[ScaleKey.self] }
        set { self[ScaleKey.self] = newValue }
    }
}

/// Type scale (30/22/17/15/14/13/11) multiplied by the user's text size.
struct Txt: ViewModifier {
    @Environment(\.textScale) private var scale
    var size: CGFloat
    var weight: Font.Weight
    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight))
    }
}

extension View {
    func txt(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View { modifier(Txt(size: size, weight: weight)) }

    /// Glass material for the top toolbar and bottom navigation only.
    func glassCapsule() -> some View {
        self.glassEffect(.regular.tint(Color(hex: "#282A2C").opacity(0.55)), in: .capsule)
    }

    func card(_ radius: CGFloat = 16, color: Color = Palette.card) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
