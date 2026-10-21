import SwiftUI

/// Month grid coloured by each day's average mood (SPEC.md, Mood calendar).
struct MoodCalendarView: View {
    let store: EntryStore

    @State private var entries: [Entry] = []
    @State private var shown = DayDate.today
    @Environment(\.colorScheme) private var colorScheme

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    weekdayHeader
                    grid
                    Text(summary.line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    MoodLegend()
                    HStack(spacing: 16) {
                        Label {
                            Text("Not scored yet")
                        } icon: {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                .frame(width: 14, height: 14)
                        }
                        Label {
                            Text("Entries that day")
                        } icon: {
                            HStack(spacing: 2) { ForEach(0..<2, id: \.self) { _ in Circle().frame(width: 4, height: 4) } }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        if value.translation.width < -50, canGoForward { move(by: 1) }
                        if value.translation.width > 50 { move(by: -1) }
                    }
            )
            .navigationTitle("Mood")
            .navigationDestination(for: DayDate.self) { day in
                DayEntriesView(store: store, day: day)
            }
            .navigationDestination(for: EditorRoute.self) { route in
                EntryEditorView(store: store, entry: route.entry, isNew: route.isNew)
            }
        }
        .task {
            do {
                for try await entries in store.observeEntries() { self.entries = entries }
            } catch {}
        }
    }

    private var summary: MonthSummary {
        MonthSummary(year: shown.year, month: shown.month, entries: entries)
    }

    private var canGoForward: Bool {
        (shown.year, shown.month) < (DayDate.today.year, DayDate.today.month)
    }

    private func move(by months: Int) {
        let date = calendar.date(byAdding: .month, value: months, to: DayDate(year: shown.year, month: shown.month, day: 1).date())!
        withAnimation(.snappy) { shown = DayDate(date) }
    }

    private var header: some View {
        HStack {
            Button("Previous month", systemImage: "chevron.left") { move(by: -1) }
                .labelStyle(.iconOnly)
            Spacer()
            Text(DayDate(year: shown.year, month: shown.month, day: 1).date().formatted(.dateTime.month(.wide).year()))
                .font(.title2.bold())
                .contentTransition(.numericText())
            Spacer()
            Button("Next month", systemImage: "chevron.right") { move(by: 1) }
                .labelStyle(.iconOnly)
                .disabled(!canGoForward)
        }
        .font(.title3)
    }

    private var weekdayHeader: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        return HStack(spacing: 6) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var grid: some View {
        let summary = summary
        return VStack(spacing: 6) {
            ForEach(Array(summary.weeks(calendar: calendar).enumerated()), id: \.offset) { _, week in
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { index in
                        if let day = week[index] {
                            let info = summary.days[day]
                            if info != nil {
                                NavigationLink(value: day) {
                                    DayCell(day: day, info: info, isToday: day == .today, colorScheme: colorScheme)
                                }
                                .buttonStyle(.plain)
                            } else {
                                DayCell(day: day, info: nil, isToday: day == .today, colorScheme: colorScheme)
                            }
                        } else {
                            Color.clear.aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
        }
    }
}

private struct DayCell: View {
    let day: DayDate
    let info: MonthSummary.Day?
    let isToday: Bool
    let colorScheme: ColorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        let step = info?.averageMood.map(MoodScale.step(for:))
        let textColor = step.map { MoodScale.textColor(step: $0, scheme: colorScheme) } ?? .primary

        ZStack {
            if let step {
                shape.fill(MoodScale.color(step: step))
            } else if info != nil {
                shape.strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            } else {
                shape.strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            }
            VStack(spacing: 3) {
                Text("\(day.day)")
                    .font(.callout.weight(isToday ? .bold : .regular))
                    .monospacedDigit()
                if let count = info?.entryCount, count > 1 {
                    HStack(spacing: 2) {
                        ForEach(0..<min(count, 4), id: \.self) { _ in Circle().frame(width: 4, height: 4) }
                    }
                }
            }
            .foregroundStyle(info == nil ? Color.secondary : textColor)
            if isToday {
                shape.strokeBorder(Color.primary, lineWidth: 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let date = day.date().formatted(.dateTime.day().month(.wide))
        guard let info else { return "\(date), no entries" }
        let count = info.entryCount == 1 ? "1 entry" : "\(info.entryCount) entries"
        let mood = info.averageMood.map { "mood \(MoodScale.describe($0))" } ?? "mood not scored yet"
        return "\(date), \(count), \(mood)"
    }
}

/// The entries written on one day, from tapping it in the calendar.
private struct DayEntriesView: View {
    let store: EntryStore
    let day: DayDate

    @State private var entries: [Entry] = []

    var body: some View {
        List(entries) { entry in
            NavigationLink(value: EditorRoute(entry: entry, isNew: false)) {
                EntryRow(entry: entry)
            }
        }
        .navigationTitle(day.date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                for try await all in store.observeEntries() {
                    entries = all.filter { $0.entryDate == day }
                }
            } catch {}
        }
    }
}
