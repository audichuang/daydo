import SwiftUI
import UIKit
import DayDoCore

extension Color {
    init(hex: String) {
        let (r, g, b, a) = Self.parseRGBA(hex)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    fileprivate static func parseRGBA(_ hex: String) -> (Double, Double, Double, Double) {
        var s = hex.trimmingCharacters(in: .whitespaces)
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

private extension UIColor {
    convenience init(hex: String, alpha: CGFloat? = nil) {
        let (r, g, b, a) = Color.parseRGBA(hex)
        self.init(red: r, green: g, blue: b, alpha: alpha ?? a)
    }
}

/// Design tokens from the 視覺系統 board (16). Colors each have one job.
enum Palette {
    private static func dynamic(
        dark: String,
        light: String,
        darkAlpha: CGFloat? = nil,
        lightAlpha: CGFloat? = nil
    ) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor(hex: light, alpha: lightAlpha)
                : UIColor(hex: dark, alpha: darkAlpha)
        })
    }

    static let background = dynamic(dark: "#0E0F10", light: "#F2F3F5")
    static let card = dynamic(dark: "#18191B", light: "#FFFFFF")
    // Light uses #F4F5F7 so nested cards on white sheets stay distinct.
    static let raised = dynamic(dark: "#1F2123", light: "#F4F5F7")
    static let control = dynamic(dark: "#232527", light: "#ECEDEF")
    static let chip = dynamic(dark: "#2A2C2E", light: "#E7E9EB")
    static let separator = dynamic(dark: "#26282A", light: "#E3E5E7")
    static let separatorSoft = dynamic(dark: "#2A2C2E", light: "#E7E9EB")
    static let text = dynamic(dark: "#F1F3F2", light: "#111314")
    static let textBody = dynamic(dark: "#D3D8D6", light: "#2A2E2C")
    static let textSecondary = dynamic(dark: "#9BA3A0", light: "#5F6764")
    static let textTertiary = dynamic(dark: "#8A928F", light: "#6F7774")
    static let textFaint = dynamic(dark: "#6E7673", light: "#767E7B")
    static let textMuted = dynamic(dark: "#B7BEBB", light: "#4E5653")
    static let textNav = dynamic(dark: "#C9CFCC", light: "#3A403E")
    static let done = dynamic(dark: "#7A827F", light: "#7C8481")
    static let overdue = dynamic(dark: "#FF7A70", light: "#D9383E")
    static let conflict = dynamic(dark: "#F7B500", light: "#A87300")
    static let danger = dynamic(dark: "#FF7A70", light: "#D9383E")
    static let handle = dynamic(dark: "#3A3D40", light: "#C9CDCF")

    static let textDay = dynamic(dark: "#E6E9E8", light: "#1D201F")
    static let textDisabled = dynamic(dark: "#737B78", light: "#8C9491")
    static let gridLabel = dynamic(dark: "#737B78", light: "#767E7B")
    static let border = dynamic(dark: "#33363A", light: "#D5D8DC")
    static let gridLine = dynamic(dark: "#222426", light: "#E6E8EB")
    static let gridColumnLine = dynamic(dark: "#1E2022", light: "#ECEEF0")
    static let blockMuted = dynamic(dark: "#26292B", light: "#ECEDEF")
    static let blockMutedBorder = dynamic(dark: "#33373A", light: "#D5D8DC")
    static let overnightTint = dynamic(dark: "#F5A623", light: "#F5A623", darkAlpha: 0.05, lightAlpha: 0.08)
    static let checkboxMuted = dynamic(dark: "#5B6461", light: "#9AA19E")
    static let codeWell = dynamic(dark: "#121314", light: "#FFFFFF")
    static let segmentSelected = dynamic(dark: "#3A3D40", light: "#FFFFFF")
    static let segmentSelectedText = dynamic(dark: "#FFFFFF", light: "#111314")
    /// Dark ink used over pastel avatar/file-badge swatches in both schemes.
    static let onLightFill = Color(hex: "#0E0F10")
    static let pressHighlight = dynamic(dark: "#FFFFFF", light: "#000000", darkAlpha: 0.04, lightAlpha: 0.05)
    static let pressHighlightStrong = dynamic(dark: "#FFFFFF", light: "#000000", darkAlpha: 0.05, lightAlpha: 0.05)
    static let scrim = dynamic(dark: "#000000", light: "#000000", darkAlpha: 0.45, lightAlpha: 0.25)
    static let glassTint = dynamic(dark: "#282A2C", light: "#FFFFFF", darkAlpha: 0.55, lightAlpha: 0.72)
    static let navGlassTint = dynamic(dark: "#242628", light: "#FFFFFF", darkAlpha: 0.60, lightAlpha: 0.75)
    static let navSelection = dynamic(dark: "#FFFFFF", light: "#000000", darkAlpha: 0.08, lightAlpha: 0.07)
    static let navShadow = dynamic(dark: "#000000", light: "#000000", darkAlpha: 0.35, lightAlpha: 0.14)
    static let fabShadow = dynamic(dark: "#000000", light: "#000000", darkAlpha: 0.35, lightAlpha: 0.14)

    static let accentOptions = ["#FF8A1E", "#4772FA", "#2BB673", "#8B6CE8"]
    static let listColors: [(String, String)] = [("無", "#5B6461"), ("紅", "#F2555A"), ("橘", "#E98A5B"), ("黃", "#E8C14E"), ("綠", "#4FC3A1"), ("天藍", "#4AA8E8"), ("靛", "#4E8BF7"), ("紫", "#C77DDB")]
    static let tagColors = ["#B6C1FF", "#F3C978", "#9FE0C4", "#FFB3A8", "#D6B3FF", "#8FD3FF"]

    static func priority(_ p: Priority) -> Color {
        switch p {
        case .high: dynamic(dark: "#F2555A", light: "#E03E43")
        case .medium: dynamic(dark: "#F7B500", light: "#C98F00")
        case .low: dynamic(dark: "#4E8BF7", light: "#3270DF")
        case .none: dynamic(dark: "#7C8582", light: "#8A928F")
        }
    }

    static func listColor(_ hex: String?) -> Color { Color(hex: hex ?? "#5B6461") }

    static func avatarColor(_ hex: String?, fallback: String) -> Color {
        Color(hex: hex ?? fallback)
    }

    /// Pastel chip colors for a tag (stable per name when no color is set).
    static func tagStyle(_ name: String, color: String?) -> (Color, Color) {
        let hex = color ?? tagColors[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % tagColors.count]
        let (r, g, b, _) = Color.parseRGBA(hex)
        let darkFg = UIColor(red: r, green: g, blue: b, alpha: 1)
        let lightFg = UIColor(red: r * 0.45, green: g * 0.45, blue: b * 0.45, alpha: 1)
        let fg = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light ? lightFg : darkFg
        })
        let bg = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light
                ? lightFg.withAlphaComponent(0.13)
                : darkFg.withAlphaComponent(0.16)
        })
        return (bg, fg)
    }

    static func todayFill(accent: AccentTheme) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor(accent.color).withAlphaComponent(0.18)
                : UIColor.white
        })
    }

    static func todayText(accent: AccentTheme) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .light ? accent.text : accent.color
            return UIColor(c).resolvedColor(with: traits)
        })
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

    /// Accent mixed 10% toward white for dark surfaces, or 30% toward black for light surfaces.
    var text: Color {
        let (r, g, b) = rgb
        return Color(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .light {
                return UIColor(red: r * 0.7, green: g * 0.7, blue: b * 0.7, alpha: 1)
            }
            return UIColor(red: r * 0.9 + 0.1, green: g * 0.9 + 0.1, blue: b * 0.9 + 0.1, alpha: 1)
        })
    }

    var onAccent: Color {
        let lin = { (c: Double) in c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = rgb
        let l = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return l > 0.3 ? Color(hex: "#1A1206") : .white
    }

    var soft: Color { color.opacity(0.18) }
}

extension AppAppearance {
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: .unspecified
        }
    }
}

/// Applies `overrideUserInterfaceStyle` on every `UIWindow` of every connected
/// `UIWindowScene`, avoiding SwiftUI `.preferredColorScheme(nil)` issues on sheets.
@MainActor
enum AppearanceApplier {
    private(set) static var currentStyle: UIUserInterfaceStyle = .dark
    private static var installedObserver = false

    static func apply(_ appearance: AppAppearance) {
        applyStyle(appearance.userInterfaceStyle)
    }

    static func applyStyle(_ style: UIUserInterfaceStyle) {
        currentStyle = style
        installObserverIfNeeded()
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            apply(style, to: windowScene)
        }
    }

    private static func apply(_ style: UIUserInterfaceStyle, to windowScene: UIWindowScene) {
        if style == .unspecified {
            windowScene.traitOverrides.remove(UITraitUserInterfaceStyle.self)
        } else {
            windowScene.traitOverrides.userInterfaceStyle = style
        }
        for window in windowScene.windows where window.overrideUserInterfaceStyle != style {
            window.overrideUserInterfaceStyle = style
            window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
        }
    }

    private static func installObserverIfNeeded() {
        guard !installedObserver else { return }
        installedObserver = true
        NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification,
            object: nil,
            queue: nil
        ) { notification in
            let windowScene = notification.object as? UIWindowScene
            runOnMain {
                if let windowScene {
                    apply(currentStyle, to: windowScene)
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification,
            object: nil,
            queue: nil
        ) { notification in
            let window = notification.object as? UIWindow
            runOnMain {
                guard let window else { return }
                if let windowScene = window.windowScene {
                    apply(currentStyle, to: windowScene)
                }
                if window.overrideUserInterfaceStyle != currentStyle {
                    window.overrideUserInterfaceStyle = currentStyle
                    window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
                }
            }
        }
    }

    private nonisolated static func runOnMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }
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
        self.glassEffect(.regular.tint(Palette.glassTint), in: .capsule)
    }

    func card(_ radius: CGFloat = 16, color: Color = Palette.card) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
