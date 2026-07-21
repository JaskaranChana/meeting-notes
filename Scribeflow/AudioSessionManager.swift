import AVFoundation
import Observation

// MARK: - AudioSessionManager
//
// Centralized AVAudioSession controller used by capture paths (LiveMeeting,
// VoiceNote). Handles interruptions and route changes so individual
// coordinators get callbacks instead of crashing or hanging silently.
//
// Production pattern: one class owns the session lifecycle; coordinators
// register a resume closure that fires automatically after an interruption ends.

@MainActor
@Observable
final class AudioSessionManager {

    static let shared = AudioSessionManager()

    enum SessionState: Equatable {
        case idle
        case active
        case interrupted
        case failed(String)
    }

    var state: SessionState = .idle
    var currentRoute: AVAudioSessionRouteDescription = AVAudioSession.sharedInstance().currentRoute

    // Coordinator registers this; manager calls it after interruption recovery.
    var onInterruptionEnded: (() async -> Void)?
    // Called whenever the audio route changes (plug/unplug headphones, BT connect).
    var onRouteChanged: ((AVAudioSession.RouteChangeReason) -> Void)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // MARK: - Session activation

    func activate(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(category, mode: mode, options: options)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        state = .active
        currentRoute = session.currentRoute
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        state = .idle
    }

    // MARK: - Notification registration

    func startObserving() {
        guard observers.isEmpty else { return }

        let interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleInterruption(note)
            }
        }

        let routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(note)
            }
        }

        let silenceObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleSilenceHint(note)
            }
        }

        observers = [interruptionObserver, routeObserver, silenceObserver]
    }

    func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        onInterruptionEnded = nil
        onRouteChanged = nil
    }

    // MARK: - Interruption handling

    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            state = .interrupted

        case .ended:
            let opts = AVAudioSession.InterruptionOptions(
                rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            guard opts.contains(.shouldResume) else { return }
            Task {
                do {
                    try AVAudioSession.sharedInstance().setActive(
                        true,
                        options: .notifyOthersOnDeactivation
                    )
                    state = .active
                    await onInterruptionEnded?()
                } catch {
                    state = .failed(error.localizedDescription)
                }
            }

        @unknown default:
            break
        }
    }

    // MARK: - Route change handling

    private func handleRouteChange(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        currentRoute = AVAudioSession.sharedInstance().currentRoute
        onRouteChanged?(reason)
    }

    // MARK: - Silence secondary audio

    private func handleSilenceHint(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
            let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeValue)
        else { return }

        // When the system signals our secondary audio should be silenced,
        // respect it — don't fight for the session.
        if type == .begin { state = .interrupted }
    }

    // MARK: - Route helpers

    var hasBluetoothInput: Bool {
        let inputs = AVAudioSession.sharedInstance().availableInputs ?? []
        return inputs.contains {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
        }
    }

    var currentInputPort: AVAudioSession.Port? {
        currentRoute.inputs.first?.portType
    }

    var isUsingBluetoothOutput: Bool {
        currentRoute.outputs.contains {
            $0.portType == .bluetoothA2DP ||
            $0.portType == .bluetoothHFP ||
            $0.portType == .bluetoothLE
        }
    }

    var isUsingHeadphones: Bool {
        currentRoute.outputs.contains {
            $0.portType == .headphones
        }
    }
}

// MARK: - Session configuration presets
//
// Three contexts need different session behavior. All use .playAndRecord
// so that call audio is NOT interrupted. The difference is in mode/options.

extension AudioSessionManager {
    private static var bluetoothHandsFreeOption: AVAudioSession.CategoryOptions {
        #if compiler(>=6.2)
        .allowBluetoothHFP
        #else
        .allowBluetooth
        #endif
    }

    // Live meeting — microphone capture in a quiet room.
    // .measurement prevents system noise-reduction from degrading the signal.
    // .defaultToSpeaker sends playback to speaker but crucially does NOT
    // switch the mic route — the input node still reads from the selected input.
    func configureForLiveMeeting() throws {
        try activate(
            category: .playAndRecord,
            mode: .measurement,
            options: [
                .allowBluetoothA2DP,   // AirPods, stereo BT
                Self.bluetoothHandsFreeOption,
                .defaultToSpeaker,
                .mixWithOthers         // don't kill music or phone call audio
            ]
        )
    }

    // Quick voice note — user captures a short personal note.
    // .playAndRecord (not .record) keeps ambient playback alive.
    // .mixWithOthers prevents silencing podcasts/music during a short note.
    func configureForVoiceNote() throws {
        try activate(
            category: .playAndRecord,
            mode: .measurement,
            options: [
                .allowBluetoothA2DP,
                Self.bluetoothHandsFreeOption,
                .mixWithOthers
            ]
        )
    }
}
