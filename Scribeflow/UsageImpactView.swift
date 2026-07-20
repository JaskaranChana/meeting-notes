import Charts
import SwiftUI

enum UsageImpactPeriod: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .allTime: "All time"
        }
    }
}

struct UsageImpactDay: Identifiable, Hashable, Sendable {
    var id: Date { date }
    let date: Date
    let captures: Int
    let closedLoops: Int
}

struct UsageImpactSnapshot: Hashable, Sendable {
    var captures = 0
    var capturedMinutes = 0
    var closedLoops = 0
    var openLoops = 0
    var skippedLoops = 0
    var sourceBackedItems = 0
    var activeDays = 0
    var captureDelta: Int?
    var closedLoopDelta: Int?
    var days: [UsageImpactDay] = []

    var followThroughRate: Double? {
        let total = closedLoops + openLoops
        guard total > 0 else { return nil }
        return Double(closedLoops) / Double(total)
    }

    var followThroughLabel: String {
        guard let followThroughRate else { return "No data" }
        return followThroughRate.formatted(.percent.precision(.fractionLength(0)))
    }
}

actor UsageImpactBuilder {
    func make(
        meetings: [Meeting],
        period: UsageImpactPeriod,
        referenceDate: Date = .now
    ) -> UsageImpactSnapshot {
        let calendar = Calendar.current
        let interval = dateInterval(for: period, meetings: meetings, referenceDate: referenceDate, calendar: calendar)
        let scoped = meetings.filter { interval.contains($0.when) }
        let previous = previousMeetings(
            for: period,
            meetings: meetings,
            interval: interval,
            calendar: calendar
        )

        let currentCommitments = scoped
            .filter(\.allowsAccountabilityExtraction)
            .flatMap(\.commitments)
        let previousCommitments = previous
            .filter(\.allowsAccountabilityExtraction)
            .flatMap(\.commitments)

        let closed = currentCommitments.filter { $0.status == .fulfilled }.count
        let open = currentCommitments.filter { $0.status == .open || $0.status == .atRisk }.count
        let skipped = currentCommitments.filter { $0.status == .superseded }.count
        let previousClosed = previousCommitments.filter { $0.status == .fulfilled }.count

        let activeDaySet = Set(scoped.map { calendar.startOfDay(for: $0.when) })
        let sourceBacked = scoped.reduce(0) { total, meeting in
            let evidence = meeting.evidenceItems.filter { !$0.sourceReferences.isEmpty }.count
            let commitments = meeting.commitments.filter { !$0.sourceReferences.isEmpty }.count
            return total + evidence + commitments
        }

        return UsageImpactSnapshot(
            captures: scoped.count,
            capturedMinutes: scoped.reduce(0) { $0 + max($1.durationMinutes, 0) },
            closedLoops: closed,
            openLoops: open,
            skippedLoops: skipped,
            sourceBackedItems: sourceBacked,
            activeDays: activeDaySet.count,
            captureDelta: period == .allTime ? nil : scoped.count - previous.count,
            closedLoopDelta: period == .allTime ? nil : closed - previousClosed,
            days: chartDays(
                meetings: scoped,
                period: period,
                referenceDate: referenceDate,
                calendar: calendar
            )
        )
    }

    private func dateInterval(
        for period: UsageImpactPeriod,
        meetings: [Meeting],
        referenceDate: Date,
        calendar: Calendar
    ) -> DateInterval {
        switch period {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: referenceDate)
                ?? DateInterval(start: calendar.startOfDay(for: referenceDate), duration: 7 * 86_400)
        case .month:
            return calendar.dateInterval(of: .month, for: referenceDate)
                ?? DateInterval(start: calendar.startOfDay(for: referenceDate), duration: 31 * 86_400)
        case .allTime:
            let earliest = meetings.map(\.when).min() ?? referenceDate
            let start = calendar.startOfDay(for: earliest)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate)) ?? referenceDate
            return DateInterval(start: start, end: end)
        }
    }

    private func previousMeetings(
        for period: UsageImpactPeriod,
        meetings: [Meeting],
        interval: DateInterval,
        calendar: Calendar
    ) -> [Meeting] {
        let component: Calendar.Component
        switch period {
        case .week: component = .weekOfYear
        case .month: component = .month
        case .allTime: return []
        }
        guard let previousAnchor = calendar.date(byAdding: component, value: -1, to: interval.start),
              let previousInterval = calendar.dateInterval(of: component, for: previousAnchor)
        else { return [] }
        return meetings.filter { previousInterval.contains($0.when) }
    }

    private func chartDays(
        meetings: [Meeting],
        period: UsageImpactPeriod,
        referenceDate: Date,
        calendar: Calendar
    ) -> [UsageImpactDay] {
        let requestedDays = period == .week ? 7 : 30
        let today = calendar.startOfDay(for: referenceDate)
        let start = calendar.date(byAdding: .day, value: -(requestedDays - 1), to: today) ?? today
        let meetingsByDay = Dictionary(grouping: meetings) { calendar.startOfDay(for: $0.when) }

        return (0..<requestedDays).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let dayMeetings = meetingsByDay[date] ?? []
            let closed = dayMeetings
                .flatMap(\.commitments)
                .filter { $0.status == .fulfilled }
                .count
            return UsageImpactDay(date: date, captures: dayMeetings.count, closedLoops: closed)
        }
    }
}

struct UsageImpactView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var period: UsageImpactPeriod = .month
    @State private var snapshot = UsageImpactSnapshot()
    @State private var builder = UsageImpactBuilder()

    private var snapshotKey: String {
        "\(store.revision)-\(period.rawValue)"
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    impactHeader
                    periodPicker
                    metricGrid
                    activityChart
                    accountabilitySummary
                    privacyNote
                }
                .appScreenContent(top: AppSpacing.lg, bottom: AppSpacing.xl)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle(AppStrings.Screen.impact)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppStrings.Action.done) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task(id: snapshotKey) {
                let meetings = store.meetings
                let result = await builder.make(meetings: meetings, period: period)
                guard !Task.isCancelled else { return }
                snapshot = result
            }
        }
        .modifier(ScribeflowChrome())
    }

    private var impactHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorialEyebrow(text: "On-device outcomes")
            Text("What Scribeflow helped retain")
                .font(.system(.title, design: .serif).weight(.medium))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Calculated from saved notes and commitment states. Nothing is uploaded for this view.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(UsageImpactPeriod.allCases) { period in
                Text(period.title).tag(period)
            }
        }
        .pickerStyle(.segmented)
    }

    private var metricGrid: some View {
        LazyVGrid(
            columns: dynamicTypeSize.isAccessibilitySize
                ? [GridItem(.flexible())]
                : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ImpactMetricCard(
                title: "Captures",
                value: "\(snapshot.captures)",
                detail: deltaLabel(snapshot.captureDelta, noun: "vs prior period"),
                icon: "doc.text.fill",
                tint: AppPalette.accent
            )
            ImpactMetricCard(
                title: "Minutes retained",
                value: "\(snapshot.capturedMinutes)",
                detail: "Across saved meetings",
                icon: "clock.fill",
                tint: AppPalette.gold
            )
            ImpactMetricCard(
                title: "Loops closed",
                value: "\(snapshot.closedLoops)",
                detail: deltaLabel(snapshot.closedLoopDelta, noun: "vs prior period"),
                icon: "checkmark.circle.fill",
                tint: AppPalette.success
            )
            ImpactMetricCard(
                title: "Follow-through",
                value: snapshot.followThroughLabel,
                detail: "Closed vs active loops",
                icon: "arrow.triangle.2.circlepath",
                tint: AppPalette.coral
            )
        }
    }

    private var activityChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                EditorialMeta(text: period == .week ? "7 days" : "30 days")
            }

            Chart(snapshot.days) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Captures", day.captures)
                )
                .foregroundStyle(AppPalette.accent)
                .cornerRadius(2)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: period == .week ? 1 : 7)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Capture activity chart")
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var accountabilitySummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accountability")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppPalette.ink)
            impactLine("Open loops", value: "\(snapshot.openLoops)", tint: AppPalette.coral)
            impactLine("Skipped loops", value: "\(snapshot.skippedLoops)", tint: AppPalette.secondaryInk)
            impactLine("Source-backed items", value: "\(snapshot.sourceBackedItems)", tint: AppPalette.accent)
            impactLine("Active capture days", value: "\(snapshot.activeDays)", tint: AppPalette.gold)
        }
    }

    private var privacyNote: some View {
        Label("Computed locally from the current Scribeflow library.", systemImage: "lock.shield.fill")
            .font(.footnote)
            .foregroundStyle(AppPalette.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func impactLine(_ title: String, value: String, tint: Color) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private func deltaLabel(_ delta: Int?, noun: String) -> String {
        guard let delta else { return "Current library" }
        if delta == 0 { return "No change \(noun)" }
        return "\(delta > 0 ? "+" : "")\(delta) \(noun)"
    }
}

private struct ImpactMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.10), in: Circle())
            Text(value)
                .font(.system(.title2, design: .serif).weight(.medium))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .padding(14)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppPalette.border.opacity(0.55), lineWidth: 0.6))
    }
}
