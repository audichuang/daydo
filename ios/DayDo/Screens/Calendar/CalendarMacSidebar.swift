import SwiftUI
import DayDoCore

/// Mac calendar sidebar (desktop calendar layout): a mini month to jump to any day and
/// the list filter as always-visible rows instead of a submenu.
struct CalendarMacSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var shownMonth: LocalDay
    var busyDays: Set<LocalDay>
    @Binding var projectFilter: String?
    var openMonth: (LocalDay) -> Void
    var openDay: (LocalDay) -> Void

    var body: some View {
        let mask: UInt32 = busyDays.reduce(0) { m, d in
            d.year == shownMonth.year && d.month == shownMonth.month ? m | (1 << UInt32(d.day)) : m
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                YearMonthCell(
                    year: shownMonth.year,
                    month: shownMonth.month,
                    today: model.today,
                    busyMask: mask,
                    isRegular: true,
                    reduceMotion: reduceMotion,
                    openMonth: openMonth,
                    openDay: openDay
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("清單").txt(12, .semibold).foregroundStyle(Palette.textTertiary)
                        .padding(.leading, 8).padding(.bottom, 4)
                    macFilterRow(id: nil, name: "全部清單", color: nil)
                    ForEach(model.projects) { p in
                        macFilterRow(id: p.id, name: p.name, color: p.color)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .frame(width: 236)
    }

    private func macFilterRow(id: String?, name: String, color: String?) -> some View {
        let on = projectFilter == id
        return Button {
            projectFilter = id
        } label: {
            HStack(spacing: 8) {
                if id == nil {
                    Image(systemName: "tray.full").font(.system(size: 12)).foregroundStyle(Palette.textSecondary).frame(width: 12)
                } else {
                    ListDot(color: color, size: 9).frame(width: 12)
                }
                Text(name).txt(13, on ? .semibold : .regular).foregroundStyle(on ? Palette.text : Palette.textBody).lineLimit(1)
                Spacer(minLength: 4)
                if on {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent.text)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? accent.soft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
