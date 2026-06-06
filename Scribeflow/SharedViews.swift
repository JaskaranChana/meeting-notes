import SwiftUI

// MARK: - Empty / section components

struct EmptyStateCard: View {
    let title: String
    let subtitle: String
    var systemImage: String? = nil
    var tint: Color = AppPalette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let systemImage {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.10))
                        .frame(width: 56, height: 56)
                    Circle()
                        .strokeBorder(tint.opacity(0.18), lineWidth: 0.8)
                        .frame(width: 56, height: 56)
                    Image(systemName: systemImage)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(tint)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppType.cardTitle())
                    .foregroundStyle(AppPalette.ink)
                Text(subtitle)
                    .font(AppType.caption)
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(AppPalette.cardBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.04), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5)
        )
    }
}

struct SectionHeaderRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(AppPalette.ink)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(AppPalette.tertiaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SurfaceCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2.weight(.medium))
                    .kerning(0.6)
                    .foregroundStyle(AppPalette.tertiaryInk)
                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.secondaryInk)
            }
            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(AppPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.28), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .appShadow(AppShadow.hairline)
    }
}

// MARK: - Status badge

struct StatusBadge: View {
    let status: MeetingStatus

    var body: some View {
        HStack(spacing: 5) {
            if status == .live {
                BreathingDot(tint: dotColor, size: 5)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
            }
            Text(status.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(labelColor)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(bgColor, in: Capsule())
        .animation(AppMotion.smooth, value: status)
    }

    private var dotColor: Color {
        switch status {
        case .live:   return AppPalette.coral
        case .ready:  return AppPalette.accent
        case .shared: return AppPalette.gold
        }
    }

    private var labelColor: Color {
        switch status {
        case .live:   return AppPalette.coral
        case .ready:  return AppPalette.accent
        case .shared: return AppPalette.gold
        }
    }

    private var bgColor: Color {
        switch status {
        case .live:   return AppPalette.coral.opacity(0.10)
        case .ready:  return AppPalette.accent.opacity(0.10)
        case .shared: return AppPalette.gold.opacity(0.10)
        }
    }
}

// MARK: - Label / text styles

struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 10) {
            configuration.icon
                .scaledFont(size: 8, relativeTo: .body)
                .foregroundStyle(AppPalette.accent)
                .padding(.top, 6)
            configuration.title
        }
    }
}

struct QuickNoteTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(AppPalette.paper.opacity(0.78), in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(AppPalette.border.opacity(0.82))
            )
            .foregroundStyle(AppPalette.ink)
    }
}

// MARK: - Activity sheet

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onComplete?(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Motion entrance

struct MotionEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let step: Int
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (active ? 0 : 12))
            .scaleEffect(reduceMotion ? 1 : (active ? 1 : 0.97))
            .animation(reduceMotion ? nil : animation, value: active)
    }

    private var animation: Animation {
        AppMotion.entrance.delay(Double(step) * AppMotion.entranceStagger)
    }
}

extension View {
    func motionEntrance(step: Int, active: Bool) -> some View {
        modifier(MotionEntranceModifier(step: step, active: active))
    }
}

// MARK: - Card appear glow

struct CardAppearGlow: ViewModifier {
    var tint: Color = AppPalette.accent
    @State private var glowing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .strokeBorder(tint.opacity(glowing ? 0 : 0.35), lineWidth: 1.2)
                    .allowsHitTesting(false)
            )
            .onAppear {
                guard !reduceMotion else { return }
                glowing = false
                withAnimation(.easeOut(duration: 1.2).delay(0.2)) { glowing = true }
            }
    }
}

extension View {
    func cardAppearGlow(tint: Color = AppPalette.accent) -> some View {
        modifier(CardAppearGlow(tint: tint))
    }
}

// MARK: - Success pop

struct SuccessPopModifier: ViewModifier {
    @Binding var trigger: Bool
    @State private var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: trigger) { _, fired in
                guard fired, !reduceMotion else { return }
                withAnimation(AppMotion.bounce) { scale = 1.2 }
                withAnimation(AppMotion.snappy.delay(0.15)) { scale = 1 }
            }
    }
}

extension View {
    func successPop(trigger: Binding<Bool>) -> some View {
        modifier(SuccessPopModifier(trigger: trigger))
    }
}

// MARK: - Slide transition for tab content

struct SlideTransitionModifier: ViewModifier {
    let id: AnyHashable

    func body(content: Content) -> some View {
        content
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.98)),
                removal: .opacity.animation(.easeOut(duration: 0.12))
            ))
            .animation(AppMotion.smooth, value: id)
    }
}

// MARK: - Editorial kit
//
// Shared primitives for the content-first "editorial workspace" direction:
// monospaced eyebrows, serif titles, deterministic avatars + stacks, pill
// chips, and hairline rules. Used across Today, Library, Meeting detail and
// Capture so the whole app speaks one typographic language.

/// Small uppercase monospaced label sitting above titles / metadata.
struct EditorialEyebrow: View {
    let text: String
    var tint: Color = AppPalette.secondaryInk

    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .kerning(0.9)
            .foregroundStyle(tint)
    }
}

/// Monospaced metadata line (durations, counts, timestamps). Tighter and
/// fainter than `EditorialEyebrow`.
struct EditorialMeta: View {
    let text: String
    var tint: Color = AppPalette.tertiaryInk

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .kerning(0.5)
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// Round avatar with deterministic brand-tinted background + initials.
struct EditorialAvatar: View {
    let name: String
    var size: CGFloat = 26

    private static let palette: [Color] = [
        AppPalette.accent,
        Color(red: 0.722, green: 0.361, blue: 0.180),  // burnt orange
        Color(red: 0.290, green: 0.478, blue: 0.243),  // green
        Color(red: 0.478, green: 0.243, blue: 0.416),  // plum
        Color(red: 0.243, green: 0.329, blue: 0.478),  // indigo
        Color(red: 0.478, green: 0.416, blue: 0.243)   // ochre
    ]

    private var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " })
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    private var fill: Color {
        guard let first = name.unicodeScalars.first else { return AppPalette.accent }
        return Self.palette[Int(first.value) % Self.palette.count]
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(fill, in: Circle())
    }
}

/// Overlapping avatar row with a "+N" overflow chip. Borders use the paper
/// surface so the stack reads cleanly over any background.
struct EditorialAvatarStack: View {
    let names: [String]
    var size: CGFloat = 24
    var max: Int = 4
    var borderColor: Color = AppPalette.paper

    var body: some View {
        let shown = Array(names.prefix(max))
        let overflow = names.count - shown.count
        HStack(spacing: -size * 0.34) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, name in
                EditorialAvatar(name: name, size: size)
                    .overlay(Circle().strokeBorder(borderColor, lineWidth: 2))
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: size * 0.40, weight: .semibold))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .frame(width: size, height: size)
                    .background(AppPalette.softSurface, in: Circle())
                    .overlay(Circle().strokeBorder(borderColor, lineWidth: 2))
            }
        }
    }
}

/// Pill chip used for filters, tags, and inline actions.
struct EditorialChip: View {
    enum Variant { case neutral, accent, warn, good, outline, ink }
    let text: String
    var systemImage: String? = nil
    var variant: Variant = .neutral
    var trailingCount: Int? = nil

    private var fg: Color {
        switch variant {
        case .neutral:  AppPalette.secondaryInk
        case .accent:   AppPalette.accent
        case .warn:     AppPalette.coral
        case .good:     AppPalette.success
        case .outline:  AppPalette.secondaryInk
        case .ink:      AppPalette.cardBackground
        }
    }
    private var bg: Color {
        switch variant {
        case .neutral:  AppPalette.softSurface
        case .accent:   AppPalette.accentSoft
        case .warn:     AppPalette.coral.opacity(0.16)
        case .good:     AppPalette.success.opacity(0.16)
        case .outline:  .clear
        case .ink:      AppPalette.ink
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
            if let trailingCount {
                Text("\(trailingCount)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(fg.opacity(0.55))
            }
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(bg, in: Capsule())
        .overlay {
            if variant == .outline {
                Capsule().strokeBorder(AppPalette.border, lineWidth: 1)
            }
        }
    }
}

/// One-pixel hairline rule matching the editorial divider weight.
struct EditorialRule: View {
    var inset: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(AppPalette.border.opacity(0.7))
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// Section header: serif title on the left, monospaced meta on the right.
struct EditorialSectionHead<Trailing: View>: View {
    let title: String
    var titleSize: CGFloat = 22
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: titleSize, weight: .medium, design: .serif))
                .foregroundStyle(AppPalette.ink)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension EditorialSectionHead where Trailing == EmptyView {
    init(title: String, titleSize: CGFloat = 22) {
        self.title = title
        self.titleSize = titleSize
        self.trailing = EmptyView()
    }
}

/// Tactile press feedback for flat editorial list rows. On press the row gets a
/// soft inset highlight and a barely-there scale — so a tap reads as physical
/// without the heaviness of a card. Use on `NavigationLink`/`Button` rows that
/// otherwise sit flat on the page.
struct EditorialRowStyle: ButtonStyle {
    var inset: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, inset)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(AppPalette.highlight.opacity(configuration.isPressed ? 0.7 : 0))
            )
            .padding(.horizontal, -inset)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(AppMotion.press, value: configuration.isPressed)
    }
}

/// Continuous scroll-reveal: rows soften + lift slightly as they leave the
/// viewport, snapping crisp at rest. Adds depth to long lists without the
/// janky "everything animates on first paint" feel. Respects Reduce Motion.
private struct EditorialRevealModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition(.interactive(timingCurve: .easeOut)) { view, phase in
                view
                    .opacity(phase.isIdentity ? 1 : 0.4)
                    .scaleEffect(phase.isIdentity ? 1 : 0.97, anchor: .center)
                    .offset(y: phase.isIdentity ? 0 : (phase.value < 0 ? -6 : 10))
            }
        }
    }
}

extension View {
    /// Apply the editorial scroll-reveal to a list row.
    func editorialReveal() -> some View { modifier(EditorialRevealModifier()) }
}

/// A number that tweens through its integer values when `value` is animated.
/// Conforms to `Animatable` so `withAnimation` interpolates `animatableData`
/// and re-renders `body` each frame — giving a count-up roll on appear.
struct CountUpNumber: View, Animatable {
    var value: Double
    var font: Font
    var color: Color

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
    }
}

// MARK: - Shareable meeting digest

/// Best-effort one-line synopsis from a meeting's summary (or raw notes).
func meetingSynopsis(for meeting: Meeting, summary: MeetingSummary) -> String {
    // The model judged the input to be nonsense — say so, don't fake meaning.
    if let brief = meeting.aiBrief, !brief.makesSense {
        return "This does not make sense. Please clarify."
    }
    // The model's own one-line summary wins when it processed this meeting.
    if let aiSummary = meeting.aiBrief?.summary,
       !aiSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return aiSummary
    }
    // Prefer a real objective the user set, then genuinely extracted highlights
    // (skipping placeholder prompts), then the user's own first line — never the
    // templated "This meeting is centered on…" / "Summary of…" title.
    let objective = meeting.objective.trimmingCharacters(in: .whitespacesAndNewlines)
    if !objective.isEmpty { return objective }
    let bullets = summary.sections.flatMap(\.bullets)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !isPlaceholderSummaryBullet($0) }
    if !bullets.isEmpty { return bullets.prefix(2).joined(separator: " · ") }
    let firstLine = meeting.rawNotes
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•\t")) }
        .first(where: { !$0.isEmpty && $0 != "Add your key takeaways here" })
    if let firstLine { return firstLine }
    return "Captured. Ready to review."
}

/// Placeholder summary prompts shown when nothing could be extracted — never use
/// these as a synopsis.
func isPlaceholderSummaryBullet(_ bullet: String) -> Bool {
    let starts = ["Add a few bullets", "Add your", "Clarify the next", "Capture more",
                  "Document the next", "Name the one", "The meeting capture is", "Capture at least"]
    return starts.contains { bullet.hasPrefix($0) }
}

/// Markdown digest used by the Detail "Share digest" menu and the Library
/// row context menu. Stays compact: title + meta, synopsis, decisions,
/// actions (with checkbox state + owner + due), risks, people.
func meetingDigestMarkdown(_ m: Meeting, signals: MeetingSignals) -> String {
    let synopsis = meetingSynopsis(for: m, summary: m.summary(for: m.selectedTemplate))
    let date = m.when.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    let durationStr = m.durationMinutes > 0 ? " · \(m.durationMinutes)m" : ""

    var lines: [String] = []
    lines.append("# \(m.title.isEmpty ? "Untitled meeting" : m.title)")
    lines.append("_\(date) · \(m.workspace)\(durationStr)_")
    lines.append("")
    // --- AI summary: what Scribeflow extracted ---
    lines.append("## Summary")
    lines.append("_Auto-summarized by Scribeflow._")
    lines.append("")
    lines.append(synopsis)

    if !signals.decisions.isEmpty {
        lines.append("")
        lines.append("## Decisions")
        for d in signals.decisions { lines.append("- \(d)") }
    }

    let openCs = m.commitments.filter { $0.status == .open || $0.status == .atRisk }
    let doneCs = m.commitments.filter { $0.status == .fulfilled || $0.status == .superseded }
    // Commitments and signal actions are the same extractor — only fall back to
    // signal actions when there are no commitments, so nothing is listed twice.
    let signalActions = (openCs.isEmpty && doneCs.isEmpty) ? signals.actions : []
    if !openCs.isEmpty || !doneCs.isEmpty || !signalActions.isEmpty {
        lines.append("")
        lines.append("## Actions")
        for c in openCs {
            var parts = ["- [ ] \(c.statement)"]
            if c.owner != "Owner not named" { parts.append("(\(c.owner))") }
            if let due = c.dueHint { parts.append("— due \(due)") }
            if c.priority?.lowercased() == "high" { parts.append("— high priority") }
            lines.append(parts.joined(separator: " "))
            if let why = c.rationale, !why.isEmpty { lines.append("  why: \(why)") }
        }
        for c in doneCs { lines.append("- [x] \(c.statement)") }
        for text in signalActions { lines.append("- [ ] \(text)") }
    }

    if !signals.questions.isEmpty {
        lines.append("")
        lines.append("## Open questions")
        for q in signals.questions { lines.append("- \(q)") }
    }

    if !signals.risks.isEmpty {
        lines.append("")
        lines.append("## Risks")
        for r in signals.risks { lines.append("- \(r)") }
    }

    // Meeting-type-specific sections the model chose (standup Done/Blocked, …).
    for section in m.aiBrief?.sections ?? [] where !section.items.isEmpty {
        lines.append("")
        lines.append("## \(section.heading)")
        for item in section.items { lines.append("- \(item)") }
    }

    // Points flagged unclear — surfaced, never guessed.
    let clarifications = m.aiBrief?.needsClarification ?? []
    if !clarifications.isEmpty {
        lines.append("")
        lines.append("## Needs clarification")
        for c in clarifications { lines.append("- \(c)") }
    }

    // --- The user's own words, kept separate from the AI summary above ---
    if let enhanced = m.aiBrief?.enhancedNotes, !enhanced.isEmpty {
        lines.append("")
        lines.append("## Your notes")
        lines.append("_Your words, expanded with context._")
        for note in enhanced {
            lines.append("- \(note.anchor)")
            if !note.detail.isEmpty { lines.append("  \(note.detail)") }
        }
    } else {
        let yourNotes = m.rawNotes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•\t")) }
            .filter { !$0.isEmpty && $0 != "Add your key takeaways here" }
        if !yourNotes.isEmpty {
            lines.append("")
            lines.append("## Your notes")
            lines.append("_In your words — captured by you, unedited._")
            for n in yourNotes { lines.append("- \(n)") }
        }
    }

    if !m.attendees.isEmpty {
        lines.append("")
        lines.append("## People")
        lines.append(m.attendees.joined(separator: ", "))
    }

    lines.append("")
    lines.append("—")
    lines.append("Shared from Scribeflow")
    return lines.joined(separator: "\n")
}

// MARK: - Speaker color

private let editorialSpeakerPalette: [Color] = [
    AppPalette.accent,
    Color(red: 0.722, green: 0.361, blue: 0.180),
    Color(red: 0.290, green: 0.478, blue: 0.243),
    Color(red: 0.478, green: 0.243, blue: 0.416),
    Color(red: 0.243, green: 0.329, blue: 0.478),
    Color(red: 0.478, green: 0.416, blue: 0.243)
]

/// Deterministic per-speaker color matching EditorialAvatar's palette. Use on
/// speaker labels so the visual cue is consistent (avatar + label same tint).
func editorialSpeakerColor(for name: String) -> Color {
    guard let first = name.unicodeScalars.first else { return AppPalette.accent }
    return editorialSpeakerPalette[Int(first.value) % editorialSpeakerPalette.count]
}
