import SwiftUI
import DayDoCore

/// Round glass button used in the top toolbar (44×44 hit area).
struct GlassIconButton: View {
    var systemName: String
    var label: String
    var tint: Color = Palette.text
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// The 20pt square checkbox with priority-colored outline (1b).
struct TaskCheckbox: View {
    @Environment(\.accent) private var accent
    var done: Bool
    var priority: Priority
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(done ? accent.color : Palette.priority(priority), lineWidth: 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(done ? accent.color : .clear))
            .overlay {
                if done {
                    Image(systemName: "checkmark").font(.system(size: size * 0.55, weight: .heavy)).foregroundStyle(Palette.background)
                }
            }
            .frame(width: size, height: size)
    }
}

struct ListDot: View {
    var color: String?
    var size: CGFloat = 7
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3).fill(Palette.listColor(color)).frame(width: size, height: size)
    }
}

struct AvatarStack: View {
    var members: [Member]
    var size: CGFloat = 18
    var body: some View {
        HStack(spacing: -4) {
            ForEach(members) { m in
                Text(m.initial)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(Palette.background)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color(hex: m.color)))
                    .overlay(Circle().stroke(Palette.card, lineWidth: 1.5))
            }
        }
    }
}

struct TagChip: View {
    var name: String
    var label: String
    var color: String?
    var body: some View {
        let (bg, fg) = Palette.tagStyle(name, color: color)
        Text("# " + label)
            .txt(12, .medium)
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(bg))
    }
}

/// Pill used for options (reminders, repeat, durations).
struct OptionChip: View {
    @Environment(\.accent) private var accent
    var label: String
    var on: Bool
    var filled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .txt(13, .semibold)
                .foregroundStyle(on ? (filled ? accent.onAccent : accent.text) : Palette.textNav)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(on ? (filled ? accent.color : accent.soft) : (filled ? Palette.chip : .clear)))
                .overlay(Capsule().strokeBorder(on ? accent.color : (filled ? .clear : Color(hex: "#33363A")), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Primary/secondary pill buttons in sheet headers (取消 / 儲存 / 確定).
struct PillButton: View {
    @Environment(\.accent) private var accent
    enum Kind { case primary, secondary, disabled }
    var title: String
    var kind: Kind = .secondary
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .txt(14, kind == .secondary ? .semibold : .bold)
                .foregroundStyle(kind == .primary ? accent.onAccent : (kind == .disabled ? Color(hex: "#737B78") : Color(hex: "#E6E9E8")))
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(Capsule().fill(kind == .primary ? accent.color : (kind == .disabled ? Palette.separator : Palette.control)))
        }
        .buttonStyle(.plain)
        .disabled(kind == .disabled)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

/// Small date calendar used by the date panel (4b).
struct MonthPicker: View {
    @Environment(\.accent) private var accent
    @Binding var month: LocalDay
    var selected: LocalDay?
    var today: LocalDay
    var pick: (LocalDay) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { month = month.adding(months: -1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 32) }
                Spacer()
                Text(month.year == LocalDay(date: Date(), in: .current).year ? "\(month.month)月" : "\(String(month.year)) 年 \(month.month) 月").txt(17, .bold).foregroundStyle(Palette.text)
                Spacer()
                Button { month = month.adding(months: 1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 32) }
            }
            .foregroundStyle(Palette.textSecondary)
            .buttonStyle(.plain)
            HStack(spacing: 0) {
                ForEach(LocalDay.weekdaySymbols, id: \.self) { w in
                    Text(w).txt(11).foregroundStyle(Palette.textTertiary).frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 2)
            let days = MonthLayout.gridDays(for: month)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { d in
                    let sel = d == selected, isToday = d == today, inMonth = d.month == month.month
                    Button { pick(d) } label: {
                        Text("\(d.day)")
                            .txt(14, sel || isToday ? .bold : .medium)
                            .foregroundStyle(sel ? accent.onAccent : (isToday ? accent.color : Color(hex: "#E6E9E8")))
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(sel ? accent.color : (isToday ? Color.white : .clear)))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(inMonth ? 1 : 0.38)
                    .accessibilityLabel(DateText.full(d))
                    .accessibilityIdentifier("monthDay.\(d)")
                    .accessibilityAddTraits(sel ? .isSelected : [])
                }
            }
        }
    }
}

extension Int64 {
    var byteText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
