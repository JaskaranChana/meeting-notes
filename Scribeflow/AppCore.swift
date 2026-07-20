import AppIntents
import CoreSpotlight
import EventKit
import MetricKit
import OSLog
import SwiftUI
import UserNotifications
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
    /// Faintest ink tier. Maintains AA contrast on paper in both appearances.
    static let tertiaryInk  = dyn(
        (0.365, 0.380, 0.420), (0.635, 0.647, 0.678),                               // #5D616B / #A2A5AD
        lightHC: (0.278, 0.294, 0.333), darkHC: (0.753, 0.765, 0.792)               // #474B55 / #C0C3CA
    )

    // MARK: Brand accents — teal signature, brighter in dark for legibility.
    /// Signature teal.
    static let accent  = dyn((0.082, 0.345, 0.353), (0.310, 0.639, 0.647))   // #15585A / #4FA3A5
    /// Amber.
    static let gold    = dyn((0.545, 0.392, 0.082), (0.878, 0.784, 0.482))   // #8B6415 / #E0C87B
    /// Burnt-orange warning.
    static let coral   = dyn((0.616, 0.263, 0.106), (0.878, 0.482, 0.302))   // #9D431B / #E07B4D
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
            let data = payload.jsonRepresentation()
            Task { await DiagnosticsArchive.shared.append(kind: .metrics, data: data) }
            #if DEBUG
            metricsLog.debug("metric payload: \(String(decoding: data, as: UTF8.self), privacy: .public)")
            #else
            let launchMs = payload.applicationLaunchMetrics?.histogrammedTimeToFirstDraw.totalBucketCount ?? 0
            let hangs = payload.applicationResponsivenessMetrics?.histogrammedApplicationHangTime.totalBucketCount ?? 0
            metricsLog.notice("daily metrics — launches=\(launchMs, privacy: .public) hangs=\(hangs, privacy: .public)")
            #endif
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            Task { await DiagnosticsArchive.shared.append(kind: .diagnostics, data: data) }
            #if DEBUG
            metricsLog.debug("diagnostic payload: \(String(decoding: data, as: UTF8.self), privacy: .public)")
            #else
            metricsLog.notice("diagnostic payload received (size=\(data.count, privacy: .public))")
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

// MARK: - Calendar events

enum CalendarAccessState: String, Equatable {
    case notDetermined
    case allowed
    case denied
    case restricted

    var canReadEvents: Bool { self == .allowed }

    static func from(_ status: EKAuthorizationStatus) -> CalendarAccessState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .fullAccess:
            return .allowed
        case .restricted:
            return .restricted
        case .denied, .writeOnly:
            return .denied
        @unknown default:
            return .denied
        }
    }
}

/// Stable calendar event shape for UI and persistence handoff. Views never need
/// to hold EventKit objects, and saved meetings can keep a light source link.
struct CalendarEventSnapshot: Identifiable, Equatable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var location: String?
    var notes: String?
    var attendees: [String]
    var isVideoCall: Bool

    var durationMinutes: Int {
        max(15, Int(endDate.timeIntervalSince(startDate) / 60))
    }

    var objective: String {
        let parts = [
            location.map { "Location: \($0)" },
            notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ].compactMap { $0 }
        return parts.isEmpty ? "Prepared from calendar" : parts.joined(separator: "\n")
    }

    var prepNotesTemplate: String {
        var lines = [
            "- Agenda:",
            "- Decisions:",
            "- Risks:",
            "- Next steps:"
        ]
        if !attendees.isEmpty {
            lines.insert("- Attendees: \(attendees.joined(separator: ", "))", at: 0)
        }
        return lines.joined(separator: "\n")
    }
}

private actor CalendarEventReader {
    private let store = EKEventStore()

    func fetchEvents(from start: Date, to end: Date, limit: Int) -> [CalendarEventSnapshot] {
        store.refreshSourcesIfNecessary()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map(Self.snapshot(from:))
    }

    private static func attendeeNames(from event: EKEvent) -> [String] {
        let names = (event.attendees ?? [])
            .compactMap { participant -> String? in
                let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty { return name }
                return participant.url.absoluteString
                    .replacingOccurrences(of: "mailto:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
            }
        return Array(NSOrderedSet(array: names)) as? [String] ?? names
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

    private static func snapshot(from event: EKEvent) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Meeting",
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location,
            notes: event.notes,
            attendees: attendeeNames(from: event),
            isVideoCall: detectVideoCall(event)
        )
    }
}

@MainActor
final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()
    private let reader = CalendarEventReader()

    private(set) var accessState = CalendarAccessState.from(EKEventStore.authorizationStatus(for: .event))

    @discardableResult
    func refreshAccessState() -> CalendarAccessState {
        accessState = CalendarAccessState.from(EKEventStore.authorizationStatus(for: .event))
        return accessState
    }

    func requestAccessIfNeeded() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        accessState = CalendarAccessState.from(status)
        switch status {
        case .fullAccess:
            return true
        case .denied, .restricted, .writeOnly:
            return false
        case .notDetermined:
            do {
                if #available(iOS 17, *) {
                    let granted = try await store.requestFullAccessToEvents()
                    accessState = CalendarAccessState.from(EKEventStore.authorizationStatus(for: .event))
                    return granted
                } else {
                    let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                        store.requestAccess(to: .event) { granted, error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
                        }
                    }
                    accessState = CalendarAccessState.from(EKEventStore.authorizationStatus(for: .event))
                    return granted
                }
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    func fetchUpcoming(hours: Int = 24, limit: Int = 3) async -> [CalendarEventSnapshot] {
        accessState = CalendarAccessState.from(EKEventStore.authorizationStatus(for: .event))
        guard accessState.canReadEvents else { return [] }
        let now = Date.now
        guard let end = Calendar.current.date(byAdding: .hour, value: hours, to: now) else { return [] }
        return await fetchEvents(from: now, to: end, limit: limit)
    }

    func fetchEvents(from start: Date, to end: Date, limit: Int = 120) async -> [CalendarEventSnapshot] {
        accessState = CalendarAccessState.from(EKEventStore.authorizationStatus(for: .event))
        guard accessState.canReadEvents else { return [] }
        return await reader.fetchEvents(from: start, to: end, limit: limit)
    }
}

typealias UpcomingEvent = CalendarEventSnapshot

/// Single-shot hand-off context so Home can pass an event title into the
/// capture surface without threading parameters through every closure. The
/// CaptureView (or its child) reads + clears this when it appears.
@MainActor
final class UpcomingCaptureContext {
    static let shared = UpcomingCaptureContext()
    var preferredEvent: CalendarEventSnapshot?

    var preferredTitle: String? {
        get { preferredEvent?.title }
        set {
            if let newValue {
                preferredEvent = CalendarEventSnapshot(
                    id: UUID().uuidString,
                    title: newValue,
                    startDate: .now,
                    endDate: Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now,
                    location: nil,
                    notes: nil,
                    attendees: [],
                    isVideoCall: false
                )
            } else {
                preferredEvent = nil
            }
        }
    }

    func consume() -> CalendarEventSnapshot? {
        let value = preferredEvent
        preferredEvent = nil
        return value
    }
}

// MARK: - Local action reminders

enum ReminderScheduler {
    enum ScheduleError: Error, Equatable {
        case permissionDenied
        case invalidDate
        case schedulingFailed

        var message: String {
            switch self {
            case .permissionDenied:
                return "Allow notifications in Settings to schedule reminders."
            case .invalidDate:
                return "Add a future due date before scheduling a reminder."
            case .schedulingFailed:
                return "Couldn't schedule the reminder. Try again."
            }
        }
    }

    static func notificationID(meetingID: Meeting.ID, commitmentID: Commitment.ID) -> String {
        "scribeflow.action.\(meetingID.uuidString).\(commitmentID.uuidString)"
    }

    static func cancel(meetingID: Meeting.ID, commitmentID: Commitment.ID) {
        let identifier = notificationID(meetingID: meetingID, commitmentID: commitmentID)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    static func reminderDate(for dueDate: Date, now: Date = .now) -> Date? {
        let oneDayBefore = Calendar.current.date(byAdding: .day, value: -1, to: dueDate) ?? dueDate
        let candidate = oneDayBefore > now ? oneDayBefore : dueDate
        return candidate > now ? candidate : nil
    }

    static func schedule(
        commitment: Commitment,
        meetingID: Meeting.ID,
        meetingTitle: String,
        dueDate: Date?
    ) async -> Result<String, ScheduleError> {
        guard let dueDate, let fireDate = reminderDate(for: dueDate) else {
            return .failure(.invalidDate)
        }
        return await schedule(
            commitment: commitment,
            meetingID: meetingID,
            meetingTitle: meetingTitle,
            fireDate: fireDate
        )
    }

    static func schedule(
        commitment: Commitment,
        meetingID: Meeting.ID,
        meetingTitle: String,
        fireDate: Date
    ) async -> Result<String, ScheduleError> {
        guard fireDate > .now else { return .failure(.invalidDate) }
        do {
            let center = UNUserNotificationCenter.current()
            let permission = await ScribeflowNotificationAuthorization.shared.requestIfNeeded()
            guard permission.canSchedule else { return .failure(.permissionDenied) }

            let content = UNMutableNotificationContent()
            content.title = commitment.owner == "Owner not named"
                ? "Action reminder"
                : "Follow up: \(commitment.owner)"
            content.body = commitment.statement
            content.subtitle = meetingTitle
            content.sound = .default
            content.interruptionLevel = .active
            content.relevanceScore = 1
            content.threadIdentifier = meetingID.uuidString
            content.userInfo = [
                "meetingID": meetingID.uuidString,
                "commitmentID": commitment.id.uuidString
            ]

            var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
            components.calendar = Calendar.current
            components.timeZone = TimeZone.current
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            guard trigger.nextTriggerDate() != nil else { return .failure(.invalidDate) }
            let identifier = notificationID(meetingID: meetingID, commitmentID: commitment.id)
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            return .success(identifier)
        } catch {
            return .failure(.schedulingFailed)
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
    @Published var openMeetingID: Meeting.ID?

    func requestStartRecord()     { startRecordRequested = true }
    func requestStartType()       { startTypeRequested = true }
    func requestOpenLastMeeting() { openLastMeetingRequested = true }
    func requestOpenAsk()         { openAskRequested = true }
    func requestOpenMeeting(_ id: Meeting.ID) { openMeetingID = id }
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

    static func clear() {
        defaults?.removeObject(forKey: storageKey)
    }
}

extension Notification.Name {
    /// Broadcast from Ask citation taps so the host scene can route to a
    /// specific meeting without threading bindings through every subview.
    static let scribeflowOpenMeeting = Notification.Name("scribeflowOpenMeeting")
    /// Broadcast from RootTabBar when the user re-taps the already-
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
    private static let worker = Worker()

    static func index(_ meetings: [Meeting]) async {
        await worker.index(meetings)
    }

    static func remove(meetingID: UUID) {
        Task { await worker.remove(meetingID: meetingID) }
    }

    static func removeAll() {
        Task { await worker.removeAll() }
    }

    static func removeAllAndWait() async {
        await worker.removeAll()
    }

    private actor Worker {
        private var indexedFingerprints: [Meeting.ID: Int] = [:]
        private var pendingRemovalIDs: Set<Meeting.ID> = []
        // Reconcile once per launch so a deletion interrupted by termination
        // cannot leave a stale system-search result behind.
        private var needsRemoveAll = true

        func index(_ meetings: [Meeting]) async {
            if needsRemoveAll {
                guard await deleteAllFromSystemIndex() else { return }
                indexedFingerprints.removeAll(keepingCapacity: true)
                pendingRemovalIDs.removeAll(keepingCapacity: true)
                needsRemoveAll = false
            }

            let currentIDs = Set(meetings.map(\.id))
            pendingRemovalIDs.formUnion(indexedFingerprints.keys.filter { !currentIDs.contains($0) })
            await flushPendingRemovals()

            var changedMeetings: [Meeting] = []
            var changedFingerprints: [Meeting.ID: Int] = [:]
            changedMeetings.reserveCapacity(min(meetings.count, 8))
            for meeting in meetings {
                let fingerprint = SpotlightIndex.fingerprint(meeting)
                guard indexedFingerprints[meeting.id] != fingerprint else { continue }
                changedMeetings.append(meeting)
                changedFingerprints[meeting.id] = fingerprint
            }
            guard !changedMeetings.isEmpty else { return }

            let items = changedMeetings.map(SpotlightIndex.makeItem)
            guard await submit(items) else { return }
            for (meetingID, fingerprint) in changedFingerprints {
                indexedFingerprints[meetingID] = fingerprint
            }
        }

        func remove(meetingID: Meeting.ID) async {
            pendingRemovalIDs.insert(meetingID)
            await flushPendingRemovals()
        }

        func removeAll() async {
            needsRemoveAll = true
            guard await deleteAllFromSystemIndex() else { return }
            indexedFingerprints.removeAll(keepingCapacity: true)
            pendingRemovalIDs.removeAll(keepingCapacity: true)
            needsRemoveAll = false
        }

        private func flushPendingRemovals() async {
            guard !pendingRemovalIDs.isEmpty else { return }
            let ids = pendingRemovalIDs
            let identifiers = ids.map(\.uuidString)
            let succeeded = await withCheckedContinuation { continuation in
                CSSearchableIndex.default()
                    .deleteSearchableItems(withIdentifiers: identifiers) { error in
                        continuation.resume(returning: error == nil)
                    }
            }
            guard succeeded else { return }
            pendingRemovalIDs.subtract(ids)
            for id in ids {
                indexedFingerprints[id] = nil
            }
        }

        private func deleteAllFromSystemIndex() async -> Bool {
            await withCheckedContinuation { continuation in
                CSSearchableIndex.default()
                    .deleteSearchableItems(withDomainIdentifiers: [SpotlightIndex.domain]) { error in
                        continuation.resume(returning: error == nil)
                    }
            }
        }

        private func submit(_ items: [CSSearchableItem]) async -> Bool {
            await withCheckedContinuation { continuation in
                CSSearchableIndex.default().indexSearchableItems(items) { error in
                    continuation.resume(returning: error == nil)
                }
            }
        }
    }

    private static func fingerprint(_ meeting: Meeting) -> Int {
        var hasher = Hasher()
        hasher.combine(meeting.title)
        hasher.combine(meeting.objective)
        hasher.combine(meeting.workspace)
        hasher.combine(meeting.attendees)
        hasher.combine(meeting.when)
        hasher.combine(meeting.rawNotes)
        hasher.combine(meeting.summaries)
        hasher.combine(meeting.transcript)
        return hasher.finalize()
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

/// A raw source chunk retrieved from the user's library. `sourceID` is scoped
/// to one answer and is the only identifier the language model may cite.
struct RAGResult: Identifiable, Equatable, Sendable {
    let sourceID: String
    let meetingID: UUID
    let meetingTitle: String
    let kind: SourceReferenceKind
    let speaker: String?
    let lineIndex: Int?
    let snippet: String
    let score: Double

    var id: String { "\(sourceID)|\(meetingID.uuidString)" }

    var sourceLabel: String {
        var components = [kind.title]
        if let speaker, !speaker.isEmpty { components.append(speaker) }
        if let lineIndex { components.append("line \(lineIndex + 1)") }
        return components.joined(separator: " - ")
    }
}

/// Turns a free-text due hint ("Friday", "tomorrow", "eod", "next week") into
/// an absolute deadline, resolved relative to when the note was captured — so
/// "due soon" and "overdue" can be judged by real time, not keyword guesses.
enum DueDateParser {
    static func date(from hint: String?, capturedAt ref: Date, calendar: Calendar = .current) -> Date? {
        guard let raw = hint?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let startOfRef = calendar.startOfDay(for: ref)

        func endOf(_ day: Date) -> Date {
            calendar.date(bySettingHour: 23, minute: 59, second: 59, of: day) ?? day
        }
        func addingDays(_ n: Int, to day: Date) -> Date {
            calendar.date(byAdding: .day, value: n, to: day) ?? day
        }

        if raw.contains("today") || raw.contains("eod") || raw.contains("tonight") || raw.contains("end of day") {
            return endOf(startOfRef)
        }
        if raw.contains("tomorrow") {
            return endOf(addingDays(1, to: startOfRef))
        }
        if raw.contains("end of week") || raw.contains("eow") || raw.contains("this week") {
            return endOf(nextWeekday(6, onOrAfter: startOfRef, calendar: calendar)) // Friday
        }
        if raw.contains("next week") {
            return endOf(addingDays(7, to: startOfRef))
        }
        if raw.contains("next month") || raw.contains("month") {
            return endOf(addingDays(30, to: startOfRef))
        }

        let weekdays: [(String, Int)] = [
            ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
            ("thursday", 5), ("friday", 6), ("saturday", 7)
        ]
        for (name, index) in weekdays where raw.contains(name) {
            return endOf(nextWeekday(index, onOrAfter: startOfRef, calendar: calendar))
        }
        return nil
    }

    /// Next date whose weekday == target (1=Sun … 7=Sat), on or after `from`.
    private static func nextWeekday(_ target: Int, onOrAfter from: Date, calendar: Calendar) -> Date {
        let current = calendar.component(.weekday, from: from)
        let delta = (target - current + 7) % 7
        return calendar.date(byAdding: .day, value: delta, to: from) ?? from
    }
}

enum LocalRAG {
    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "you", "your", "this", "that", "from",
        "have", "has", "are", "was", "were", "but", "they", "them",
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

    fileprivate struct SourceChunk: Sendable {
        let meetingID: Meeting.ID
        let meetingTitle: String
        let kind: SourceReferenceKind
        let speaker: String?
        let lineIndex: Int?
        let text: String
        let searchText: String
        let capturedAt: Date
    }

    fileprivate struct IndexedDocument: Sendable {
        let chunk: SourceChunk
        let frequencies: [String: Int]
        let length: Double
        let titleTokens: Set<String>
    }

    struct Index: Sendable {
        fileprivate let documents: [IndexedDocument]
        fileprivate let documentFrequency: [String: Int]
    }

    private struct ScoredChunk: Sendable {
        let chunk: SourceChunk
        let score: Double
    }

    /// Retrieves raw note and transcript chunks. Generated summaries are
    /// deliberately excluded so an AI claim can never become evidence for a
    /// later AI claim.
    static func search(_ query: String, in meetings: [Meeting], limit: Int = 5) -> [RAGResult] {
        search(query, in: makeIndex(from: meetings), limit: limit)
    }

    static func makeIndex(from meetings: [Meeting]) -> Index {
        let documents = meetings.flatMap(makeSourceChunks).map { chunk -> IndexedDocument in
            let tokens = tokenize(chunk.searchText)
            var frequencies: [String: Int] = [:]
            for token in tokens { frequencies[token, default: 0] += 1 }
            let titleTokens = Set(tokenize(chunk.meetingTitle))
            return IndexedDocument(
                chunk: chunk,
                frequencies: frequencies,
                length: sqrt(Double(max(tokens.count, 1))),
                titleTokens: titleTokens
            )
        }
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for token in document.frequencies.keys {
                documentFrequency[token, default: 0] += 1
            }
        }
        return Index(documents: documents, documentFrequency: documentFrequency)
    }

    static func search(
        _ query: String,
        in index: Index,
        limit: Int = 5,
        allowedMeetingIDs: Set<Meeting.ID>? = nil,
        includeTranscripts: Bool = true
    ) -> [RAGResult] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty, !index.documents.isEmpty else { return [] }

        let documents = index.documents.filter { document in
            if let allowedMeetingIDs, !allowedMeetingIDs.contains(document.chunk.meetingID) {
                return false
            }
            if !includeTranscripts,
               document.chunk.kind == .transcript || document.chunk.kind == .audioTranscript {
                return false
            }
            return true
        }
        guard !documents.isEmpty else { return [] }

        let querySet = Set(queryTokens)
        let totalDocs = Double(index.documents.count)
        let scored: [ScoredChunk] = documents.compactMap { document in
            var score = 0.0
            for token in queryTokens {
                guard let tf = document.frequencies[token] else { continue }
                let df = max(1, index.documentFrequency[token] ?? 1)
                let idf = log((totalDocs + 1) / Double(df + 1)) + 1
                score += (1 + log(Double(tf))) * idf
            }
            guard score > 0 else { return nil }
            let titleMatches = document.titleTokens.intersection(querySet).count
            let sourceBoost: Double = document.chunk.kind == .transcript ? 1.10 : 1.04
            let titleBoost = 1 + min(Double(titleMatches) * 0.12, 0.36)
            let ageDays = max(0, Date.now.timeIntervalSince(document.chunk.capturedAt) / 86_400)
            let recencyBoost = 1 + (0.10 / (1 + ageDays / 30))
            let normalized = (score / max(document.length, 1)) * sourceBoost * titleBoost * recencyBoost
            return ScoredChunk(chunk: document.chunk, score: normalized)
        }

        var selected: [ScoredChunk] = []
        var perMeetingCount: [Meeting.ID: Int] = [:]
        var seenSourceText: Set<String> = []
        for candidate in scored.sorted(by: { $0.score > $1.score }) {
            guard selected.count < max(1, limit) else { break }
            guard perMeetingCount[candidate.chunk.meetingID, default: 0] < 2 else { continue }
            let fingerprint = sourceFingerprint(candidate.chunk.text)
            guard !fingerprint.isEmpty, seenSourceText.insert(fingerprint).inserted else { continue }
            selected.append(candidate)
            perMeetingCount[candidate.chunk.meetingID, default: 0] += 1
        }

        return selected.enumerated().map { offset, result in
            RAGResult(
                sourceID: "S\(offset + 1)",
                meetingID: result.chunk.meetingID,
                meetingTitle: result.chunk.meetingTitle,
                kind: result.chunk.kind,
                speaker: result.chunk.speaker,
                lineIndex: result.chunk.lineIndex,
                snippet: String(result.chunk.text.prefix(420)),
                score: result.score
            )
        }
    }

    private static func makeSourceChunks(for meeting: Meeting) -> [SourceChunk] {
        var chunks: [SourceChunk] = []
        let context = [meeting.title, meeting.objective]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")

        let notes = meeting.rawNotes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for (index, note) in notes.enumerated() {
            chunks.append(SourceChunk(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                kind: .note,
                speaker: nil,
                lineIndex: index,
                text: note,
                searchText: context + " " + note,
                capturedAt: meeting.when
            ))
        }

        for (index, line) in meeting.transcript.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            chunks.append(SourceChunk(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                kind: .transcript,
                speaker: line.speaker.trimmingCharacters(in: .whitespacesAndNewlines),
                lineIndex: index,
                text: text,
                searchText: context + " " + line.speaker + " " + text,
                capturedAt: meeting.when
            ))
        }

        if chunks.isEmpty, !context.isEmpty {
            chunks.append(SourceChunk(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                kind: meeting.calendarEventID == nil ? .meetingContext : .calendar,
                speaker: nil,
                lineIndex: nil,
                text: context,
                searchText: context,
                capturedAt: meeting.when
            ))
        }
        return chunks
    }

    private static func sourceFingerprint(_ text: String) -> String {
        tokenize(text).joined(separator: "|")
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

    var displayLocation: String {
        guard let parsed = URL(string: url), let host = parsed.host else {
            return "Secure webhook"
        }
        return host
    }
}

@MainActor
final class WebhookStore: ObservableObject {
    static let shared = WebhookStore()
    @Published private(set) var configs: [WebhookConfig] = []
    @Published private(set) var persistenceError: String?
    private let defaultsKey = "scribeflow.webhooks"
    private let secretStore = KeychainSecretStore(service: "ai.scribeflow.app.webhooks")

    init() {
        load()
    }

    func add(_ config: WebhookConfig) {
        guard Self.validatedHTTPSURL(config.url) != nil else { return }
        do {
            try storeSecret(for: config)
        } catch {
            persistenceError = "The webhook could not be saved securely."
            return
        }
        configs.append(config)
        saveMetadata()
    }

    func remove(_ id: UUID) {
        configs.removeAll { $0.id == id }
        try? secretStore.remove(account: secretAccount(for: id))
        saveMetadata()
    }

    func clear() {
        for config in configs {
            try? secretStore.remove(account: secretAccount(for: config.id))
        }
        configs.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        persistenceError = nil
    }

    func send(meetingTitle: String, body: String, to config: WebhookConfig) async throws {
        guard let url = Self.validatedHTTPSURL(config.url) else {
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
        let persisted = (try? JSONDecoder().decode([WebhookConfig].self, from: data)) ?? []
        var loaded: [WebhookConfig] = []
        var migratedLegacySecrets = false
        var migrationFailed = false
        for var config in persisted {
            if let data = try? secretStore.data(for: secretAccount(for: config.id)),
               let secret = String(data: data, encoding: .utf8),
               Self.validatedHTTPSURL(secret) != nil {
                config.url = secret
                loaded.append(config)
                continue
            }
            if Self.validatedHTTPSURL(config.url) != nil {
                do {
                    try storeSecret(for: config)
                    loaded.append(config)
                    migratedLegacySecrets = true
                } catch {
                    loaded.append(config)
                    migrationFailed = true
                }
            }
        }
        configs = loaded
        if migratedLegacySecrets, !migrationFailed {
            saveMetadata()
        } else if migrationFailed {
            persistenceError = "Move webhook secrets to Keychain by reopening Integrations."
        }
    }

    private func saveMetadata() {
        let metadata = configs.map {
            WebhookConfig(id: $0.id, target: $0.target, url: "", label: $0.label)
        }
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func storeSecret(for config: WebhookConfig) throws {
        guard let data = config.url.data(using: .utf8) else {
            throw KeychainStoreError.encodeFailed
        }
        try secretStore.set(data, for: secretAccount(for: config.id))
        persistenceError = nil
    }

    private func secretAccount(for id: UUID) -> String {
        "webhook.\(id.uuidString)"
    }

    private static func validatedHTTPSURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else { return nil }
        return url
    }
}

// MARK: - Privacy-first local analytics

/// Append-only on-device event log. Captures usage signals (captures started,
/// notes saved, action items resolved) so the user can see what the app has
/// recorded about them under Settings → Privacy → Activity log. We do not
/// upload anything; this is purely local insight. Logging is gated by an
/// `analyticsOptIn` flag stored in UserDefaults and disabled until the user opts in.
struct AnalyticsEvent: Codable, Identifiable, Sendable {
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
    private var saveTask: Task<Void, Never>?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = base.appendingPathComponent("Scribeflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.fileURL = folder.appendingPathComponent("analytics.json")
        load()
        if UserDefaults.standard.object(forKey: optInKey) == nil {
            UserDefaults.standard.set(false, forKey: optInKey)
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
        saveTask?.cancel()
        saveTask = nil
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
        saveTask?.cancel()
        let snapshot = events
        let destination = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
        }
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
