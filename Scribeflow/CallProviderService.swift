import Foundation
import Observation

enum CallProviderCapability: String, Codable {
    case appOwnedVoIP
    case pstnBridge
    case recording
    case transcriptionWebhook
}

struct ProviderCallSession: Codable, Equatable, Identifiable {
    var id = UUID()
    var displayNumber: String
    var startedAt: Date
    var isMuted: Bool
    var isSpeakerEnabled: Bool
    var isRecording: Bool
    var providerName: String
    var recordingDisclosure: String
}

enum CallProviderError: LocalizedError {
    case invalidNumber
    case credentialsRequired
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidNumber:
            "Enter a phone number before starting the provider call."
        case .credentialsRequired:
            "A compliant VoIP or telephony backend is required before this can place real calls."
        case .unavailable:
            "The calling provider is unavailable right now."
        }
    }
}

enum PhoneDialer {
    static func normalizedNumber(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let ignoredCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-()."))
        var normalized = ""

        for scalar in trimmed.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                normalized.append(String(scalar))
            } else if scalar == "+", normalized.isEmpty {
                normalized.append("+")
            } else if ignoredCharacters.contains(scalar) {
                continue
            } else {
                return nil
            }
        }

        guard normalized.dropFirst().contains("+") == false else { return nil }
        let digitCount = normalized.filter(\.isNumber).count
        guard (3...15).contains(digitCount) else { return nil }
        return normalized
    }

    static func callURL(from rawValue: String) -> URL? {
        guard let normalized = normalizedNumber(from: rawValue) else { return nil }
        return URL(string: "tel:\(normalized)")
    }

    static func friendlyValidationMessage(for rawValue: String) -> String? {
        normalizedNumber(from: rawValue) == nil
            ? "Enter a valid phone number with digits, spaces, dashes, or a leading +."
            : nil
    }
}

protocol CompliantCallProvider {
    var name: String { get }
    var capabilities: Set<CallProviderCapability> { get }
    var isConfigured: Bool { get }
    var allowsSandboxCalls: Bool { get }
    func startCall(to number: String) async throws -> ProviderCallSession
    func endCall(_ session: ProviderCallSession) async
    func setMuted(_ muted: Bool, for session: ProviderCallSession) async throws -> ProviderCallSession
    func setSpeakerEnabled(_ enabled: Bool, for session: ProviderCallSession) async throws -> ProviderCallSession
}

struct MockCompliantCallProvider: CompliantCallProvider {
    let name: String
    var isConfigured: Bool
    var allowsSandboxCalls: Bool

    var capabilities: Set<CallProviderCapability> {
        guard isConfigured || allowsSandboxCalls else {
            return [.appOwnedVoIP]
        }
        return [.appOwnedVoIP, .pstnBridge, .recording, .transcriptionWebhook]
    }

    init(
        name: String = "Provider sandbox",
        isConfigured: Bool = false,
        allowsSandboxCalls: Bool = Self.defaultAllowsSandboxCalls
    ) {
        self.name = name
        self.isConfigured = isConfigured
        self.allowsSandboxCalls = allowsSandboxCalls
    }

    func startCall(to number: String) async throws -> ProviderCallSession {
        guard isConfigured || allowsSandboxCalls else {
            throw CallProviderError.credentialsRequired
        }

        guard let cleaned = PhoneDialer.normalizedNumber(from: number) else {
            throw CallProviderError.invalidNumber
        }

        try? await Task.sleep(for: .milliseconds(450))
        return ProviderCallSession(
            displayNumber: cleaned,
            startedAt: .now,
            isMuted: false,
            isSpeakerEnabled: false,
            isRecording: true,
            providerName: name,
            recordingDisclosure: isConfigured
                ? "Recording is handled by your configured provider flow. Confirm participant consent before recording."
                : "Sandbox session only. \(RecordingCompliance.providerCallRequirement)"
        )
    }

    func endCall(_ session: ProviderCallSession) async {
        try? await Task.sleep(for: .milliseconds(180))
    }

    func setMuted(_ muted: Bool, for session: ProviderCallSession) async throws -> ProviderCallSession {
        var copy = session
        copy.isMuted = muted
        return copy
    }

    func setSpeakerEnabled(_ enabled: Bool, for session: ProviderCallSession) async throws -> ProviderCallSession {
        var copy = session
        copy.isSpeakerEnabled = enabled
        return copy
    }

    private static var defaultAllowsSandboxCalls: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

@MainActor
@Observable
final class ProviderCallViewModel {
    var phoneNumber = ""
    var session: ProviderCallSession?
    var elapsedSeconds = 0
    var isStarting = false
    var errorMessage: String?
    var callNotes = ""

    @ObservationIgnored private let provider: CompliantCallProvider
    @ObservationIgnored private var timer: Timer?

    init(provider: CompliantCallProvider = MockCompliantCallProvider()) {
        self.provider = provider
    }

    var providerName: String {
        provider.name
    }

    var isProviderConfigured: Bool {
        provider.isConfigured
    }

    var isProviderAvailable: Bool {
        provider.isConfigured || provider.allowsSandboxCalls
    }

    var providerStatusLabel: String {
        if provider.isConfigured {
            return "Configured"
        }
        if provider.allowsSandboxCalls {
            return "Sandbox only"
        }
        return "Setup required"
    }

    var elapsedLabel: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var canStart: Bool {
        !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStarting && isProviderAvailable
    }

    func start() async {
        guard !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isStarting else { return }
        guard isProviderAvailable else {
            errorMessage = CallProviderError.credentialsRequired.localizedDescription
            return
        }

        isStarting = true
        errorMessage = nil
        do {
            let started = try await provider.startCall(to: phoneNumber)
            session = started
            elapsedSeconds = 0
            startTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
        isStarting = false
    }

    func end() async {
        guard let session else { return }
        await provider.endCall(session)
        stopTimer()
        self.session = nil
        elapsedSeconds = 0
    }

    func toggleMute() async {
        guard let session else { return }
        do {
            self.session = try await provider.setMuted(!session.isMuted, for: session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleSpeaker() async {
        guard let session else { return }
        do {
            self.session = try await provider.setSpeakerEnabled(!session.isSpeakerEnabled, for: session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.session?.startedAt else { return }
                self.elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
            }
        }
    }
}
