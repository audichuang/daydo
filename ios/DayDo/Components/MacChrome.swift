import Observation
import SwiftUI
import DayDoCore

enum MacCalChrome {
    static let height: CGFloat = 28
    static let cornerRadius: CGFloat = 6
}

struct MacCalendarIconButton: View {
    var systemName: String
    var label: String
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: MacCalChrome.height, height: MacCalChrome.height)
                .background(
                    RoundedRectangle(cornerRadius: MacCalChrome.cornerRadius, style: .continuous)
                        .fill(isHovered ? Palette.control : Palette.card)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: MacCalChrome.cornerRadius, style: .continuous)
                        .strokeBorder(Palette.separator, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: MacCalChrome.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct MacCalendarModeMenu<MenuContent: View>: View {
    var mode: CalMode
    var isActive: Bool
    @ViewBuilder var menuContent: () -> MenuContent
    @State private var isHovered = false

    private var labelView: some View {
        HStack(spacing: 5) {
            Text(mode.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.text)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: MacCalChrome.height)
        .background(
            RoundedRectangle(cornerRadius: MacCalChrome.cornerRadius, style: .continuous)
                .fill(isHovered ? Palette.control : Palette.card)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MacCalChrome.cornerRadius, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: MacCalChrome.cornerRadius, style: .continuous))
    }

    var body: some View {
        if isActive {
            Menu {
                menuContent()
            } label: {
                labelView
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .onHover { isHovered = $0 }
            .accessibilityLabel("切換檢視：目前\(mode.label)")
            .accessibilityIdentifier("calendarModeMenu")
        } else {
            labelView.accessibilityHidden(true)
        }
    }
}

struct MacCalendarNavControl: View {
    var onPrev: () -> Void
    var onToday: () -> Void
    var onNext: () -> Void
    @State private var hoveredSegment: Int?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPrev) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .frame(width: 26, height: MacCalChrome.height)
                    .background(hoveredSegment == 0 ? Palette.control : Palette.card)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveredSegment = $0 ? 0 : (hoveredSegment == 0 ? nil : hoveredSegment) }
            .help("上一頁")
            .accessibilityLabel("上一頁")
            .accessibilityIdentifier("calendarPrev")

            Rectangle().fill(Palette.separator).frame(width: 1, height: MacCalChrome.height)

            Button(action: onToday) {
                Text("今天")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 10)
                    .frame(height: MacCalChrome.height)
                    .background(hoveredSegment == 1 ? Palette.control : Palette.card)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveredSegment = $0 ? 1 : (hoveredSegment == 1 ? nil : hoveredSegment) }
            .help("回到今天 (T)")
            .accessibilityLabel("回到今天")
            .accessibilityIdentifier("calendarToday")

            Rectangle().fill(Palette.separator).frame(width: 1, height: MacCalChrome.height)

            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .frame(width: 26, height: MacCalChrome.height)
                    .background(hoveredSegment == 2 ? Palette.control : Palette.card)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveredSegment = $0 ? 2 : (hoveredSegment == 2 ? nil : hoveredSegment) }
            .help("下一頁")
            .accessibilityLabel("下一頁")
            .accessibilityIdentifier("calendarNext")
        }
        .clipShape(RoundedRectangle(cornerRadius: MacCalChrome.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MacCalChrome.cornerRadius, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1)
        }
    }
}

struct MacCalendarMoreMenu<MenuContent: View>: View {
    var isActive: Bool
    @ViewBuilder var menuContent: () -> MenuContent
    @State private var isHovered = false

    private var labelView: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.text)
            .frame(width: MacCalChrome.height, height: MacCalChrome.height)
            .background(
                RoundedRectangle(cornerRadius: MacCalChrome.cornerRadius, style: .continuous)
                    .fill(isHovered ? Palette.control : Palette.card)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MacCalChrome.cornerRadius, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: MacCalChrome.cornerRadius, style: .continuous))
    }

    var body: some View {
        if isActive {
            Menu {
                menuContent()
            } label: {
                labelView
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .onHover { isHovered = $0 }
            .help("更多選項")
            .accessibilityLabel("更多選項")
        } else {
            labelView.accessibilityHidden(true)
        }
    }
}
