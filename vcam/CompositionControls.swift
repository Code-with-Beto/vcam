import SwiftUI

/// A preview-only divider. Place this over a preview whose bounds match the
/// output aspect ratio; only the 20-point divider strip receives pointer input.
struct CompositionDivider: View {
    let layout: CaptureLayout
    @Binding var splitRatio: Double
    var isEnabled: Bool = true

    @GestureState private var dragOrigin: DragOrigin?
    @State private var isHovering = false

    private struct DragOrigin {
        let ratio: Double
        let extent: CGFloat
        let isSideBySide: Bool
    }

    @Namespace private var dragSpace

    private var isSideBySide: Bool {
        if case .sideBySide = layout { return true }
        return false
    }

    private var ratio: Double { bounded(splitRatio) }
    private var percentage: Int { Int((ratio * 100).rounded()) }
    private var valueDescription: String {
        "Region A \(percentage) percent \(isSideBySide ? "left" : "top"), "
            + "region B \(100 - percentage) percent \(isSideBySide ? "right" : "bottom")"
    }

    var body: some View {
        if case .single = layout {
            EmptyView()
        } else {
            GeometryReader { geometry in
                let size = geometry.size
                let first = firstRegion(in: size)
                let second = secondRegion(in: size)
                ZStack(alignment: .topLeading) {
                    regionBadge("A", in: first)
                    regionBadge("B", in: second)
                    divider(in: size)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .coordinateSpace(name: dragSpace)
            }
        }
    }

    private func divider(in size: CGSize) -> some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.72))
                .frame(width: isSideBySide ? 1 : size.width, height: isSideBySide ? size.height : 1)
                .shadow(color: .black.opacity(0.65), radius: 1)
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                .frame(width: isSideBySide ? 18 : 36, height: isSideBySide ? 36 : 18)
                .overlay {
                    Image(systemName: isSideBySide ? "arrow.left.and.right" : "arrow.up.and.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
        }
        .frame(width: isSideBySide ? 20 : size.width, height: isSideBySide ? size.height : 20)
        .contentShape(Rectangle())
        .opacity(isEnabled ? (isHovering || dragOrigin != nil ? 1 : 0.8) : 0.45)
        .gesture(dragGesture(in: size))
        .onHover { isHovering = $0 }
        .help("\(valueDescription). Drag \(isSideBySide ? "left or right" : "up or down") to resize the regions. This guide is not recorded.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Composition split")
        .accessibilityValue(valueDescription)
        .accessibilityHint("Adjust the share of the video assigned to region A.")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: splitRatio = bounded(ratio + 0.05)
            case .decrement: splitRatio = bounded(ratio - 0.05)
            @unknown default: break
            }
        }
        .disabled(!isEnabled)
        .allowsHitTesting(isEnabled)
        .position(x: isSideBySide ? size.width * ratio : size.width / 2,
                  y: isSideBySide ? size.height / 2 : size.height * ratio)
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(dragSpace))
            .updating($dragOrigin) { _, origin, _ in
                if origin == nil {
                    origin = DragOrigin(ratio: ratio,
                        extent: isSideBySide ? size.width : size.height,
                        isSideBySide: isSideBySide)
                }
            }
            .onChanged { value in
                guard isEnabled else { return }
                let origin = dragOrigin ?? DragOrigin(ratio: ratio,
                    extent: isSideBySide ? size.width : size.height,
                    isSideBySide: isSideBySide)
                guard origin.extent > 0, origin.isSideBySide == isSideBySide else { return }
                // Preserve the pointer's offset within the hit strip. Translating
                // from the initial ratio avoids a jump on click or cumulative drift.
                let distance = isSideBySide ? value.translation.width : value.translation.height
                splitRatio = bounded(origin.ratio + Double(distance / origin.extent))
            }
        // GestureState clears the origin on completion or cancellation.
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

    private func firstRegion(in size: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: isSideBySide ? size.width * ratio : size.width,
               height: isSideBySide ? size.height : size.height * ratio)
    }

    private func secondRegion(in size: CGSize) -> CGRect {
        let first = firstRegion(in: size)
        return isSideBySide
            ? CGRect(x: first.maxX, y: 0, width: size.width - first.width, height: size.height)
            : CGRect(x: 0, y: first.maxY, width: size.width, height: size.height - first.height)
    }

    private func bounded(_ value: Double) -> Double {
        CaptureLayout.clampedSplitRatio(value)
    }
}

/// Optional standalone picker for settings; all state remains with its owner.
struct CompositionLayoutPicker: View {
    @Binding var selection: CaptureLayout
    var isEnabled: Bool = true

    var body: some View {
        Picker("Composition layout", selection: $selection) {
            Text(CaptureLayout.single.title).tag(CaptureLayout.single)
            Text(CaptureLayout.sideBySide.title).tag(CaptureLayout.sideBySide)
            Text(CaptureLayout.stacked.title).tag(CaptureLayout.stacked)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!isEnabled)
    }
}
