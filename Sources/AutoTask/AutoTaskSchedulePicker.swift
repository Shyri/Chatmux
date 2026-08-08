import SwiftUI

/// Picks when an `/auto-task` run should start.
///
/// Shortcuts first, because the realistic answers are "tonight" and "tomorrow
/// night" — an autonomous run is something you leave going while you are not
/// at the machine. The full picker is there for the rest.
///
/// Takes no store and no model: it hands a `Date` to its caller and nothing
/// else, so it can sit inside a `LazyVStack` row without breaking the snapshot
/// boundary rule.
struct AutoTaskSchedulePicker: View {
    let issueIID: Int
    let onPick: (Date) -> Void

    @State private var customDate: Date = AutoTaskSchedulePicker.tonight()
    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(
                localized: "autoTask.schedule.title",
                defaultValue: "Schedule Auto-Task for #\(issueIID)"
            ))
            .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                shortcut(
                    title: String(localized: "autoTask.schedule.tonight", defaultValue: "Tonight at 03:00"),
                    date: Self.tonight(calendar: calendar)
                )
                shortcut(
                    title: String(localized: "autoTask.schedule.tomorrow", defaultValue: "Tomorrow at 03:00"),
                    date: Self.tonight(calendar: calendar).addingTimeInterval(24 * 3600)
                )
                shortcut(
                    title: String(localized: "autoTask.schedule.inAnHour", defaultValue: "In an hour"),
                    date: Date().addingTimeInterval(3600)
                )
            }

            Divider()

            DatePicker(
                String(localized: "autoTask.schedule.custom", defaultValue: "Custom"),
                selection: $customDate,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .font(.system(size: 11))

            HStack {
                Spacer()
                Button {
                    onPick(customDate)
                } label: {
                    Text(String(localized: "autoTask.schedule.confirm", defaultValue: "Schedule"))
                }
                .keyboardShortcut(.defaultAction)
            }

            Text(String(
                localized: "autoTask.schedule.footnote",
                defaultValue: "Runs only while cmux is open. If it is closed at that time, the task waits for you."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 260)
    }

    private func shortcut(title: String, date: Date) -> some View {
        Button {
            onPick(date)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(Self.relativeLabel(for: date))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
    }

    /// The next 03:00 — tonight if it has not passed yet, otherwise tomorrow's.
    /// Built from calendar components rather than by adding seconds, so it lands
    /// on the wall clock across a DST change.
    static func tonight(calendar: Calendar = .current, now: Date = Date()) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 3
        components.minute = 0
        components.second = 0
        let candidate = calendar.date(from: components) ?? now
        if candidate > now { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? now.addingTimeInterval(3600)
    }

    private static func relativeLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
