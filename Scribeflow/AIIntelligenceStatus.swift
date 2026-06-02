import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - AI intelligence status (honest tier signalling)

/// App-wide, honest read of whether on-device Apple Intelligence is actually
/// available. When it isn't, summaries and "Ask" silently fall back to keyword
/// heuristics — the UI uses this to tell the user plainly which mode they're in
/// instead of implying every device gets real AI.
enum AIIntelligenceStatus: Equatable {
    /// Apple Intelligence is ready — answers and rewrites run on-device.
    case onDevice
    /// Falling back to keyword matching. `reason` is a short, human cause.
    case basic(reason: String)

    static var current: AIIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .onDevice
            case .unavailable(let reason):
                return .basic(reason: Self.describe(reason))
            @unknown default:
                return .basic(reason: "Apple Intelligence is unavailable")
            }
        }
        #endif
        return .basic(reason: "needs iOS 26 and Apple Intelligence")
    }

    var isOnDevice: Bool {
        if case .onDevice = self { return true }
        return false
    }

    /// Short chip label.
    var shortLabel: String {
        switch self {
        case .onDevice: "Apple Intelligence"
        case .basic:    "Basic mode"
        }
    }

    /// One-line explanation for badges, footers, and accessibility.
    var detail: String {
        switch self {
        case .onDevice:
            "Answers and rewrites run privately on-device with Apple Intelligence."
        case .basic(let reason):
            "Running on keyword matching — \(reason). Answers are simpler and may miss nuance."
        }
    }

    var systemImage: String {
        switch self {
        case .onDevice: "sparkles"
        case .basic:    "text.magnifyingglass"
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:           return "this device doesn't support Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is off in Settings"
        case .modelNotReady:               return "the model is still downloading"
        @unknown default:                  return "Apple Intelligence is unavailable"
        }
    }
    #endif
}

/// Small honest badge showing whether real on-device AI is in play. Accent when
/// on-device, quiet ink when in basic/keyword mode. Carries the full
/// explanation for VoiceOver.
struct AIModeBadge: View {
    var status: AIIntelligenceStatus = .current

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.systemImage)
                .font(.caption2.weight(.bold))
            Text(status.shortLabel)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(status.isOnDevice ? AppPalette.accent : AppPalette.secondaryInk)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            (status.isOnDevice ? AppPalette.accentSoft : AppPalette.softSurface),
            in: Capsule()
        )
        .overlay(Capsule().strokeBorder(AppPalette.border.opacity(0.5), lineWidth: 0.6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(status.shortLabel). \(status.detail)")
    }
}
