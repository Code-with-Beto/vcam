import SwiftUI

/// Preview-only framing controls. Moving the camera image changes its source
/// crop, while the compositor keeps the destination overlay or panel fixed.
struct CameraCropControls: View {
    @Binding var framing: CameraFramingConfiguration
    let sourceSize: CGSize
    let outputSize: CGSize
    let destination: CGRect
    var shape: CameraShape?
    var isEnabled = true

    @Namespace private var interactionSpace
    @GestureState private var dragOrigin: DragOrigin?

    private struct DragOrigin {
        let framing: CameraFramingConfiguration
        let cropSize: CGSize
        let previewSize: CGSize
        let sourceSize: CGSize
        let destination: CGRect
    }

    var body: some View {
        GeometryReader { geometry in
            if outputSize.width > 0, outputSize.height > 0,
               sourceSize.width > 0, sourceSize.height > 0,
               destination.width > 0, destination.height > 0 {
                let rect = previewRect(in: geometry.size)
                let mask = CameraCropShape(cameraShape: shape)
                mask.fill(.clear)
                    .overlay {
                        mask.stroke(.white.opacity(0.95), lineWidth: 2)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        cropGrid
                            .clipShape(mask)
                            .allowsHitTesting(false)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(mask)
                    .gesture(panGesture(previewSize: rect.size))
                    .help("Drag the image to frame your face. The camera frame stays in place. Use Zoom in Live to crop closer.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Camera crop")
                    .accessibilityValue(String(format: "%.1f times zoom", framing.zoom))
                    .accessibilityHint("Adjust to zoom, or use the image movement actions to frame your face.")
                    .accessibilityAdjustableAction { adjustZoom($0) }
                    .accessibilityAction(named: Text("Move image left")) { moveImage(x: -0.05, y: 0) }
                    .accessibilityAction(named: Text("Move image right")) { moveImage(x: 0.05, y: 0) }
                    .accessibilityAction(named: Text("Move image up")) { moveImage(x: 0, y: -0.05) }
                    .accessibilityAction(named: Text("Move image down")) { moveImage(x: 0, y: 0.05) }
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .coordinateSpace(name: interactionSpace)
        .allowsHitTesting(isEnabled)
        .disabled(!isEnabled)
    }

    private var cropGrid: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
                    let x = geometry.size.width * fraction
                    let y = geometry.size.height * fraction
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .shadow(color: .black.opacity(0.5), radius: 1)
        }
    }

    private func panGesture(previewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(interactionSpace))
            .updating($dragOrigin) { _, origin, _ in
                if origin == nil { origin = makeOrigin(previewSize: previewSize) }
            }
            .onChanged { event in
                guard isEnabled else { return }
                let origin = dragOrigin ?? makeOrigin(previewSize: previewSize)
                guard origin.sourceSize == sourceSize, origin.destination == destination,
                      origin.previewSize.width > 0, origin.previewSize.height > 0 else { return }
                var value = origin.framing
                // The camera is already mirrored by the compositor. Center uses
                // post-mirror coordinates, so the image follows the pointer in
                // either mirror mode. Translation is measured from a stable
                // parent rather than the changing cropped image.
                value.center.x -= event.translation.width / origin.previewSize.width
                    * origin.cropSize.width / origin.sourceSize.width
                value.center.y -= event.translation.height / origin.previewSize.height
                    * origin.cropSize.height / origin.sourceSize.height
                framing = value.centerClamped(in: sourceSize, filling: destination.size)
            }
    }

    private func makeOrigin(previewSize: CGSize) -> DragOrigin {
        let value = framing.centerClamped(in: sourceSize, filling: destination.size)
        return DragOrigin(framing: value,
                          cropSize: value.sourceRect(in: sourceSize, filling: destination.size).size,
                          previewSize: previewSize, sourceSize: sourceSize, destination: destination)
    }

    private func previewRect(in size: CGSize) -> CGRect {
        CGRect(x: destination.minX / outputSize.width * size.width,
               y: (outputSize.height - destination.maxY) / outputSize.height * size.height,
               width: destination.width / outputSize.width * size.width,
               height: destination.height / outputSize.height * size.height)
    }

    private func moveImage(x: CGFloat, y: CGFloat) {
        guard isEnabled else { return }
        var value = framing.centerClamped(in: sourceSize, filling: destination.size)
        let crop = value.sourceRect(in: sourceSize, filling: destination.size)
        value.center.x -= x * crop.width / sourceSize.width
        value.center.y -= y * crop.height / sourceSize.height
        framing = value.centerClamped(in: sourceSize, filling: destination.size)
    }

    private func adjustZoom(_ direction: AccessibilityAdjustmentDirection) {
        guard isEnabled else { return }
        var value = framing
        switch direction {
        case .increment: value.zoom += 0.1
        case .decrement: value.zoom -= 0.1
        @unknown default: return
        }
        framing = value.centerClamped(in: sourceSize, filling: destination.size)
    }
}

private struct CameraCropShape: Shape {
    let cameraShape: CameraShape?

    func path(in rect: CGRect) -> Path {
        switch cameraShape {
        case .circle: return Ellipse().path(in: rect)
        case .roundedRectangle:
            return RoundedRectangle(cornerRadius: rect.height * 0.14, style: .circular).path(in: rect)
        case nil: return Rectangle().path(in: rect)
        }
    }
}
