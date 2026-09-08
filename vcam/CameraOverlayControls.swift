import SwiftUI

/// Interaction only: the capture pipeline already draws the camera in preview.
/// Place over the exact output aspect ratio; everything outside the bubble and
/// its resize handle passes pointer input through to the composition controls.
struct CameraOverlayControls: View {
    @Binding var configuration: CameraOverlayConfiguration
    let outputSize: CGSize
    var isEnabled: Bool = true

    @Namespace private var interactionSpace
    @GestureState private var moveOrigin: InteractionOrigin?
    @GestureState private var resizeOrigin: InteractionOrigin?
    @State private var hoveringCamera = false
    @State private var hoveringHandle = false

    private struct InteractionOrigin {
        let configuration: CameraOverlayConfiguration
        let previewSize: CGSize
        let outputSize: CGSize
    }

    private var showsControls: Bool {
        isEnabled && (hoveringCamera || hoveringHandle || moveOrigin != nil || resizeOrigin != nil)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if size.width > 0, size.height > 0, outputSize.width > 0, outputSize.height > 0 {
                let rect = previewRect(configuration, in: size)
                ZStack(alignment: .topLeading) {
                    cameraHitArea(in: rect, previewSize: size)
                    resizeHandle(in: rect, previewSize: size)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .coordinateSpace(name: interactionSpace)
            }
        }
        .allowsHitTesting(isEnabled)
        .disabled(!isEnabled)
    }

    private func cameraHitArea(in rect: CGRect, previewSize: CGSize) -> some View {
        let shape = CameraControlShape(shape: configuration.shape)
        return shape.fill(.clear)
            .overlay {
                shape.stroke(.white.opacity(showsControls ? 0.95 : 0), lineWidth: 1.5)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .allowsHitTesting(false)
            }
            .frame(width: rect.width, height: rect.height)
            .contentShape(shape)
            .gesture(moveGesture(in: previewSize))
            .onHover { hoveringCamera = $0 }
            .help("Drag to move the camera. Its position is saved in the video.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Camera position")
            .accessibilityValue(positionDescription + ", size " + sizeDescription)
            .accessibilityHint("Adjust to resize, or use the move actions to reposition the camera.")
            .accessibilityAdjustableAction { adjustSize($0) }
            .accessibilityAction(named: Text("Move left")) { moveBy(x: -0.025, y: 0) }
            .accessibilityAction(named: Text("Move right")) { moveBy(x: 0.025, y: 0) }
            .accessibilityAction(named: Text("Move up")) { moveBy(x: 0, y: -0.025) }
            .accessibilityAction(named: Text("Move down")) { moveBy(x: 0, y: 0.025) }
            .position(x: rect.midX, y: rect.midY)
    }

    private func resizeHandle(in rect: CGRect, previewSize: CGSize) -> some View {
        let point = handlePoint(in: rect, shape: configuration.shape)
        return Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 16, height: 16)
            .background(.white, in: Circle())
            .shadow(color: .black.opacity(0.5), radius: 2)
            .padding(4)
            .contentShape(Circle())
            .opacity(showsControls ? 1 : 0)
            .gesture(resizeGesture(in: previewSize))
            .onHover { hoveringHandle = $0 }
            .help("Drag to resize the camera. \(sizeDescription).")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Camera size")
            .accessibilityValue(sizeDescription)
            .accessibilityAdjustableAction { adjustSize($0) }
            .position(point)
    }

    private func moveGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(interactionSpace))
            .updating($moveOrigin) { _, origin, _ in
                if origin == nil { origin = interactionOrigin(in: size) }
            }
            .onChanged { event in
                guard isEnabled else { return }
                let origin = moveOrigin ?? interactionOrigin(in: size)
                guard origin.outputSize == outputSize else { return }
                var value = origin.configuration
                // Translation is measured in a stable parent coordinate space,
                // preserving the pointer's original offset inside the bubble.
                value.center.x += event.translation.width / origin.previewSize.width
                value.center.y += event.translation.height / origin.previewSize.height
                configuration = value.clamped(in: outputSize)
            }
    }

    private func resizeGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(interactionSpace))
            .updating($resizeOrigin) { _, origin, _ in
                if origin == nil { origin = interactionOrigin(in: size) }
            }
            .onChanged { event in
                guard isEnabled else { return }
                let origin = resizeOrigin ?? interactionOrigin(in: size)
                guard origin.outputSize == outputSize else { return }
                let rect = previewRect(origin.configuration, in: origin.previewSize)
                let handle = handlePoint(in: rect, shape: origin.configuration.shape)
                // Project pointer travel onto the corner's growth direction.
                // This handles circles and 4:3 rectangles without sudden jumps,
                // and holds the original center until canvas clamping is needed.
                let dx = (handle.x - rect.midX) / origin.configuration.widthFraction
                let dy = (handle.y - rect.midY) / origin.configuration.widthFraction
                let squaredLength = dx * dx + dy * dy
                guard squaredLength > 0 else { return }
                var value = origin.configuration
                value.widthFraction += (event.translation.width * dx + event.translation.height * dy) / squaredLength
                configuration = value.clamped(in: outputSize)
            }
    }

    private func interactionOrigin(in previewSize: CGSize) -> InteractionOrigin {
        InteractionOrigin(configuration: configuration.clamped(in: outputSize),
                          previewSize: previewSize, outputSize: outputSize)
    }

    private func previewRect(_ value: CameraOverlayConfiguration, in size: CGSize) -> CGRect {
        let pixels = value.rect(in: outputSize)
        return CGRect(x: pixels.minX / outputSize.width * size.width,
                      y: (outputSize.height - pixels.maxY) / outputSize.height * size.height,
                      width: pixels.width / outputSize.width * size.width,
                      height: pixels.height / outputSize.height * size.height)
    }

    /// Put the affordance on the visible lower-right edge, including on a circle.
    private func handlePoint(in rect: CGRect, shape: CameraShape) -> CGPoint {
        let diagonal = sqrt(0.5)
        if shape == .circle {
            return CGPoint(x: rect.midX + rect.width / 2 * diagonal,
                           y: rect.midY + rect.height / 2 * diagonal)
        }
        let radius = rect.height * 0.14
        return CGPoint(x: rect.maxX - radius * (1 - diagonal),
                       y: rect.maxY - radius * (1 - diagonal))
    }

    private func moveBy(x: CGFloat, y: CGFloat) {
        guard isEnabled else { return }
        var value = configuration
        value.center.x += x
        value.center.y += y
        configuration = value.clamped(in: outputSize)
    }

    private func adjustSize(_ direction: AccessibilityAdjustmentDirection) {
        guard isEnabled else { return }
        var value = configuration
        switch direction {
        case .increment: value.widthFraction += 0.025
        case .decrement: value.widthFraction -= 0.025
        @unknown default: return
        }
        configuration = value.clamped(in: outputSize)
    }

    private var positionDescription: String {
        let center = configuration.clamped(in: outputSize).center
        return "\(Int((center.x * 100).rounded())) percent from left, \(Int((center.y * 100).rounded())) percent from top"
    }

    private var sizeDescription: String {
        "\(Int((configuration.widthFraction * 100).rounded())) percent of the shorter output dimension"
    }
}

private struct CameraControlShape: Shape {
    let shape: CameraShape

    func path(in rect: CGRect) -> Path {
        if shape == .circle { return Ellipse().path(in: rect) }
        // Match the capture compositor's rounded-rectangle mask.
        return RoundedRectangle(cornerRadius: rect.height * 0.14, style: .circular).path(in: rect)
    }
}
