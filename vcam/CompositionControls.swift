import SwiftUI

/// Preview-only controls. Only each 20-point divider strip receives pointer input.
struct CompositionDivider: View {
    let layout: CaptureLayout
    let outputSize: CGSize
    @Binding var splitRatio: Double
    @Binding var secondSplitRatio: Double
    let splitRatioRange: ClosedRange<Double>
    let secondSplitRatioRange: ClosedRange<Double>
    var isEnabled: Bool = true

    var body: some View {
        if layout.regionCount > 1 {
            GeometryReader { geometry in
                let regions = previewRegions(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    ForEach(regions.indices, id: \.self) { index in
                        regionBadge(["A", "B", "C"][index], in: regions[index])
                    }
                    CompositionBoundary(
                        ratio: $splitRatio, range: splitRatioRange,
                        position: regions[0].maxY, size: geometry.size,
                        label: layout.regionCount == 3 ? "Top composition split" : "Composition split",
                        detail: "Boundary between regions A and B", isEnabled: isEnabled)
                    if layout.regionCount == 3 {
                        CompositionBoundary(
                            ratio: $secondSplitRatio, range: secondSplitRatioRange,
                            position: regions[1].maxY, size: geometry.size,
                            label: "Bottom composition split",
                            detail: "Boundary between regions B and C", isEnabled: isEnabled)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            // A new layout has different gesture origins and boundary identities.
            .id(layout)
        }
    }

    private func previewRegions(in size: CGSize) -> [CGRect] {
        let scaleX = size.width / max(outputSize.width, 1)
        let scaleY = size.height / max(outputSize.height, 1)
        return layout.destinationRects(in: outputSize, splitRatio: splitRatio,
                                       secondSplitRatio: secondSplitRatio).map {
            CGRect(x: $0.minX * scaleX, y: (outputSize.height - $0.maxY) * scaleY,
                   width: $0.width * scaleX, height: $0.height * scaleY)
        }
    }

    private func regionBadge(_ label: String, in region: CGRect) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
            .position(x: region.minX + min(18, region.width / 2),
                      y: region.minY + min(18, region.height / 2))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct CompositionBoundary: View {
    @Binding var ratio: Double
    let range: ClosedRange<Double>
    let position: CGFloat
    let size: CGSize
    let label: String
    let detail: String
    let isEnabled: Bool
    @GestureState private var dragOrigin: DragOrigin?
    @State private var isHovering = false

    private struct DragOrigin {
        let ratio: Double
        let extent: CGFloat
    }

    private var valueDescription: String { "\(Int((ratio * 100).rounded())) percent from the top" }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.72))
                .frame(width: size.width, height: 1)
                .shadow(color: .black.opacity(0.65), radius: 1)
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                .frame(width: 36, height: 18)
                .overlay {
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
        }
        .frame(width: size.width, height: 20)
        .contentShape(Rectangle())
        .opacity(isEnabled ? (isHovering || dragOrigin != nil ? 1 : 0.8) : 0.3)
        .gesture(dragGesture)
        .onHover { isHovering = $0 }
        .help("\(detail). Drag up or down to resize the panels. Every panel keeps at least 15% of the video. This guide is not recorded.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueDescription)
        .accessibilityHint(detail)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: ratio = bounded(ratio + 0.05)
            case .decrement: ratio = bounded(ratio - 0.05)
            @unknown default: break
            }
        }
        .disabled(!isEnabled)
        .allowsHitTesting(isEnabled)
        .position(x: size.width / 2, y: position)
    }

    private var dragGesture: some Gesture {
        // A fixed global coordinate space keeps translations stable as the
        // divider moves. Each divider owns its own initial ratio and extent.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($dragOrigin) { _, origin, _ in
                if origin == nil { origin = DragOrigin(ratio: ratio, extent: size.height) }
            }
            .onChanged { value in
                guard isEnabled else { return }
                let origin = dragOrigin ?? DragOrigin(ratio: ratio, extent: size.height)
                guard origin.extent > 0 else { return }
                ratio = bounded(origin.ratio + Double(value.translation.height / origin.extent))
            }
    }

    private func bounded(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

struct CompositionLayoutPicker: View {
    @Binding var selection: CaptureLayout
    var isEnabled: Bool = true

    var body: some View {
        Picker("Composition layout", selection: $selection) {
            Text("Single").tag(CaptureLayout.single)
            Text("2 stacked").tag(CaptureLayout.stacked)
            Text("3 stacked").tag(CaptureLayout.stackedThree)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!isEnabled)
    }
}
