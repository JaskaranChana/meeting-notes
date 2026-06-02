import AppIntents
import CoreSpotlight
import EventKit
import MetricKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let metricsLog = Logger(subsystem: "ai.scribeflow.app", category: "Metrics")

// MARK: - Palette

/// Light-mode-only palette. The whole app is locked to light at the scene
/// root, so every token below is a fixed value — no `Color(uiColor:)` system
/// references that would shift in dark mode.
///
/// Brand structure:
/// - **Paper neutrals** (warm cream → white) carry the bulk of the UI.
/// - **Teal `accent`** is the single signature color: CTAs, key icons, links.
/// - **Gold** is a sparing premium accent. **Coral** is reserved for warnings
///   and destructive states only — do not use it as decoration.
enum AppPalette {
    // MARK: Surfaces — adaptive "Slate" system
    //
    // Light: warm near-neutral paper with a slate-blue signature accent.
    // Dark: deep warm slate that keeps the ink-on-paper feel inverted.
    // Tokens defined with `UIColor` dynamic providers so the same `Color`
    // value adapts per `userInterfaceStyle`. Brand accents brighten slightly
    // in dark for legibility.

    private typealias RGB = (CGFloat, CGFloat, CGFloat)

    /// Adaptive color. Optional `lightHC` / `darkHC` are used when the user has
    /// "Increase Contrast" enabled, letting faint ink tiers darken/brighten for
    /// legibility without flattening the default hierarchy.
    private static func dyn(
        _ light: RGB,
        _ dark: RGB,
        lightHC: RGB? = nil,
        darkHC: RGB? = nil
    ) -> Color {
        Color(UIColor { trait in
            let highContrast = trait.accessibilityContrast == .high
            let c: RGB
            if trait.userInterfaceStyle == .dark {
                c = (highContrast ? darkHC : nil) ?? dark
            } else {
                c = (highContrast ? lightHC : nil) ?? light
            }
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// Page background. Three-stop adaptive gradient — warm cream paper stack.
    static let background = LinearGradient(
        colors: [
            dyn((0.984, 0.976, 0.953), (0.059, 0.067, 0.082)),  // #FBF9F3 / #0F1115
            dyn((0.965, 0.953, 0.925), (0.078, 0.090, 0.110)),  // #F6F3EC / #14171C
            dyn((0.929, 0.914, 0.875), (0.094, 0.106, 0.129))   // #EDE9DF / #181B21
        ],
        startPoint: .top,
        endPoint: .bottomTrailing
    )

    /// Card / panel surface — warm paper in light, deep slate in dark.
    static let cardBackground = dyn((0.984, 0.976, 0.953), (0.078, 0.090, 0.110))   // #FBF9F3 / #14171C
    /// Subtly tinted surface for secondary chips, inputs, list rows.
    static let softSurface    = dyn((0.929, 0.914, 0.875), (0.094, 0.106, 0.129))   // #EDE9DF / #181B21
    /// Nav-bar / dock chrome — dark editorial dock, both modes.
    static let dockBackground = dyn((0.086, 0.102, 0.133), (0.063, 0.071, 0.086))   // #161A22 / #101216
    /// True paper for sheets / modal canvases.
    static let paper          = dyn((0.984, 0.976, 0.953), (0.078, 0.090, 0.110))   // #FBF9F3 / #14171C
    /// Hairline borders.
    static let border         = dyn((0.855, 0.835, 0.788), (0.165, 0.176, 0.200))   // #DAD5C9 / #2A2D33
    /// Subtle hover / selected fill.
    static let highlight      = dyn((0.929, 0.914, 0.875), (0.125, 0.141, 0.169))   // #EDE9DF / #20242B

    // MARK: Ink — cool near-black, inverts to warm off-white in dark.
    static let ink          = dyn((0.086, 0.102, 0.133), (0.953, 0.941, 0.910))     // #161A22 / #F3F0E8
    static let secondaryInk = dyn(
        (0.420, 0.435, 0.478), (0.545, 0.557, 0.588),                               // #6B6F7A / #8B8E96
        lightHC: (0.310, 0.325, 0.365), darkHC: (0.667, 0.678, 0.706)               // #4F535D / #AAACB4
    )
    /// Faintest ink tier. Base ~4:1 on paper; Increase-Contrast pushes to AA.
    static let tertiaryInk  = dyn(
        (0.494, 0.510, 0.553), (0.451, 0.463, 0.498),                               // #7E828D / #737682
        lightHC: (0.420, 0.435, 0.478), darkHC: (0.545, 0.557, 0.588)               // #6B6F7A / #8B8E96
    )

    // MARK: Brand accents — teal signature, brighter in dark for legibility.
    /// Signature teal.
    static let accent  = dyn((0.082, 0.345, 0.353), (0.310, 0.639, 0.647))   // #15585A / #4FA3A5
    /// Amber.
    static let gold    = dyn((0.710, 0.525, 0.173), (0.878, 0.784, 0.482))   // #B5862C / #E0C87B
    /// Burnt-orange warning.
    static let coral   = dyn((0.722, 0.361, 0.180), (0.878, 0.482, 0.302))   // #B85C2E / #E07B4D
    /// Success green.
    static let success = dyn((0.290, 0.478, 0.243), (0.490, 0.820, 0.639))   // #4A7A3E / #7DD1A3

    static let shadow = Color.black.opacity(0.05)

    // MARK: Showpiece gradients — used on hero / capture surfaces only
    /// Deep teal → signature teal → warm amber. Cinematic, restrained.
    static let heroGradient = LinearGradient(
        colors: [
            Color(red: 0.055, green: 0.176, blue: 0.180), // #0E2D2E deep teal
            Color(red: 0.082, green: 0.345, blue: 0.353), // #15585A signature
            Color(red: 0.710, green: 0.525, blue: 0.173)  // #B5862C amber
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Muted hero twin so library / secondary heroes don't fight.
    static let libraryGradient = LinearGradient(
        colors: [
            Color(red: 0.047, green: 0.149, blue: 0.153), // #0C2627
            Color(red: 0.078, green: 0.314, blue: 0.322), // #145052
            Color(red: 0.659, green: 0.486, blue: 0.157)  // #A87C28
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Extended tokens

    /// Pale wash of accent — chip backgrounds, hover fills, focus tints.
    static let accentSoft = dyn((0.851, 0.902, 0.890), (0.110, 0.208, 0.208))      // #D9E6E3 / #1C3535
    /// Deeper accent for pressed gradients and emphasized rails.
    static let accentDeep = dyn((0.055, 0.227, 0.231), (0.039, 0.157, 0.161))      // #0E3A3B / #0A2829
    /// Elevated surface above `cardBackground` — used for nested cards.
    static let elevated   = dyn((0.992, 0.984, 0.961), (0.106, 0.122, 0.149))      // #FDFBF5 / #1B1F26
    /// Hairline divider, slightly stronger than `border`.
    static let divider    = dyn((0.812, 0.792, 0.745), (0.200, 0.212, 0.239))      // #CFCABE / #33363D

    /// Capture stage gradient — immersive near-black stack for live recording.
    static let captureGradient = LinearGradient(
        colors: [
            Color(red: 0.059, green: 0.067, blue: 0.082), // #0F1115
            Color(red: 0.063, green: 0.122, blue: 0.125), // #101F20 teal wash
            Color(red: 0.082, green: 0.345, blue: 0.353)  // #15585A signature
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Two-stop accent button gradient — primary CTAs.
    static let accentButton = LinearGradient(
        colors: [
            Color(red: 0.114, green: 0.431, blue: 0.439), // #1D6E70 brighter top
            Color(red: 0.055, green: 0.227, blue: 0.231)  // #0E3A3B deeper bottom
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Ink button gradient — secondary CTAs / "Ask this note".
    static let inkButton = LinearGradient(
        colors: [
            Color(red: 0.086, green: 0.102, blue: 0.133), // #161A22
            Color(red: 0.039, green: 0.047, blue: 0.063)  // #0A0C10
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Appearance preference

/// User-facing appearance toggle. `system` defers to iOS; explicit choices
/// override at the root scene via `.preferredColorScheme(...)`.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Persistent storage key used by `@AppStorage`.
    static let storageKey = "appearancePreference"
}

// MARK: - Haptics

enum HapticEngine {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred()
    }
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(type)
    }
    static func select() {
        let gen = UISelectionFeedbackGenerator()
        gen.prepare()
        gen.selectionChanged()
    }
}

// MARK: - Toast

struct ToastItem: Equatable {
    let id = UUID()
    let message: String
    let icon: String
    /// Optional tappable action — when present, renders an inline button on the toast
    /// (used for undo on soft-deletes). Equality ignores the closure.
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    static func == (lhs: ToastItem, rhs: ToastItem) -> Bool { lhs.id == rhs.id }
}

struct ToastView: View {
    let item: ToastItem
    var onDismiss: (() -> Void)? = nil
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 22, height: 22)
            Text(item.message)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle = item.actionTitle, let action = item.action {
                Spacer(minLength: 4)
                Button {
                    HapticEngine.tap(.light)
                    action()
                    onDismiss?()
                } label: {
                    Text(actionTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AppPalette.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppPalette.accentSoft, in: Capsule())
                        .overlay(Capsule().strokeBorder(AppPalette.accent.opacity(0.20), lineWidth: 0.8))
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel("\(actionTitle) \(item.message)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            Capsule()
                .fill(AppPalette.cardBackground)
                .appShadow(AppShadow.card)
        )
        .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.6), lineWidth: 0.8))
        .offset(y: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    if value.translation.height < 0 {
                        dragOffset = value.translation.height * 0.6
                    }
                }
                .onEnded { value in
                    if value.translation.height < -30 {
                        withAnimation(AppMotion.smooth) { onDismiss?() }
                    } else {
                        withAnimation(AppMotion.snappy) { dragOffset = 0 }
                    }
                }
        )
    }
}

// MARK: - Navigation

typealias NavigationPressStyle = PressScaleButtonStyle

// MARK: - Chrome

struct ScribeflowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackground(AppPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        UIApplication.shared.endEditing()
                    } label: {
                        Label("Close", systemImage: "xmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                    }
                    .tint(AppPalette.ink)
                }
            }
    }
}

// MARK: - UIApplication

extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    var bottomSafeAreaInset: CGFloat {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    var topSafeAreaInset: CGFloat {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }
}

// MARK: - Utilities

func suggestedMeetingTitle(objective: String, notes: String, fallback: String) -> String {
    let source = "\(objective)\n\(notes)"
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty }) ?? fallback

    let cleaned = source
        .replacingOccurrences(of: "- ", with: "")
        .replacingOccurrences(of: "Decision:", with: "")
        .replacingOccurrences(of: "Action:", with: "")
        .replacingOccurrences(of: "Concern:", with: "")
        .replacingOccurrences(of: "Follow-up:", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    let words = cleaned.split(separator: " ").prefix(6)
    let title = words.joined(separator: " ")
    return title.isEmpty ? fallback : title
}

struct IdentifiableString: Identifiable {
    let id = UUID()
    let value: String
}

// MARK: - MetricKit subscriber

/// Lightweight MetricKit hook. iOS hands us a daily metric payload (battery,
/// launch time, hangs) and any crash diagnostics from the previous day.
/// In release we log a single summary line; in debug we log the full
/// payload. All output goes through OSLog. Wire a real telemetry sink later.
final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsSubscriber()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            #if DEBUG
            metricsLog.debug("metric payload: \(String(decoding: payload.jsonRepresentation(), as: UTF8.self), privacy: .public)")
            #else
            let launchMs = payload.applicationLaunchMetrics?.histogrammedTimeToFirstDraw.totalBucketCount ?? 0
            let hangs = payload.applicationResponsivenessMetrics?.histogrammedApplicationHangTime.totalBucketCount ?? 0
            metricsLog.notice("daily metrics — launches=\(launchMs, privacy: .public) hangs=\(hangs, privacy: .public)")
            #endif
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            #if DEBUG
            metricsLog.debug("diagnostic payload: \(String(decoding: payload.jsonRepresentation(), as: UTF8.self), privacy: .public)")
            #else
            metricsLog.notice("diagnostic payload received (size=\(payload.jsonRepresentation().count, privacy: .public))")
            #endif
        }
    }
}

// MARK: - Retry helper

/// Exponential-backoff retry helper. Use for idempotent network calls (AI
/// summarize, sync push) that can be replayed safely after a transient
/// failure. Caller owns idempotency keys — we do not invent them.
enum RetryPolicy {
    static func withBackoff<T: Sendable>(
        attempts: Int = 3,
        initialDelaySeconds: Double = 0.4,
        maxDelaySeconds: Double = 8.0,
        retryableCheck: (@Sendable (Error) -> Bool)? = nil,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var delay = initialDelaySeconds
        var lastError: Error = CancellationError()
        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .userAuthenticationRequired
                || error.code == .userCancelledAuthentication {
                throw error
            } catch {
                if let retryableCheck, !retryableCheck(error) {
                    throw error
                }
                lastError = error
                if attempt == attempts { break }
                try await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, maxDelaySeconds)
            }
        }
        throw lastError
    }
}

// MARK: - Upcoming calendar events

/// Lightweight EventKit reader for upcoming events in the next 24 hours.
/// Used by Home to surface "what's next" so the user can prep notes or arm a
/// recording before walking into a meeting. iOS gates access through
/// `NSCalendarsFullAccessUsageDescription` (set in Info.plist).
struct UpcomingEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let isVideoCall: Bool
}

@MainActor
final class UpcomingEventsService {
    static let shared = UpcomingEventsService()
    private let store = EKEventStore()

    private(set) var authorization: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    func requestAccessIfNeeded() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorization = status
        switch status {
        case .fullAccess, .authorized:
            return true
        case .denied, .restricted, .writeOnly:
            return false
        case .notDetermined:
            do {
                if #available(iOS 17, *) {
                    let granted = try await store.requestFullAccessToEvents()
                    authorization = EKEventStore.authorizationStatus(for: .event)
                    return granted
                } else {
                    return try await withCheckedThrowingContinuation { continuation in
                        store.requestAccess(to: .event) { granted, error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
                        }
                    }
                }
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    func fetchUpcoming(hours: Int = 24, limit: Int = 3) -> [UpcomingEvent] {
        guard authorization == .fullAccess || authorization == .authorized else { return [] }
        let now = Date.now
        guard let end = Calendar.current.date(byAdding: .hour, value: hours, to: now) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
        return events.map { event in
            let video = Self.detectVideoCall(event)
            return UpcomingEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Meeting",
                startDate: event.startDate,
                endDate: event.endDate,
                location: event.location,
                isVideoCall: video
            )
        }
    }

    private static func detectVideoCall(_ event: EKEvent) -> Bool {
        let haystack = [
            event.notes ?? "",
            event.location ?? "",
            event.url?.absoluteString ?? ""
        ].joined(separator: " ").lowercased()
        let markers = ["zoom.us", "meet.google", "teams.microsoft", "webex", "whereby", "around.co", "facetime"]
        return markers.contains(where: haystack.contains)
    }
}

/// Single-shot hand-off context so Home can pass an event title into the
/// capture surface without threading parameters through every closure. The
/// CaptureView (or its child) reads + clears this when it appears.
@MainActor
final class UpcomingCaptureContext {
    static let shared = UpcomingCaptureContext()
    var preferredTitle: String?

    func consume() -> String? {
        let value = preferredTitle
        preferredTitle = nil
        return value
    }
}

// MARK: - Pending capture inbox (App Intents / Shortcuts)

/// Pending-action inbox the AppIntent layer writes into when iOS launches
/// the app from a Siri / Shortcuts request. The root scene drains it on
/// appearance and triggers the corresponding UI flow (open capture).
@MainActor
final class PendingCaptureInbox: ObservableObject {
    static let shared = PendingCaptureInbox()
    @Published var startRecordRequested = false
    @Published var startTypeRequested = false
    @Published var openLastMeetingRequested = false
    @Published var openAskRequested = false

    func requestStartRecord()     { startRecordRequested = true }
    func requestStartType()       { startTypeRequested = true }
    func requestOpenLastMeeting() { openLastMeetingRequested = true }
    func requestOpenAsk()         { openAskRequested = true }
}

// MARK: - App Intents

/// Start a new recorded capture from Siri, Shortcuts, or a Lock Screen
/// shortcut. Brings the app to the foreground and arms the record path.
struct StartScribeflowRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Scribeflow recording"
    static var description = IntentDescription("Open Scribeflow and immediately begin a new meeting recording.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingCaptureInbox.shared.requestStartRecord()
        return .result()
    }
}

/// Start a typed quick note via Siri or Shortcuts. Useful for "Hey Siri,
/// take a Scribeflow note" without speaking the contents through dictation.
struct StartScribeflowQuickNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "New Scribeflow quick note"
    static var description = IntentDescription("Open Scribeflow on the quick-note composer.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingCaptureInbox.shared.requestStartType()
        return .result()
    }
}

/// Jump straight into the most recent meeting. Common follow-up after a
/// recording — "Hey Siri, open my last Scribeflow meeting."
struct OpenLastScribeflowMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Open last Scribeflow meeting"
    static var description = IntentDescription("Open the most recently captured meeting in Scribeflow.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingCaptureInbox.shared.requestOpenLastMeeting()
        return .result()
    }
}

/// Open the Ask tab focused for a cross-meeting question. Lets a user say
/// "Hey Siri, ask Scribeflow…" then type or speak the question.
struct AskScribeflowIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Scribeflow"
    static var description = IntentDescription("Open Scribeflow's Ask tab to query across every saved meeting.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingCaptureInbox.shared.requestOpenAsk()
        return .result()
    }
}

// MARK: - Widget shared snapshot
//
// Scaffold for a future Widget Extension target. The widget reads this
// lightweight snapshot via an App Group `UserDefaults` suite so the
// extension never needs to load the full meeting store.
//
// To finish wiring widgets:
// 1. Xcode → File ▸ New ▸ Target ▸ Widget Extension. Include Live Activity
//    if you want the recording Live Activity wired up too.
// 2. Enable App Groups capability on both the app target *and* the widget
//    extension. Use the same group ID below.
// 3. Call `WidgetSharedStore.flush(from: store)` from a background queue
//    whenever the store's revision changes (debounce ~1s).
// 4. Inside the widget extension, `WidgetSharedStore.read()` gives the
//    snapshot to render the timeline entry.

struct WidgetSharedSnapshot: Codable, Equatable {
    var nextMeetingTitle: String?
    var nextMeetingStart: Date?
    var todayCaptureCount: Int
    var openFollowUpCount: Int
    var generatedAt: Date

    init(
        nextMeetingTitle: String? = nil,
        nextMeetingStart: Date? = nil,
        todayCaptureCount: Int = 0,
        openFollowUpCount: Int = 0,
        generatedAt: Date = .now
    ) {
        self.nextMeetingTitle = nextMeetingTitle
        self.nextMeetingStart = nextMeetingStart
        self.todayCaptureCount = todayCaptureCount
        self.openFollowUpCount = openFollowUpCount
        self.generatedAt = generatedAt
    }
}

enum WidgetSharedStore {
    /// Replace with the App Group identifier you assign when the Widget
    /// Extension target is added in Xcode. Both targets must enable the
    /// App Groups capability with this exact ID.
    static let appGroupID = "group.ai.scribeflow.app"

    private static let storageKey = "scribeflow.widget.snapshot.v1"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    @discardableResult
    static func write(_ snapshot: WidgetSharedSnapshot) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    static func read() -> WidgetSharedSnapshot? {
        guard let defaults, let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSharedSnapshot.self, from: data)
    }
}

extension Notification.Name {
    /// Broadcast from Ask citation taps so the host scene can route to a
    /// specific meeting without threading bindings through every subview.
    static let scribeflowOpenMeeting = Notification.Name("scribeflowOpenMeeting")
    /// Broadcast from FloatingTabDock when the user re-taps the already-
    /// selected tab. Tab roots listen and scroll their primary list to top.
    /// `object` carries the raw tab id (`String`).
    static let scribeflowDockScrollToTop = Notification.Name("scribeflowDockScrollToTop")
    /// Broadcast from any subview that wants the host scene to show a toast
    /// without needing a `Binding<ToastItem?>` plumbed through every parent.
    /// `object` carries a `ToastItem`.
    static let scribeflowToast = Notification.Name("scribeflowToast")
}

// MARK: - Spotlight indexing

/// Indexes meetings into Core Spotlight so users can find their notes from
/// iOS system search + Siri Suggestions, even with the app closed. Each
/// meeting becomes a searchable item keyed by its UUID; tapping the search
/// result deep-links the app via `NSUserActivity` (handled in the root).
enum SpotlightIndex {
    static let domain = "ai.scribeflow.app.meetings"
    static let activityType = "ai.scribeflow.app.openMeeting"

    static func index(_ meetings: [Meeting]) {
        let items = meetings.map(makeItem)
        CSSearchableIndex.default().indexSearchableItems(items) { _ in }
    }

    static func remove(meetingID: UUID) {
        CSSearchableIndex.default()
            .deleteSearchableItems(withIdentifiers: [meetingID.uuidString]) { _ in }
    }

    static func removeAll() {
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }

    private static func makeItem(_ meeting: Meeting) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.content)
        attrs.title = meeting.title
        attrs.contentDescription = meeting.objective
        attrs.keywords = [meeting.workspace] + meeting.attendees
        attrs.contentCreationDate = meeting.when
        attrs.contentModificationDate = meeting.when
        // Make the meeting's notes + transcript fully searchable.
        let summaryText = meeting.summaries
            .flatMap { $0.summary.sections.flatMap(\.bullets) }
            .joined(separator: "\n")
        let transcriptText = meeting.transcript.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        attrs.textContent = [meeting.rawNotes, summaryText, transcriptText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return CSSearchableItem(
            uniqueIdentifier: meeting.id.uuidString,
            domainIdentifier: domain,
            attributeSet: attrs
        )
    }
}

// MARK: - Local RAG (TF-IDF ranker)

/// On-device retrieval over the meeting library. Returns the top-N most
/// relevant meetings + a citation snippet per result so the Ask tab can show
/// answers grounded in the user's own notes without sending data anywhere.
///
/// Tokenization: lowercase, alphanumeric runs ≥3 chars, strip a small
/// stopword set. Scoring: classic TF-IDF cosine over query vs. concatenated
/// meeting text (title + objective + raw notes + summary bullets + transcript).
struct RAGResult: Identifiable, Equatable {
    let id: UUID
    let meetingTitle: String
    let snippet: String
    let score: Double
}

enum LocalRAG {
    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "you", "your", "this", "that", "from",
        "have", "has", "are", "was", "were", "but", "not", "they", "them",
        "their", "what", "when", "where", "which", "who", "how", "any",
        "all", "can", "will", "would", "could", "should", "about", "into",
        "than", "then", "also", "just", "out", "our", "ours"
    ]

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                if current.count >= 3, !stopwords.contains(current) {
                    tokens.append(current)
                }
                current = ""
            }
        }
        if current.count >= 3, !stopwords.contains(current) {
            tokens.append(current)
        }
        return tokens
    }

    static func search(_ query: String, in meetings: [Meeting], limit: Int = 5) -> [RAGResult] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty, !meetings.isEmpty else { return [] }

        // Document texts + token counts.
        struct Doc {
            let meeting: Meeting
            let tokens: [String]
            let tokenFreq: [String: Int]
            let length: Double
            let fullText: String
        }

        let docs: [Doc] = meetings.map { meeting in
            let parts = [
                meeting.title,
                meeting.objective,
                meeting.rawNotes,
                meeting.summaries.flatMap { $0.summary.sections.flatMap(\.bullets) }.joined(separator: "\n"),
                meeting.transcript.map(\.text).joined(separator: "\n")
            ]
            let text = parts.joined(separator: "\n")
            let tokens = tokenize(text)
            var freq: [String: Int] = [:]
            for token in tokens { freq[token, default: 0] += 1 }
            return Doc(
                meeting: meeting,
                tokens: tokens,
                tokenFreq: freq,
                length: sqrt(Double(tokens.count)),
                fullText: text
            )
        }

        let querySet = Set(queryTokens)
        var docFreq: [String: Int] = [:]
        for doc in docs {
            for token in querySet where doc.tokenFreq[token] != nil {
                docFreq[token, default: 0] += 1
            }
        }
        let totalDocs = Double(docs.count)

        // Score each doc.
        let scored: [RAGResult] = docs.compactMap { doc in
            var score = 0.0
            for token in queryTokens {
                guard let tf = doc.tokenFreq[token] else { continue }
                let df = max(1, docFreq[token] ?? 1)
                let idf = log((totalDocs + 1) / Double(df))
                score += Double(tf) * idf
            }
            guard score > 0 else { return nil }
            let normalized = score / max(doc.length, 1)
            let snippet = bestSnippet(for: queryTokens, in: doc.fullText)
            return RAGResult(
                id: doc.meeting.id,
                meetingTitle: doc.meeting.title,
                snippet: snippet,
                score: normalized
            )
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// Pick the sentence with the highest query-token coverage as the citation
    /// snippet. Falls back to the first 160 chars of the document.
    private static func bestSnippet(for query: [String], in text: String) -> String {
        let querySet = Set(query)
        let sentences = text
            .replacingOccurrences(of: "\n", with: ". ")
            .components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var best: (sentence: String, hits: Int) = ("", 0)
        for sentence in sentences {
            let hits = tokenize(sentence).filter { querySet.contains($0) }.count
            if hits > best.hits {
                best = (sentence, hits)
            }
        }
        if best.hits > 0 {
            return String(best.sentence.prefix(220))
        }
        return String(text.prefix(160))
    }
}

// MARK: - Shareable links

/// Deterministic short-code generator for meeting URLs. Maps a stable UUID
/// to a base-36, 8-character public code so the user can paste a clean
/// `scribeflow.ai/n/<code>` link instead of leaking the meeting UUID.
/// The web side that resolves these codes is intentionally out of scope —
/// this layer only generates the codes and ShareLink-ready URLs.
enum ShareableLink {
    private static let host = "scribeflow.ai"

    static func code(for id: UUID) -> String {
        // Fold the UUID's 16 bytes into a 64-bit integer, then base-36 encode.
        // Collisions are negligible at single-user scale.
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        var folded: UInt64 = 0xC0FFEE
        for byte in bytes { folded = folded &* 1_099_511_628_211 ^ UInt64(byte) }
        var value = folded
        var chars: [Character] = []
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        while value > 0 {
            chars.append(alphabet[Int(value % 36)])
            value /= 36
        }
        let raw = String(chars)
        return String(raw.prefix(8)).padding(toLength: 8, withPad: "x", startingAt: 0)
    }

    static func url(for id: UUID) -> URL {
        URL(string: "https://\(host)/n/\(code(for: id))")!
    }
}

// MARK: - Outbound webhooks (Slack / Notion / Linear)

/// User-configured outbound webhook. We do not bundle integration secrets;
/// the user pastes their own incoming-webhook URL (Slack, Notion automation,
/// Linear "Create issue from webhook", Zapier Catch Hook). Posting a meeting
/// recap then becomes a single tap from the share menu.
enum WebhookTarget: String, Codable, CaseIterable, Identifiable {
    case slack
    case notion
    case linear
    case zapier
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slack:   "Slack"
        case .notion:  "Notion"
        case .linear:  "Linear"
        case .zapier:  "Zapier"
        case .custom:  "Custom webhook"
        }
    }

    var systemImage: String {
        switch self {
        case .slack:   "number"
        case .notion:  "doc.richtext"
        case .linear:  "checkmark.square"
        case .zapier:  "bolt.horizontal"
        case .custom:  "link"
        }
    }
}

struct WebhookConfig: Codable, Identifiable, Hashable {
    let id: UUID
    var target: WebhookTarget
    var url: String
    var label: String

    init(id: UUID = UUID(), target: WebhookTarget, url: String, label: String) {
        self.id = id
        self.target = target
        self.url = url
        self.label = label
    }
}

@MainActor
final class WebhookStore: ObservableObject {
    static let shared = WebhookStore()
    @Published private(set) var configs: [WebhookConfig] = []
    private let defaultsKey = "scribeflow.webhooks"

    init() {
        load()
    }

    func add(_ config: WebhookConfig) {
        configs.append(config)
        save()
    }

    func remove(_ id: UUID) {
        configs.removeAll { $0.id == id }
        save()
    }

    func send(meetingTitle: String, body: String, to config: WebhookConfig) async throws {
        guard let url = URL(string: config.url) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let payload: [String: Any]
        switch config.target {
        case .slack:
            payload = ["text": "*\(meetingTitle)*\n\(body)"]
        case .notion, .linear, .zapier, .custom:
            payload = ["title": meetingTitle, "body": body]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 30
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        configs = (try? JSONDecoder().decode([WebhookConfig].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

// MARK: - Privacy-first local analytics

/// Append-only on-device event log. Captures usage signals (captures started,
/// notes saved, action items resolved) so the user can see what the app has
/// recorded about them under Settings → Privacy → Activity log. We do not
/// upload anything; this is purely local insight. Logging is gated by an
/// `analyticsOptIn` flag stored in UserDefaults, defaulted on but toggleable.
struct AnalyticsEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let name: String
    let context: [String: String]

    init(name: String, context: [String: String] = [:]) {
        self.id = UUID()
        self.timestamp = .now
        self.name = name
        self.context = context
    }
}

@MainActor
final class AnalyticsLog {
    static let shared = AnalyticsLog()

    private let fileURL: URL
    private let optInKey = "analyticsOptIn"
    private(set) var events: [AnalyticsEvent] = []

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = base.appendingPathComponent("Scribeflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.fileURL = folder.appendingPathComponent("analytics.json")
        load()
        if UserDefaults.standard.object(forKey: optInKey) == nil {
            UserDefaults.standard.set(true, forKey: optInKey)
        }
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: optInKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: optInKey)
            if !newValue { clear() }
        }
    }

    func log(_ name: String, _ context: [String: String] = [:]) {
        guard isEnabled else { return }
        let event = AnalyticsEvent(name: name, context: context)
        events.append(event)
        // Cap log to 2,000 events so it stays bounded.
        if events.count > 2_000 { events.removeFirst(events.count - 2_000) }
        save()
    }

    func clear() {
        events.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        events = (try? decoder.decode([AnalyticsEvent].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct ScribeflowShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartScribeflowRecordingIntent(),
            phrases: [
                "Start a \(.applicationName) recording",
                "Begin meeting in \(.applicationName)",
                "Record in \(.applicationName)"
            ],
            shortTitle: "Start recording",
            systemImageName: "waveform.badge.mic"
        )
        AppShortcut(
            intent: StartScribeflowQuickNoteIntent(),
            phrases: [
                "New \(.applicationName) note",
                "Take a \(.applicationName) note",
                "Quick note in \(.applicationName)"
            ],
            shortTitle: "Quick note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenLastScribeflowMeetingIntent(),
            phrases: [
                "Open my last \(.applicationName) meeting",
                "Show my latest \(.applicationName) note",
                "Continue in \(.applicationName)"
            ],
            shortTitle: "Last meeting",
            systemImageName: "doc.text.fill"
        )
        AppShortcut(
            intent: AskScribeflowIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Search \(.applicationName)",
                "Find in \(.applicationName)"
            ],
            shortTitle: "Ask Scribeflow",
            systemImageName: "sparkle.magnifyingglass"
        )
    }
}
