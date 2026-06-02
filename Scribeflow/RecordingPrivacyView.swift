import SwiftUI

struct RecordingPrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hasAnimatedIn = false

    private let items: [(icon: String, title: String, body: String, tint: Color)] = [
        ("waveform.badge.mic", "Voice notes", RecordingCompliance.localAudioStorage, AppPalette.accent),
        ("text.bubble.fill", "Transcription", RecordingCompliance.speechRecognition, AppPalette.gold),
        ("phone.badge.waveform", "Phone calls", "\(RecordingCompliance.restrictedCallRecordingNotice) \(RecordingCompliance.providerCallRequirement)", AppPalette.coral),
        ("lock.shield.fill", "Privacy stance", RecordingCompliance.releasePrivacySummary, AppPalette.success),
    ]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .motionEntrance(step: 0, active: hasAnimatedIn)
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 28)

                    HStack(alignment: .top, spacing: 0) {
                        timelineRail
                            .padding(.leading, 36)

                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                                timelineItem(
                                    icon: item.icon,
                                    title: item.title,
                                    body: item.body,
                                    tint: item.tint,
                                    step: idx
                                )
                                .motionEntrance(step: idx + 1, active: hasAnimatedIn)
                            }
                        }
                        .padding(.leading, 22)
                        .padding(.trailing, 20)
                    }

                    footer
                        .motionEntrance(step: 5, active: hasAnimatedIn)
                        .padding(.horizontal, 20)
                        .padding(.top, 32)
                        .padding(.bottom, 40)
                }
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Recording privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .tint(AppPalette.ink)
                }
            }
            .onAppear { hasAnimatedIn = true }
        }
        .modifier(ScribeflowChrome())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOW YOUR DATA IS PROTECTED")
                .font(.caption2.weight(.medium))
                .kerning(0.6)
                .foregroundStyle(AppPalette.tertiaryInk)
            Text("Clear limits, safer recordings")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(AppPalette.ink)
            Text("Scribeflow is designed around App Store-safe recording behavior and clear user consent.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryInk)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timelineRail: some View {
        VStack(spacing: 0) {
            ForEach(0..<items.count, id: \.self) { idx in
                Circle()
                    .fill(items[idx].tint.opacity(0.15))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().fill(items[idx].tint).frame(width: 4, height: 4))
                if idx < items.count - 1 {
                    Rectangle()
                        .fill(AppPalette.border.opacity(0.30))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(width: 10)
    }

    private func timelineItem(icon: String, title: String, body: String, tint: Color, step: Int) -> some View {
        DisclosureGroup {
            Text(body)
                .font(.footnote)
                .foregroundStyle(AppPalette.secondaryInk)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
            }
        }
        .tint(AppPalette.tertiaryInk)
        .padding(16)
        .background(AppPalette.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AppPalette.border.opacity(0.25), lineWidth: 0.5))
        .appShadow(AppShadow.hairline)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppPalette.success)
            Text("Your data never leaves this device unless you choose to export or share it.")
                .font(.system(.caption, design: .serif))
                .foregroundStyle(AppPalette.tertiaryInk)
                .lineSpacing(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppPalette.success.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
