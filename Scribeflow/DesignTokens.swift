import SwiftUI

// MARK: - Radius

enum AppRadius {
    /// 6pt — chips, micro badges, tiny indicators.
    static let xs: CGFloat = 6
    /// 10pt — small icon containers, segmented controls.
    static let sm: CGFloat = 10
    /// 14pt — inputs, compact cards, list rows.
    static let md: CGFloat = 14
    /// 20pt — primary cards, surfaces, modals.
    static let lg: CGFloat = 20
    /// 28pt — generous cards, hero strips.
    static let xl: CGFloat = 28
    /// 36pt — full-bleed hero surfaces, marquee cards.
    static let xxl: CGFloat = 36
}

// MARK: - Spacing

enum AppSpacing {
    /// 4pt — hairline gap.
    static let xxs: CGFloat = 4
    /// 8pt — adjacent labels, icon-to-text.
    static let xs: CGFloat = 8
    /// 12pt — tight stacks, dense rows.
    static let sm: CGFloat = 12
    /// 16pt — default content padding.
    static let md: CGFloat = 16
    /// 20pt — comfortable margins, screen edges.
    static let lg: CGFloat = 20
    /// 24pt — section gaps inside a screen.
    static let xl: CGFloat = 24
    /// 32pt — major breaks between sections.
    static let xxl: CGFloat = 32
}

// MARK: - Motion

enum AppMotion {
    /// Snappy — taps, tab bar, button press. ~280ms, well damped.
    static let snappy: Animation = .spring(response: 0.28, dampingFraction: 0.86)
    /// Smooth — toasts, sheets, modal transitions. ~380ms, gentle.
    static let smooth: Animation = .spring(response: 0.38, dampingFraction: 0.84)
    /// Short first-frame fade for lightweight screen chrome.
    static let entrance: Animation = .easeOut(duration: 0.24)
    /// Press — button label compress on tap. Tighter than `snappy`.
    static let press: Animation = .spring(response: 0.24, dampingFraction: 0.82)
    /// Linear opacity fade — privacy curtain, splash dismiss.
    static let fade: Animation = .easeOut(duration: 0.20)
    /// Slow ease — long crossfades, scrubber bars.
    static let crossfade: Animation = .easeInOut(duration: 0.32)
    /// Repeating pulse — live recording dots, attention indicators.
    static let pulse: Animation = .easeInOut(duration: 0.9).repeatForever(autoreverses: true)

    /// Small stagger for the first few pieces of screen chrome.
    static let entranceStagger: Double = 0.035

    /// Interactive bounce — used for selected tab pop, mic tap.
    static let bounce: Animation = .spring(response: 0.30, dampingFraction: 0.62)

    /// Hero parallax — slow, glassy. Used on background blobs and ambient glow.
    static let drift: Animation = .easeInOut(duration: 7.5).repeatForever(autoreverses: true)

    /// Wave breathing — for live recording bars and breathing dots.
    static let breathe: Animation = .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
}

// MARK: - Type scale

/// Dynamic-Type-aware font helpers. Prefer these over `.system(size:)` so the
/// app respects user font size preferences.
enum AppFont {
    /// Numeric / monospaced digits at a semantic size (for timers, counters).
    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }

    /// Serif headline — used for hero titles to match the brand mark.
    static func serif(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .serif).weight(weight)
    }
}

/// A fixed point size that scales with Dynamic Type relative to a chosen text style.
/// Use as `.scaledFont(size: 58, weight: .bold, design: .rounded, relativeTo: .largeTitle)`.
private struct ScaledFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// Apply a fixed-point font that still scales with Dynamic Type.
    /// Prefer semantic styles (`.body`, `.title`, etc.) when possible —
    /// reach for this when a specific visual size matters (hero counters,
    /// brand display type) but the text should still grow with user settings.
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo style: Font.TextStyle = .body
    ) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design, relativeTo: style))
    }
}

// MARK: - Shadow

/// Layered shadow tokens. Apply via `.shadow(...)`.
enum AppShadow {
    /// Hairline lift — list rows, chip elevation.
    static let hairline = Shadow(color: Color(red: 0.35, green: 0.33, blue: 0.28).opacity(0.06), radius: 4, y: 2)
    /// Subtle lift — soft cards.
    static let soft = Shadow(color: Color(red: 0.35, green: 0.33, blue: 0.28).opacity(0.08), radius: 8, y: 3)
    /// Standard card — default elevation.
    static let card = Shadow(color: Color(red: 0.35, green: 0.33, blue: 0.28).opacity(0.09), radius: 14, y: 6)
    /// Floating — tab dock, FAB, sheets.
    static let floating = Shadow(color: Color(red: 0.30, green: 0.28, blue: 0.24).opacity(0.14), radius: 22, y: 10)
    /// Hero — accent surfaces with deeper drop.
    static let hero = Shadow(color: Color(red: 0.30, green: 0.28, blue: 0.24).opacity(0.16), radius: 32, y: 16)
    /// Ambient — large diffused halo for hero blobs / glow.
    static let ambient = Shadow(color: Color(red: 0.35, green: 0.33, blue: 0.28).opacity(0.07), radius: 44, y: 20)

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let y: CGFloat
    }
}

extension View {
    func appShadow(_ token: AppShadow.Shadow) -> some View {
        shadow(color: token.color, radius: token.radius, y: token.y)
    }
}

// MARK: - Reduce-Transparency-aware material

/// Applies a blur material normally, but falls back to a solid surface when the
/// user enables "Reduce Transparency" — blur reads as muddy/illegible for those
/// users, so we honor the setting.
private struct AdaptiveMaterialBackground<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let material: Material
    let solid: Color
    let shape: S

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(solid, in: shape)
        } else {
            content.background(material, in: shape)
        }
    }
}

extension View {
    /// Reduce-Transparency-aware background. Pass the solid fallback that best
    /// matches the surface (`dockBackground` for chrome, `paper` for sheets).
    func adaptiveMaterial<S: Shape>(
        _ material: Material = .ultraThinMaterial,
        solid: Color = AppPalette.cardBackground,
        in shape: S = Rectangle()
    ) -> some View {
        modifier(AdaptiveMaterialBackground(material: material, solid: solid, shape: shape))
    }
}

// MARK: - Reusable launch surfaces

struct PressScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.98
    var opacity: Double = 0.92
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(isEnabled ? (configuration.isPressed ? opacity : 1) : 0.46)
            .animation(reduceMotion ? nil : AppMotion.press, value: configuration.isPressed)
    }
}

struct PremiumPanel<Content: View>: View {
    var cornerRadius: CGFloat = AppRadius.xl
    var contentPadding: CGFloat = AppSpacing.lg
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            content
        }
        .padding(contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppPalette.cardBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppPalette.highlight.opacity(0.10),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(AppPalette.border.opacity(0.35), lineWidth: 0.6)
        )
        .appShadow(AppShadow.soft)
    }
}

struct LaunchActionLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = AppPalette.accent
    var isPrimary = false

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: systemImage)
                .font(.title3.weight(.bold))
                .foregroundStyle(isPrimary ? .white : tint)
                .frame(width: 46, height: 46)
                .background(isPrimary ? tint : tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(isPrimary ? .white : AppPalette.ink)
                Text(subtitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isPrimary ? .white.opacity(0.72) : AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppSpacing.xs)

            Image(systemName: "arrow.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(isPrimary ? .white.opacity(0.72) : tint)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isPrimary ? AnyShapeStyle(AppPalette.heroGradient) : AnyShapeStyle(AppPalette.softSurface.opacity(0.72)),
            in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(isPrimary ? .white.opacity(0.18) : AppPalette.border.opacity(0.65), lineWidth: 0.8)
        )
    }
}

struct ProductMetric: View {
    let value: String
    let label: String
    var tint: Color = AppPalette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(AppPalette.ink)
                .contentTransition(.numericText())
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppPalette.secondaryInk.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 0.8)
        )
    }
}

struct WorkflowRailStep: View {
    let index: Int
    let title: String
    let detail: String
    let systemImage: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(String(format: "%02d", index))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 24, alignment: .leading)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.system(size: 17, weight: .medium, design: .serif))
                        .foregroundStyle(AppPalette.ink)
                }
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Reading width
//
// iPad has 1024–1366pt of width to spend. Stretching list rows + cards to
// that width hurts readability and looks amateur. Pin the primary content
// column to a comfortable max so the experience feels intentional on both
// form factors. Use as `.frame(maxWidth: AppLayout.contentMaxWidth)`.
enum AppLayout {
    /// Max width for primary scroll content. Tuned for ~80 chars at body
    /// size — the long-read sweet spot.
    static let contentMaxWidth: CGFloat = 720
    /// Consistent readable gutter for every full-screen flow.
    static let screenHorizontalPadding: CGFloat = 20
    /// Minimum interactive footprint from the iOS Human Interface Guidelines.
    static let minimumTapTarget: CGFloat = 44
    /// Bottom breathing room for sheets without persistent bottom controls.
    static let sheetBottomPadding: CGFloat = 32
}

/// Caps a stack of content to `AppLayout.contentMaxWidth` and centers it.
/// Use on the inner stack of a `ScrollView` so iPad gets nice gutters.
extension View {
    func readingWidth() -> some View {
        frame(maxWidth: AppLayout.contentMaxWidth, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Gives compact icon and chip controls a reliable 44-point hit region
    /// without forcing their visible background to grow.
    func appTapTarget(_ size: CGFloat = AppLayout.minimumTapTarget) -> some View {
        frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
    }

    /// Standard page treatment for content hosted by a vertical ScrollView.
    func appScreenContent(
        top: CGFloat = AppSpacing.md,
        bottom: CGFloat = AppLayout.sheetBottomPadding
    ) -> some View {
        padding(.horizontal, AppLayout.screenHorizontalPadding)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .readingWidth()
    }
}

// MARK: - Canonical icon vocabulary
//
// Single source of truth for SF Symbol names mapped to concepts. Use these
// constants instead of hardcoded `Image(systemName: "...")` strings so the
// app speaks one visual language: "decision" always looks like a seal,
// "action" always looks like an arrow, etc.

enum AppSymbols {
    // Meeting outcomes
    static let decision = "checkmark.seal.fill"
    static let action   = "arrow.right.circle.fill"
    static let risk     = "exclamationmark.triangle.fill"
    static let summary  = "sparkles"
    static let score    = "chart.bar.fill"
    static let prep     = "doc.text.magnifyingglass"

    // Capture surfaces
    static let mic          = "waveform.badge.mic"
    static let waveform     = "waveform"
    static let transcript   = "text.alignleft"
    static let note         = "square.and.pencil"
    static let voice        = "mic.fill"
    static let importAudio  = "square.and.arrow.down"
    static let ask          = "sparkle.magnifyingglass"

    // People + meta
    static let people    = "person.2.fill"
    static let person    = "person.fill"
    static let calendar  = "calendar"
    static let clock     = "clock.fill"
    static let workspace = "briefcase"
    static let pin       = "pin.fill"
    static let unpin     = "pin.slash"

    // States
    static let openCircle      = "circle"
    static let doneCircle      = "checkmark.circle.fill"
    static let live            = "record.circle.fill"
    static let chevron         = "chevron.right"
    static let share           = "square.and.arrow.up"
    static let info            = "info.circle.fill"
    static let close           = "xmark"
    static let success         = "checkmark.seal.fill"
    static let warning         = "exclamationmark.triangle.fill"
}

// MARK: - Semantic type scale
//
// Use these instead of one-off `.font(...)` calls to keep typography coherent.
// All semantic styles respect Dynamic Type. Reach for `AppType.display(...)`
// when a specific visual size matters (hero counters, marquee headers).

enum AppType {
    /// Marquee display — hero card titles, big-moment numbers.
    static func display(_ weight: Font.Weight = .bold) -> Font {
        .system(.largeTitle, design: .serif).weight(weight)
    }
    /// Hero subtitle / section title — between display and headline.
    static func hero(_ weight: Font.Weight = .bold) -> Font {
        .system(.title, design: .serif).weight(weight)
    }
    /// Section header — used above grouped cards.
    static func section(_ weight: Font.Weight = .bold) -> Font {
        .system(.title2, design: .serif).weight(weight)
    }
    /// Card title — `headline` weight, rounded for warmth.
    static func cardTitle(_ weight: Font.Weight = .bold) -> Font {
        .system(.headline, design: .rounded).weight(weight)
    }
    /// Eyebrow — small uppercase label, kerned, semantic above titles.
    static func eyebrow(_ weight: Font.Weight = .bold) -> Font {
        .caption2.weight(weight)
    }
    /// Body — long-form prose, transcripts.
    static let body: Font = .body
    /// Body emphasized — primary text in cards.
    static func bodyEmph(_ weight: Font.Weight = .semibold) -> Font {
        .body.weight(weight)
    }
    /// Caption — secondary metadata, timestamps.
    static let caption: Font = .footnote
}

// MARK: - IconBadge — premium icon container

/// Standardized icon container used in cards, list rows, action items.
/// Three sizes: `small` (32), `medium` (44), `large` (56).
struct IconBadge: View {
    enum Size { case small, medium, large }
    let systemImage: String
    var tint: Color = AppPalette.accent
    var size: Size = .medium
    var isFilled: Bool = false

    private var dim: CGFloat {
        switch size { case .small: 32; case .medium: 44; case .large: 56 }
    }
    private var iconFont: Font {
        switch size {
        case .small:  return .footnote.weight(.bold)
        case .medium: return .body.weight(.bold)
        case .large:  return .title3.weight(.bold)
        }
    }
    private var radius: CGFloat {
        switch size { case .small: AppRadius.sm; case .medium: AppRadius.md; case .large: AppRadius.lg }
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(iconFont)
            .foregroundStyle(isFilled ? Color.white : tint)
            .frame(width: dim, height: dim)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isFilled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.12)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(tint.opacity(isFilled ? 0.0 : 0.16), lineWidth: 0.8)
            )
    }
}

// MARK: - GlassPanel — translucent layered surface

/// Frosted glass surface for floating chrome, sheets, and ambient overlays.
/// Layers ultra-thin material with a soft tint + hairline border so it reads
/// as a premium surface even over the cream paper background.
struct GlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = AppRadius.xl
    var contentPadding: CGFloat = AppSpacing.lg
    var tint: Color = .white
    var elevation: AppShadow.Shadow = AppShadow.floating
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            content
        }
        .padding(contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(reduceTransparency ? AnyShapeStyle(AppPalette.paper) : AnyShapeStyle(.ultraThinMaterial))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(0.55),
                                    tint.opacity(0.15),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(AppPalette.cardBackground.opacity(0.45), lineWidth: 0.9)
        )
        .appShadow(elevation)
    }
}

// MARK: - PressableCard — interactive surface with press feedback

/// Wraps content in a pressable surface with the standard card chrome.
/// Adds tap haptic + scale press without the user having to wire ButtonStyle.
struct PressableCard<Content: View>: View {
    var cornerRadius: CGFloat = AppRadius.xl
    var contentPadding: CGFloat = AppSpacing.lg
    var background: AnyShapeStyle = AnyShapeStyle(AppPalette.cardBackground)
    var elevation: AppShadow.Shadow = AppShadow.card
    var action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button {
            HapticEngine.tap(.light)
            action()
        } label: {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                content
            }
            .padding(contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [AppPalette.cardBackground.opacity(0.5), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .allowsHitTesting(false)
                    }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppPalette.border.opacity(0.65), lineWidth: 0.8)
            )
            .appShadow(elevation)
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.985, opacity: 0.97))
    }
}

// MARK: - AmbientGlow — soft hero halo

/// Diffused colored halo. Place behind hero content for cinematic depth.
/// Two stops, slow drift animation. Decorative only — `allowsHitTesting`
/// is disabled so it never blocks taps.
struct AmbientGlow: View {
    var tint: Color = AppPalette.accent
    var intensity: Double = 0.45
    var animated: Bool = false
    @State private var driftOn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(intensity), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 220
                    )
                )
                .frame(width: 420, height: 420)
                .blur(radius: 22)
                .offset(x: driftOn ? -40 : 40, y: driftOn ? -28 : 24)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [AppPalette.gold.opacity(intensity * 0.7), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 180
                    )
                )
                .frame(width: 320, height: 320)
                .blur(radius: 20)
                .offset(x: driftOn ? 60 : -50, y: driftOn ? 32 : -18)
        }
        .drawingGroup()
        .allowsHitTesting(false)
        .onAppear {
            guard animated, !reduceMotion else { return }
            withAnimation(AppMotion.drift) { driftOn = true }
        }
    }
}

// MARK: - SectionHeader — refined eyebrow + title + optional trailing action

/// Premium replacement for ad-hoc section labels. Eyebrow above title, optional
/// trailing accessory (button / chip). Keeps section headers visually consistent
/// across the app.
struct SectionHeader<Trailing: View>: View {
    let eyebrow: String?
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: 5) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppPalette.tertiaryInk)
                }
                Text(title)
                    .font(AppType.section(.semibold))
                    .foregroundStyle(AppPalette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(AppType.caption)
                        .foregroundStyle(AppPalette.tertiaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: AppSpacing.sm)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String, subtitle: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = EmptyView()
    }
}

// MARK: - BreathingDot — live indicator

/// Pulsing live-state dot used by recording chrome and "live" badges.
/// Respects Reduce Motion (static dot when reduced).
struct BreathingDot: View {
    var tint: Color = .red
    var size: CGFloat = 8
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.30))
                .frame(width: size * 2.2, height: size * 2.2)
                .scaleEffect(on ? 1.4 : 0.8)
                .opacity(on ? 0 : 1)
            Circle()
                .fill(tint)
                .frame(width: size, height: size)
        }
        .onAppear { startIfActive() }
        .onChange(of: scenePhase) { _, phase in
            // Pause the loop when backgrounded so the forever-repeat doesn't
            // schedule needless renders.
            if phase == .active { startIfActive() } else { on = false }
        }
    }

    private func startIfActive() {
        guard !reduceMotion, scenePhase == .active else { return }
        withAnimation(AppMotion.breathe) { on = true }
    }
}

// MARK: - RootTabBar — liquid app navigation

enum AppDockMetrics {
    static let height: CGFloat = 58
    static let iconSize: CGFloat = 21
    static let itemWidth: CGFloat = 50
    static let centerButtonWidth: CGFloat = 68
    static let centerButtonHeight: CGFloat = 58
    static let centerButtonLift: CGFloat = -6
    static let dockLowerOffset: CGFloat = 9
    static let bottomPadding: CGFloat = 0
    static let horizontalPadding: CGFloat = 18
    static let maxWidth: CGFloat = 360
    static let chromeVerticalPadding: CGFloat = 8
    static let chromeHeight: CGFloat = height + chromeVerticalPadding * 2 + abs(centerButtonLift)
    static let chromeCornerRadius: CGFloat = 30
    static let scrollEndPadding: CGFloat = 14
}

/// Tab item shown in `RootTabBar`. The `id` is the tab's raw value;
/// drive selection by binding to a `String` matching one of these.
struct RootTabBarItem: Identifiable, Equatable {
    let id: String
    let label: String
    let systemImage: String
    var badge: Int = 0
}

/// Floating liquid navigation. It sits in the control layer above content while
/// root screens reserve scroll clearance so bottom controls remain reachable.
struct RootTabBar: View {
    let items: [RootTabBarItem]
    @Binding var selection: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(leftItems) { item in
                tabButton(item)
            }

            if let todayItem {
                todayButton(todayItem)
            }

            ForEach(rightItems) { item in
                tabButton(item)
            }
        }
        .padding(6)
        .frame(height: AppDockMetrics.height)
        .frame(maxWidth: AppDockMetrics.maxWidth)
        .background { liquidBackground }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 10, y: 5)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, AppDockMetrics.horizontalPadding)
        .padding(.bottom, AppDockMetrics.bottomPadding)
        .offset(y: AppDockMetrics.dockLowerOffset)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var todayItem: RootTabBarItem? {
        items.first { $0.id == "home" }
    }

    private var sideItems: [RootTabBarItem] {
        items.filter { $0.id != "home" }
    }

    private var leftItems: [RootTabBarItem] {
        Array(sideItems.prefix(2))
    }

    private var rightItems: [RootTabBarItem] {
        Array(sideItems.dropFirst(2))
    }

    @ViewBuilder
    private var liquidBackground: some View {
        Capsule(style: .continuous)
            .fill(AppPalette.paper.opacity(reduceTransparency ? 1 : 0.94))
            .overlay {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color.white.opacity(0.07), AppPalette.softSurface.opacity(0.18), Color.black.opacity(0.07)]
                                : [Color.white.opacity(0.48), AppPalette.accentSoft.opacity(0.24), AppPalette.softSurface.opacity(0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
    }

    @ViewBuilder
    private func tabButton(_ item: RootTabBarItem) -> some View {
        let isSelected = item.id == selection

        Button {
            // Re-tapping the active tab → broadcast scroll-to-top. Each
            // tab root listens and scrolls its primary list.
            if isSelected {
                NotificationCenter.default.post(
                    name: .scribeflowDockScrollToTop,
                    object: item.id
                )
                return
            }
            selection = item.id
        } label: {
            ZStack {
                tabIcon(item, isSelected: isSelected)
            }
            .foregroundStyle(tabForeground(isSelected: isSelected))
            .frame(width: AppDockMetrics.itemWidth)
            .frame(maxHeight: .infinity)
            .background { selectedPill(isVisible: isSelected) }
            .contentShape(Capsule(style: .continuous))
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
        .accessibilityValue(item.badge > 0 ? "\(item.badge) pending" : "")
        .accessibilityIdentifier("dock.tab.\(item.id)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    @ViewBuilder
    private func todayButton(_ item: RootTabBarItem) -> some View {
        let isSelected = item.id == selection

        Button {
            if isSelected {
                NotificationCenter.default.post(
                    name: .scribeflowDockScrollToTop,
                    object: item.id
                )
                return
            }
            selection = item.id
        } label: {
            ZStack {
                Image(systemName: item.systemImage)
                    .symbolVariant(.fill)
                    .font(.system(size: 23, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .foregroundStyle(isSelected ? .white : AppPalette.accent)
            .frame(width: AppDockMetrics.centerButtonWidth, height: AppDockMetrics.centerButtonHeight)
            .background { todayButtonBackground(isSelected: isSelected) }
            .contentShape(Capsule(style: .continuous))
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: isSelected)
        }
        .buttonStyle(.plain)
        .offset(y: AppDockMetrics.centerButtonLift)
        .accessibilityLabel(item.label)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("dock.tab.\(item.id)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    @ViewBuilder
    private func tabIcon(_ item: RootTabBarItem, isSelected: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: item.systemImage)
                .symbolVariant(isSelected ? .fill : .none)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: AppDockMetrics.iconSize, height: AppDockMetrics.iconSize)

            if item.badge > 0 {
                badge(item.badge, isSelected: isSelected)
            }
        }
    }

    private func tabForeground(isSelected: Bool) -> Color {
        if isSelected {
            return .white
        }
        return AppPalette.secondaryInk.opacity(colorScheme == .dark ? 0.92 : 0.72)
    }

    private func badge(_ count: Int, isSelected: Bool) -> some View {
        Circle()
            .fill(AppPalette.gold)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(isSelected ? Color.white : AppPalette.cardBackground, lineWidth: 1.1))
            .offset(x: 9, y: -8)
    }

    @ViewBuilder
    private func selectedPill(isVisible: Bool) -> some View {
        if isVisible {
            Capsule(style: .continuous)
                .fill(AppPalette.accentButton)
                .overlay { selectedPillSheen }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7)
                }
        }
    }

    @ViewBuilder
    private func todayButtonBackground(isSelected: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(isSelected ? AnyShapeStyle(AppPalette.accentButton) : AnyShapeStyle(AppPalette.paper))
            .overlay {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isSelected
                                ? [Color.white.opacity(0.24), Color.white.opacity(0.05), Color.black.opacity(0.12)]
                                : [Color.white.opacity(0.58), AppPalette.accentSoft.opacity(0.34), AppPalette.paper.opacity(0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(isSelected ? Color.white.opacity(0.22) : AppPalette.accent.opacity(0.16), lineWidth: 0.8)
            }
            .shadow(color: AppPalette.accent.opacity(isSelected ? 0.20 : 0.09), radius: 10, y: 5)
    }

    private var selectedPillSheen: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.28),
                        Color.white.opacity(0.06),
                        Color.black.opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

struct RootDockChrome<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppDockMetrics.chromeVerticalPadding)
            .frame(height: AppDockMetrics.chromeHeight, alignment: .center)
            .background(alignment: .bottom) {
                chromeShape
                    .fill(AppPalette.paper)
                    .overlay { chromeTint }
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.16 : 0.05), radius: 12, y: -1)
                    .ignoresSafeArea(edges: .bottom)
            }
    }

    private var chromeShape: TopRoundedRectangle {
        TopRoundedRectangle(radius: AppDockMetrics.chromeCornerRadius)
    }

    private var chromeTint: some View {
        let colors: [Color] = colorScheme == .dark
            ? [AppPalette.accentSoft.opacity(reduceTransparency ? 0.10 : 0.16), AppPalette.paper.opacity(0.96)]
            : [AppPalette.accentSoft.opacity(reduceTransparency ? 0.12 : 0.22), AppPalette.softSurface.opacity(0.22), AppPalette.paper.opacity(0.96)]

        return chromeShape.fill(
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
        )
    }
}

private struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let clampedRadius = min(radius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + clampedRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + clampedRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - clampedRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + clampedRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
