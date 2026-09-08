import SwiftUI

/// A guide for the complete output canvas, independent of its source panels.
/// It sits above the native preview and is never part of an encoded frame.
struct SafeAreaPreviewGuide: View {
    var reservesCaptions: Bool

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let content = SafeAreaGuide.contentRect(
                in: bounds,
                bottomInset: reservesCaptions ? SafeAreaGuide.captionBottomInset : SafeAreaGuide.edgeInset)
            // SafeAreaGuide uses bottom-left coordinates; SwiftUI uses top-left.
            let inner = CGRect(x: content.minX, y: bounds.height - content.maxY,
                               width: content.width, height: content.height)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    var bands = Path(bounds)
                    bands.addRect(inner)
                    context.fill(bands, with: .color(.black.opacity(0.17)),
                                 style: FillStyle(eoFill: true))
                    let outline = Path(roundedRect: inner, cornerRadius: 2)
                    context.stroke(outline, with: .color(.black.opacity(0.32)),
                                   style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    context.stroke(outline, with: .color(.white.opacity(0.68)),
                                   style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
                if reservesCaptions {
                    Text("Caption space")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: Capsule())
                        .position(x: bounds.midX,
                                  y: inner.maxY + (bounds.maxY - inner.maxY) / 2)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
