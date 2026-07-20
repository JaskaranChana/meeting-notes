import SwiftUI
import AVFoundation
import Speech

// MARK: - MicTestCoordinator
//
// 5-second mic test. Activates the session via AudioSessionManager,
// installs a tap, computes RMS for live level, and reports a
// pass/fail signal based on whether real audio was detected.

@MainActor
@Observable
final class MicTestCoordinator {
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case denied
        case recording(secondsRemaining: Int)
        case complete(detectedSignal: Bool, peakLevel: Double)
        case failed(String)
    }

    var phase: Phase = .idle
    var inputLevel: Double = 0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var peakLevel: Double = 0
    @ObservationIgnored private var sampleCount = 0
    @ObservationIgnored private var positiveSamples = 0
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    func runTest() async {
        guard !isRunning else { return }
        peakLevel = 0
        sampleCount = 0
        positiveSamples = 0
        inputLevel = 0

        phase = .requestingPermission
        guard await ensurePermissions() else {
            phase = .denied
            return
        }

        do {
            try AudioSessionManager.shared.configureForVoiceNote()

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.processBuffer(buffer)
            }

            engine.prepare()
            try engine.start()

            phase = .recording(secondsRemaining: 5)
            countdownTask = Task { [weak self] in
                guard let self else { return }
                for remaining in stride(from: 5, through: 1, by: -1) {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                    if case .recording = self.phase {
                        self.phase = .recording(secondsRemaining: remaining - 1)
                    }
                }
                if !Task.isCancelled { self.finish() }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            cleanup()
        }
    }

    func cancel() {
        countdownTask?.cancel()
        countdownTask = nil
        cleanup()
        phase = .idle
        inputLevel = 0
    }

    private var isRunning: Bool {
        if case .recording = phase { return true }
        if case .requestingPermission = phase { return true }
        return false
    }

    private func finish() {
        cleanup()
        // Heuristic: detected real signal if peak passed a noise floor and at least
        // 8% of buffers contained non-silence. Catches a muted/blocked mic.
        let ratio = sampleCount > 0 ? Double(positiveSamples) / Double(sampleCount) : 0
        let detected = peakLevel > 0.05 && ratio > 0.08
        phase = .complete(detectedSignal: detected, peakLevel: peakLevel)
        inputLevel = 0
    }

    private func cleanup() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        AudioSessionManager.shared.deactivate()
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sumSquares: Float = 0
        let channel = data[0]
        for i in 0..<frames {
            let s = channel[i]
            sumSquares += s * s
        }
        let rms = sqrt(sumSquares / Float(frames))
        let normalized = min(max(Double(rms) * 12, 0), 1)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.inputLevel = normalized
            if normalized > self.peakLevel { self.peakLevel = normalized }
            self.sampleCount += 1
            if normalized > 0.04 { self.positiveSamples += 1 }
        }
    }

    private func ensurePermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
        return speechStatus == .authorized && micGranted
    }
}

// MARK: - MicLevelMeter
//
// Animated 5-bar level meter that responds to a 0...1 amplitude.
// Each bar reacts to its own threshold so the visualization
// doesn't all jump together — it builds height like real audio.

struct MicLevelMeter: View {
    let level: Double
    var color: Color = AppPalette.accent
    var bars: Int = 14
    var maxHeight: CGFloat = 56

    var body: some View {
        let safeBars = max(1, bars)
        let barWidth: CGFloat = 4
        let spacing: CGFloat = 4
        let meterWidth = CGFloat(safeBars) * barWidth + CGFloat(safeBars - 1) * spacing

        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            for i in 0..<safeBars {
                let threshold = Double(i + 1) / Double(safeBars)
                let isActive = level >= threshold * 0.65
                let height = barHeight(for: i, barCount: safeBars)
                let rect = CGRect(
                    x: CGFloat(i) * (barWidth + spacing),
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                var path = Path()
                path.addRoundedRect(
                    in: rect,
                    cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2)
                )
                context.fill(path, with: .color(isActive ? color : color.opacity(0.16)))
            }
        }
        .frame(width: meterWidth, height: maxHeight)
        .accessibilityHidden(true)
    }

    private func barHeight(for i: Int, barCount: Int) -> CGFloat {
        let mid = max(1, Double(barCount - 1) / 2)
        let distFromCenter = abs(Double(i) - mid)
        let envelope = 1.0 - (distFromCenter / mid) * 0.55  // taller in middle
        let base = 6.0 + level * Double(maxHeight) * envelope
        let jitter = sin(Double(i) * 1.7 + level * 11) * 4 * level
        return CGFloat(min(maxHeight, max(6, base + jitter)))
    }
}

// MARK: - AudioRouteBadge

struct AudioRouteBadge: View {
    let route: AVAudioSessionRouteDescription
    let usingBluetooth: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryInk)
                Text(routeName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppPalette.cardBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.6), lineWidth: 0.8))
    }

    private var icon: String {
        if usingBluetooth { return "airpods" }
        if route.outputs.contains(where: { $0.portType == .headphones }) { return "headphones" }
        if route.outputs.contains(where: { $0.portType == .builtInSpeaker }) { return "speaker.wave.2.fill" }
        return "mic.fill"
    }

    private var label: String { usingBluetooth ? "Bluetooth" : "Active route" }

    private var routeName: String {
        route.inputs.first?.portName ?? route.outputs.first?.portName ?? "Built-in"
    }
}

// MARK: - AudioDiagnosticsView

struct AudioDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = MicTestCoordinator()
    @State private var micPermission: Bool = false
    @State private var speechPermission: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @State private var route = AVAudioSession.sharedInstance().currentRoute
    @State private var hasAnimatedIn = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    headerCard
                        .motionEntrance(step: 0, active: hasAnimatedIn)
                    micTestCard
                        .motionEntrance(step: 1, active: hasAnimatedIn)
                    permissionsCard
                        .motionEntrance(step: 2, active: hasAnimatedIn)
                    routeCard
                        .motionEntrance(step: 3, active: hasAnimatedIn)
                    iosLimitationsCard
                        .motionEntrance(step: 4, active: hasAnimatedIn)
                }
                .appScreenContent(top: AppSpacing.lg)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Microphone & audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { coordinator.cancel(); dismiss() }
                        .tint(AppPalette.ink)
                }
            }
            .onAppear {
                hasAnimatedIn = true
                refreshPermissions()
                refreshRoute()
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
                refreshRoute()
            }
        }
        .modifier(ScribeflowChrome())
    }

    // MARK: header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.title3.weight(.medium))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 40, height: 40)
                .background(AppPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text("Verify your setup")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(AppPalette.ink)
            Text("Run a 5-second mic test, check permissions, and confirm the active audio route.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous).strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5))
        .appShadow(AppShadow.soft)
        .cardAppearGlow()
    }

    // MARK: mic test

    private var micTestCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("MIC TEST")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppPalette.tertiaryInk)
                Spacer()
                phaseBadge
            }

            // Visualization area
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(AppPalette.softSurface.opacity(0.55))
                MicLevelMeter(level: coordinator.inputLevel, color: meterColor, bars: 18, maxHeight: 64)
                    .padding(.horizontal, 24)
            }
            .frame(height: 100)

            phaseDescription
                .frame(maxWidth: .infinity, alignment: .leading)

            actionButton
        }
        .padding(18)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5))
        .appShadow(AppShadow.hairline)
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch coordinator.phase {
        case .idle:
            tag("Ready", color: AppPalette.accent)
        case .requestingPermission:
            tag("Permissions…", color: AppPalette.gold)
        case .denied:
            tag("Blocked", color: AppPalette.coral)
        case .recording(let s):
            tag("\(s)s", color: AppPalette.accent)
        case .complete(let detected, _):
            tag(detected ? "Mic OK" : "No signal", color: detected ? AppPalette.success : AppPalette.coral)
        case .failed:
            tag("Error", color: AppPalette.coral)
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private var phaseDescription: some View {
        switch coordinator.phase {
        case .idle:
            Text("Tap **Run mic test** and speak normally for 5 seconds. We'll confirm Scribeflow is hearing you.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
        case .requestingPermission:
            Text("Asking iOS for microphone and speech access…")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
        case .denied:
            Text("Microphone or speech recognition is blocked in Settings. Open Settings → Scribeflow to grant access.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.coral)
        case .recording:
            Text("Listening… speak now.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.ink)
        case .complete(let detected, let peak):
            VStack(alignment: .leading, spacing: 4) {
                Text(detected ? "Looks good." : "We didn't hear much.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(detected ? AppPalette.success : AppPalette.coral)
                Text(detected
                     ? "Peak level \(Int(peak * 100))%. You're ready to capture."
                     : "Peak level \(Int(peak * 100))%. Check your input device or move closer to the mic.")
                .font(.footnote)
                .foregroundStyle(AppPalette.secondaryInk)
            }
        case .failed(let msg):
            Text("Test failed: \(msg)")
                .font(.subheadline)
                .foregroundStyle(AppPalette.coral)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch coordinator.phase {
        case .recording:
            Button {
                HapticEngine.tap(.light)
                coordinator.cancel()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppPalette.coral, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.97))
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gearshape")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppPalette.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.97))
        default:
            Button {
                HapticEngine.tap(.medium)
                Task { await coordinator.runTest() }
            } label: {
                Label(retestLabel, systemImage: "mic.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.97))
        }
    }

    private var retestLabel: String {
        if case .complete = coordinator.phase { return "Run again" }
        if case .failed = coordinator.phase { return "Try again" }
        return "Run mic test"
    }

    private var meterColor: Color {
        switch coordinator.phase {
        case .recording: return AppPalette.accent
        case .complete(let detected, _): return detected ? .green : AppPalette.coral
        case .denied, .failed: return AppPalette.coral
        default: return AppPalette.accent
        }
    }

    // MARK: permissions

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PERMISSIONS")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.secondaryInk)

            permRow(icon: "mic.fill", label: "Microphone",
                    granted: micPermission, hint: "Required to capture audio")
            Divider().padding(.leading, 38)
            permRow(icon: "waveform", label: "Speech recognition",
                    granted: speechPermission == .authorized,
                    hint: "Powers live transcript")

            if !micPermission || speechPermission != .authorized {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open Settings →")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(18)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(AppPalette.border.opacity(0.6)))
    }

    private func permRow(icon: String, label: String, granted: Bool, hint: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(granted ? AppPalette.accent : AppPalette.secondaryInk.opacity(0.55))
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(AppPalette.ink)
                Text(hint).font(.caption).foregroundStyle(AppPalette.secondaryInk)
            }
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(granted ? AppPalette.success : AppPalette.coral.opacity(0.6))
        }
    }

    // MARK: route

    private var routeCard: some View {
        let inputs = route.inputs.map(\.portName)
        let outputs = route.outputs.map(\.portName)
        let usingBT = route.outputs.contains {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
        }

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AUDIO ROUTE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryInk)
                Spacer()
                AudioRouteBadge(route: route, usingBluetooth: usingBT)
            }
            routeRow(label: "Input", values: inputs)
            Divider()
            routeRow(label: "Output", values: outputs)
        }
        .padding(18)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(AppPalette.border.opacity(0.6)))
    }

    private func routeRow(label: String, values: [String]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppPalette.secondaryInk)
                .frame(width: 50, alignment: .leading)
            Text(values.isEmpty ? "—" : values.joined(separator: ", "))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.ink)
            Spacer()
        }
    }

    // MARK: iOS limitations

    private var iosLimitationsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(AppPalette.gold)
                Text("ABOUT FACETIME & PHONE CALLS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryInk)
            }

            Text("iOS does not let any third-party app record the other party's audio during FaceTime or carrier calls — it's a system-level restriction.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Scribeflow captures **your microphone** during calls. **Speakerphone** gives the best chance of also picking up the room. AirPods/Bluetooth typically only capture your voice.")
                .font(.footnote)
                .foregroundStyle(AppPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(AppPalette.gold.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(AppPalette.gold.opacity(0.18), lineWidth: 0.8))
    }

    // MARK: helpers

    private func refreshPermissions() {
        speechPermission = SFSpeechRecognizer.authorizationStatus()
        if #available(iOS 17.0, *) {
            micPermission = AVAudioApplication.shared.recordPermission == .granted
        } else {
            micPermission = AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    private func refreshRoute() {
        route = AVAudioSession.sharedInstance().currentRoute
    }
}
