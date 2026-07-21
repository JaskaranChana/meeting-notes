import SwiftUI

// MARK: - Shimmer

private struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay(shimmerLayer)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }

    private var shimmerLayer: some View {
        GeometryReader { geo in
            if !reduceMotion {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: shimmerTint, location: 0.45),
                        .init(color: shimmerTint, location: 0.55),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 2.5)
                .offset(x: phase * geo.size.width * 1.75)
                .allowsHitTesting(false)
            }
        }
        .clipped()
    }

    private var shimmerTint: Color {
        Color.white.opacity(colorScheme == .dark ? 0.16 : 0.52)
    }
}

extension View {
    func shimmer() -> some View { modifier(ShimmerModifier()) }
}

// MARK: - SkeletonRow

struct SkeletonRow: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 7

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(AppPalette.softSurface)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .shimmer()
    }
}

// MARK: - SkeletonBlock  (multi-line text placeholder)

struct SkeletonBlock: View {
    var lines: Int = 3
    var height: CGFloat = 13
    var spacing: CGFloat = 8
    var lastLineFraction: CGFloat = 0.55

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(0..<lines, id: \.self) { i in
                    SkeletonRow(
                        width: i == lines - 1 ? geo.size.width * lastLineFraction : nil,
                        height: height
                    )
                }
            }
        }
        .frame(height: CGFloat(lines) * height + CGFloat(lines - 1) * spacing)
    }
}
