import SwiftUI

// MARK: - MeetingSavedSheet
//
// The signature post-capture moment. Replaces the silent dismiss-to-home
// pattern with an emotionally-weighted reveal of what was just captured.
//
// Reveal sequence:
//   t=0     title appears, soft fade up
//   t=180ms first extracted point fades in
//   t=320ms second extracted point fades in
//   t=480ms actions appear
//
// Two outcomes:
//   • Open  → set selectedMeetingID, dismisses; parent navigates to detail
//   • Done  → just dismisses, returns home
//
// Designed to feel like a gift, not a confirmation.

struct MeetingSavedSheet: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let meetingID: Meeting.ID
    let onOpen: () -> Void

    @State private var revealedSteps: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let burstParticles: [(size: CGFloat, x: CGFloat, y: CGFloat, color: Color)] = [
        (6, -82, -48, AppPalette.accent),
        (5, -46, 22, AppPalette.gold),
        (7, -12, -30, AppPalette.success),
        (5, 28, 30, AppPalette.coral),
        (6, 58, -18, AppPalette.accent),
        (4, 86, 12, AppPalette.gold)
    ]

    private var meeting: Meeting? { store.meeting(withID: meetingID) }
    private var signals: MeetingSignals? {
        guard let meeting else { return nil }
        return store.signals(for: meeting)
    }

    /// Two highlights chosen carefully: the first decision (proof "we got
    /// the gist") and the first action (proof "we know what's next").
    /// Falls back to risks or the meeting's first summary bullet so the
    /// reveal always has something concrete to show.
    private var highlights: [Highlight] {
        guard let meeting, let s = signals else { return [] }
        var items: [Highlight] = []
        if let decision = s.decisions.first {
            items.append(Highlight(label: "Decision", text: decision))
        }
        if let action = s.actions.first {
            items.append(Highlight(label: "Action", text: action))
        }
        if items.isEmpty, let risk = s.risks.first {
            items.append(Highlight(label: "Risk", text: risk))
        }
        if items.isEmpty {
            let summary = meeting.summary(for: meeting.selectedTemplate)
            if let bullet = summary.sections.first?.bullets.first {
                items.append(Highlight(label: "Captured", text: bullet))
            }
        }
        return Array(items.prefix(2))
    }

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            confettiBurst
                .allowsHitTesting(false)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("SAVED")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AppPalette.tertiaryInk)
                            .opacity(revealedSteps >= 1 ? 1 : 0)
                            .offset(y: revealedSteps >= 1 ? 0 : 10)

                        Text(meeting?.title ?? "Meeting")
                            .font(.system(.largeTitle, design: .serif).weight(.semibold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .opacity(revealedSteps >= 1 ? 1 : 0)
                            .offset(y: revealedSteps >= 1 ? 0 : 14)

                        if let meeting {
                            Text("\(meeting.workspace) · \(meeting.durationMinutes) min")
                                .font(.subheadline)
                                .foregroundStyle(AppPalette.secondaryInk)
                                .opacity(revealedSteps >= 1 ? 1 : 0)
                        }
                    }

                    if highlights.isEmpty {
                        placeholderRow
                            .opacity(revealedSteps >= 2 ? 1 : 0)
                    } else {
                        VStack(alignment: .leading, spacing: AppSpacing.lg) {
                            ForEach(Array(highlights.enumerated()), id: \.offset) { idx, h in
                                highlightRow(h)
                                    .opacity(revealedSteps >= idx + 2 ? 1 : 0)
                                    .offset(y: revealedSteps >= idx + 2 ? 0 : 8)
                            }
                        }
                    }
                }
                .appScreenContent(top: AppSpacing.xl, bottom: AppSpacing.lg)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionRow
                .padding(.horizontal, AppLayout.screenHorizontalPadding)
                .padding(.vertical, AppSpacing.sm)
                .background(.ultraThinMaterial)
                .opacity(revealedSteps >= 4 ? 1 : 0)
                .offset(y: revealedSteps >= 4 ? 0 : 12)
        }
        .task { await runReveal() }
    }

    // MARK: - Reveal sequence

    private func runReveal() async {
        // Signature haptic on open — single, soft success notification.
        HapticEngine.notify(.success)
        if reduceMotion {
            revealedSteps = 4
            return
        }

        // Step 1 — title block
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
            revealedSteps = 1
        }

        // Step 2 — first highlight
        try? await Task.sleep(for: .milliseconds(180))
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            revealedSteps = 2
        }

        // Step 3 — second highlight
        try? await Task.sleep(for: .milliseconds(140))
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            revealedSteps = 3
        }

        // Step 4 — actions
        try? await Task.sleep(for: .milliseconds(160))
        withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) {
            revealedSteps = 4
        }
    }

    // MARK: - Subviews

    private func highlightRow(_ h: Highlight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(h.label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(highlightColor(for: h.label))

            Text(h.text)
                .font(.title3)
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var placeholderRow: some View {
        Text("Your note is ready in Library.")
            .font(.title3)
            .foregroundStyle(AppPalette.secondaryInk)
    }

    private func highlightColor(for label: String) -> Color {
        switch label {
        case "Decision": return AppPalette.accent
        case "Action":   return AppPalette.gold
        case "Risk":     return AppPalette.coral
        default:         return AppPalette.secondaryInk
        }
    }

    private var actionRow: some View {
        AdaptiveActionStack(spacing: AppSpacing.sm) {
            Button {
                HapticEngine.tap(.light)
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppPalette.softSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.97))

            Button {
                HapticEngine.tap(.medium)
                onOpen()
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Text("Open")
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.bold))
                }
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(AppPalette.inkButton, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.97))
        }
        .readingWidth()
    }

    private var confettiBurst: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.3)
            ForEach(Array(Self.burstParticles.enumerated()), id: \.offset) { index, particle in
                Circle()
                    .fill(particle.color)
                    .frame(width: particle.size, height: particle.size)
                    .position(center)
                    .offset(
                        x: revealedSteps >= 1 ? particle.x : 0,
                        y: revealedSteps >= 1 ? particle.y : 0
                    )
                    .opacity(revealedSteps >= 1 ? 0 : 1)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 1.2).delay(Double(index) * 0.04),
                        value: revealedSteps
                    )
            }
        }
    }

    private struct Highlight {
        let label: String
        let text: String
    }
}
