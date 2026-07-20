import AVFoundation
import SwiftUI

struct AudioPlaybackControls: View {
    let url: URL
    let durationSeconds: Int

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var timer: Timer?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(isPlaying ? AppPalette.coral : AppPalette.accent, in: Circle())
                        .appTapTarget()
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.92))
                .accessibilityLabel(isPlaying ? "Pause recording" : "Play recording")

                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .tint(AppPalette.accent)
                    HStack {
                        Text(currentTimeLabel)
                        Spacer()
                        Text(durationLabel)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryInk)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(AppPalette.coral)
            }
        }
        .onDisappear {
            stopTimer()
            player?.stop()
            isPlaying = false
        }
    }

    private var currentTimeLabel: String {
        let current = Int(round((player?.currentTime ?? 0)))
        return format(seconds: current)
    }

    private var durationLabel: String {
        format(seconds: durationSeconds)
    }

    private func togglePlayback() {
        do {
            if player == nil {
                player = try AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
            }

            guard let player else { return }
            if isPlaying {
                player.pause()
                isPlaying = false
                stopTimer()
            } else {
                player.play()
                isPlaying = true
                startTimer()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Audio file could not be opened."
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            guard let player else { return }
            if player.duration > 0 {
                progress = min(max(player.currentTime / player.duration, 0), 1)
            }
            if !player.isPlaying {
                isPlaying = false
                stopTimer()
                if progress >= 0.98 {
                    player.currentTime = 0
                    progress = 0
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func format(seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
