import AppKit

/// Coordinates are global AppKit points, with the origin at the bottom left.
@MainActor
final class FrameOverlayController {
    var onFrameChanged: ((CGRect) -> Void)?
    var onToggleRecording: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    var onRestartRecording: (() -> Void)?
    var onHide: (() -> Void)?
    var onMotionModeChanged: ((String) -> Void)?
    var onSelect: (() -> Void)?

    private static let displayedOverlays = NSHashTable<FrameOverlayController>.weakObjects()
    private static var nextPlacementOrder = 0
    private let placementOrder: Int

    private let guideView = CaptureGuideView()
    private let handleView = CaptureHandleView()
    private let guideWindow: CaptureOverlayPanel
    private let handleWindow: CaptureOverlayPanel
    private var frame = CGRect.zero
    private var displayFrame = CGRect.zero
    private var recording = false
    private var controlsBusy = false
    private var dragStartFrame = CGRect.zero
    private var dragStartPoint = CGPoint.zero
    private var motionMode = FrameMotionMode.free

    init() {
        placementOrder = Self.nextPlacementOrder
        Self.nextPlacementOrder += 1
        guideWindow = CaptureOverlayPanel(contentRect: .zero)
        handleWindow = CaptureOverlayPanel(
            contentRect: CGRect(origin: .zero, size: CaptureHandleView.preferredSize)
        )
        guideWindow.contentView = guideView
        guideWindow.ignoresMouseEvents = true
        guideWindow.hasShadow = false
        guideWindow.setAccessibilityLabel("Vertical recording frame")

        handleWindow.contentView = handleView
        handleWindow.hasShadow = true
        handleWindow.setAccessibilityLabel("Recording frame controls")

        handleView.onDragBegan = { [weak self] point in
            guard let self else { return }
            self.onSelect?()
            self.dragStartPoint = point
            self.dragStartFrame = self.frame
        }
        handleView.onDragMoved = { [weak self] point in
            guard let self else { return }
            var movedFrame = self.dragStartFrame
            if self.motionMode != .vertical {
                movedFrame.origin.x += point.x - self.dragStartPoint.x
            }
            if self.motionMode != .horizontal {
                movedFrame.origin.y += point.y - self.dragStartPoint.y
            }
            movedFrame = self.clamped(movedFrame)
            guard movedFrame != self.frame else { return }
            self.frame = movedFrame
            self.positionWindows()
            self.onFrameChanged?(movedFrame)
        }
        handleView.onToggleRecording = { [weak self] in
            guard let self, !self.controlsBusy else { return }
            self.onToggleRecording?()
        }
        handleView.onCancelRecording = { [weak self] in
            guard let self, self.recording, !self.controlsBusy else { return }
            self.onCancelRecording?()
        }
        handleView.onRestartRecording = { [weak self] in
            guard let self, self.recording, !self.controlsBusy else { return }
            self.onRestartRecording?()
        }
        handleView.onHide = { [weak self] in
            guard let self, !self.recording, !self.controlsBusy else { return }
            self.onHide?()
        }
        handleView.onMotionModeChanged = { [weak self] mode in
            guard let self else { return }
            self.motionMode = mode
            self.onMotionModeChanged?(mode.rawValue)
        }
    }

    func show(frame: CGRect, displayFrame: CGRect, guides: Bool, guideBottomInset: CGFloat = 0.08,
              label: String? = nil, accent: NSColor = .systemCyan, isSelected: Bool = true,
              busy: Bool = false) {
        Self.displayedOverlays.add(self)
        update(frame: frame, displayFrame: displayFrame, guides: guides,
               recording: recording, guideBottomInset: guideBottomInset,
               label: label, accent: accent, isSelected: isSelected, busy: busy)
        // This leaves the user's terminal, browser, or other app focused.
        guideWindow.orderFrontRegardless()
        handleWindow.orderFrontRegardless()
        positionWindows()
    }

    func update(frame: CGRect, displayFrame: CGRect, guides: Bool, recording: Bool,
                guideBottomInset: CGFloat = 0.08, label: String? = nil,
                accent: NSColor = .systemCyan, isSelected: Bool = true, busy: Bool = false) {
        let becameSelected = isSelected && !handleView.isSelected
        self.frame = frame
        self.displayFrame = displayFrame
        self.recording = recording
        controlsBusy = busy
        guideView.showsGuides = guides
        guideView.isRecording = recording
        guideView.bottomInset = SafeAreaGuide.normalizedBottomInset(guideBottomInset)
        guideView.identityLabel = label
        guideView.accent = accent
        guideView.isSelected = isSelected
        handleView.isRecording = recording
        handleView.isBusy = busy
        handleView.aspectLabel = SafeAreaGuide.aspectLabel(for: frame.size)
        handleView.identityLabel = label
        handleView.accent = accent
        handleView.isSelected = isSelected
        let identity = label ?? handleView.aspectLabel
        guideWindow.setAccessibilityLabel("\(identity) recording frame")
        handleWindow.setAccessibilityLabel("\(identity) recording controls")
        positionWindows()
        if becameSelected && handleWindow.isVisible {
            guideWindow.orderFrontRegardless()
            handleWindow.orderFrontRegardless()
        }
    }

    func hide() {
        Self.displayedOverlays.remove(self)
        guideWindow.orderOut(nil)
        handleWindow.orderOut(nil)
        for overlay in Self.displayedOverlays.allObjects.sorted(by: { $0.placementOrder < $1.placementOrder }) {
            overlay.positionHandleWindow()
        }
    }

    private func clamped(_ proposed: CGRect) -> CGRect {
        var result = proposed
        result.origin.x = min(
            max(proposed.minX, displayFrame.minX),
            max(displayFrame.minX, displayFrame.maxX - proposed.width)
        )
        result.origin.y = min(
            max(proposed.minY, displayFrame.minY),
            max(displayFrame.minY, displayFrame.maxY - proposed.height)
        )
        return result
    }

    private func positionWindows() {
        guideWindow.setFrame(frame, display: true)
        positionHandleWindow()
        // Earlier-created regions keep their anchor. Later handles move around them,
        // avoiding the oscillation caused by each handle trying to dodge the other.
        for overlay in Self.displayedOverlays.allObjects.sorted(by: { $0.placementOrder < $1.placementOrder })
            where overlay.placementOrder > placementOrder && overlay.handleWindow.isVisible {
            overlay.positionHandleWindow()
        }
        guideView.needsDisplay = true
    }

    private func positionHandleWindow() {
        let size = handleView.preferredSize
        let gap: CGFloat = 9
        let aboveY = frame.maxY + gap
        let belowY = frame.minY - size.height - gap
        let proposedY: CGFloat
        if aboveY + size.height <= displayFrame.maxY {
            proposedY = aboveY
        } else if belowY >= displayFrame.minY {
            proposedY = belowY
        } else {
            // At a display edge, keep the handle reachable inside the frame.
            proposedY = frame.maxY - size.height - gap
        }
        let x = min(
            max(frame.midX - size.width / 2, displayFrame.minX + 4),
            max(displayFrame.minX + 4, displayFrame.maxX - size.width - 4)
        )
        let y = min(
            max(proposedY, displayFrame.minY + 4),
            max(displayFrame.minY + 4, displayFrame.maxY - size.height - 4)
        )
        let anchor = CGRect(x: x, y: y, width: size.width, height: size.height)
        let obstacles = Self.displayedOverlays.allObjects.filter {
            $0.placementOrder < placementOrder && $0.handleWindow.isVisible
        }.map { $0.handleWindow.frame.insetBy(dx: -4, dy: -4) }
        var candidates = [anchor]
        for candidateY in [belowY, aboveY, frame.maxY - size.height - gap, frame.minY + gap] {
            candidates.append(CGRect(x: x, y: candidateY, width: size.width, height: size.height))
        }
        for step in 1...6 {
            for direction: CGFloat in [-1, 1] {
                candidates.append(anchor.offsetBy(dx: 0, dy: direction * CGFloat(step) * (size.height + gap)))
            }
        }
        let usableDisplay = displayFrame.insetBy(dx: 4, dy: 4)
        let reachable = candidates.filter { usableDisplay.contains($0) }
        let target = reachable.first { candidate in !obstacles.contains { $0.intersects(candidate) } } ?? anchor
        handleWindow.setFrame(target, display: true)
    }
}

@MainActor
private final class CaptureOverlayPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CaptureGuideView: NSView {
    var showsGuides = true { didSet { needsDisplay = true } }
    var isRecording = false { didSet { needsDisplay = true } }
    var bottomInset: CGFloat = SafeAreaGuide.edgeInset { didSet { needsDisplay = true } }
    var identityLabel: String? { didSet { needsDisplay = true } }
    var accent: NSColor = .systemCyan { didSet { needsDisplay = true } }
    var isSelected = true { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let tint: NSColor = isRecording && identityLabel == nil ? .systemRed : accent
        let border = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        NSColor.black.withAlphaComponent(0.6).setStroke()
        border.lineWidth = 4
        border.stroke()
        tint.withAlphaComponent(isSelected ? 1 : 0.65).setStroke()
        border.lineWidth = isSelected ? 2.5 : 1.5
        border.stroke()

        if let identityLabel {
            drawPill(identityLabel, at: CGPoint(x: 10, y: max(4, bounds.height - 29)), tint: accent)
        }

        guard showsGuides else { return }

        let safeRect = SafeAreaGuide.contentRect(in: bounds, bottomInset: bottomInset)
        let reservesCaptions = bottomInset > SafeAreaGuide.edgeInset + 0.001

        // Only shade the edges, keeping the large composition area completely clear.
        // Everything inside the outer frame is still recorded, including these margins.
        NSColor.black.withAlphaComponent(0.15).setFill()
        for margin in [
            CGRect(x: 0, y: 0, width: bounds.width, height: safeRect.minY),
            CGRect(x: 0, y: safeRect.maxY, width: bounds.width, height: bounds.height - safeRect.maxY),
            CGRect(x: 0, y: safeRect.minY, width: safeRect.minX, height: safeRect.height),
            CGRect(x: safeRect.maxX, y: safeRect.minY, width: bounds.width - safeRect.maxX, height: safeRect.height)
        ] {
            NSBezierPath(rect: margin).fill()
        }

        // Small corner marks suggest comfortable padding without boxing the content in.
        let marks = NSBezierPath()
        let length: CGFloat = min(14, safeRect.width * 0.08)
        for corner in [
            (CGPoint(x: safeRect.minX, y: safeRect.minY), CGFloat(1), CGFloat(1)),
            (CGPoint(x: safeRect.maxX, y: safeRect.minY), CGFloat(-1), CGFloat(1)),
            (CGPoint(x: safeRect.minX, y: safeRect.maxY), CGFloat(1), CGFloat(-1)),
            (CGPoint(x: safeRect.maxX, y: safeRect.maxY), CGFloat(-1), CGFloat(-1))
        ] {
            marks.move(to: CGPoint(x: corner.0.x + length * corner.1, y: corner.0.y))
            marks.line(to: corner.0)
            marks.line(to: CGPoint(x: corner.0.x, y: corner.0.y + length * corner.2))
        }
        NSColor.black.withAlphaComponent(0.6).setStroke()
        marks.lineWidth = 3
        marks.stroke()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        marks.lineWidth = 1
        marks.stroke()

        if reservesCaptions {
            tint.withAlphaComponent(0.055).setFill()
            NSBezierPath(rect: CGRect(x: 3, y: 3, width: bounds.width - 6, height: safeRect.minY - 3)).fill()
            let separator = NSBezierPath()
            separator.move(to: CGPoint(x: safeRect.minX + length, y: safeRect.minY))
            separator.line(to: CGPoint(x: safeRect.maxX - length, y: safeRect.minY))
            separator.setLineDash([4, 6], count: 2, phase: 0)
            separator.lineWidth = 1
            NSColor.white.withAlphaComponent(0.35).setStroke()
            separator.stroke()
        }

        // Small landscape frames can have margins shorter than a readable label.
        // The handle still identifies the aspect ratio without covering the content.
        if identityLabel == nil && bounds.height - safeRect.maxY >= 23 {
            let topLabel = "\(SafeAreaGuide.aspectLabel(for: bounds.size)) · Padding guide"
            drawCenteredPill(topLabel, y: safeRect.maxY + (bounds.height - safeRect.maxY - 20) / 2, tint: .white)
        }
        if safeRect.minY >= 23 {
            drawCenteredPill(
                reservesCaptions ? "Space for captions" : "Entire frame is recorded",
                y: (safeRect.minY - 20) / 2,
                tint: .white
            )
        }
    }

    private func drawCenteredPill(_ text: String, y: CGFloat, tint: NSColor) {
        let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width + 12
        guard width <= bounds.width - 12 else { return }
        drawPill(text, at: CGPoint(x: (bounds.width - width) / 2, y: y), tint: tint)
    }

    private func drawPill(_ text: String, at point: CGPoint, tint: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: tint
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        let rect = CGRect(x: point.x, y: point.y, width: size.width + 12, height: 20)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        string.draw(at: CGPoint(x: point.x + 6, y: point.y + 4), withAttributes: attributes)
    }
}

private enum FrameMotionMode: String {
    case free
    case horizontal
    case vertical
}

@MainActor
private final class CaptureHandleView: NSView {
    static let preferredSize = CGSize(width: 330, height: 40)
    var preferredSize: CGSize {
        CGSize(width: Self.preferredSize.width + dragRegionWidth - 76 + (isRecording ? 18 : 0), height: 40)
    }
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onToggleRecording: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    var onRestartRecording: (() -> Void)?
    var onHide: (() -> Void)?
    var onMotionModeChanged: ((FrameMotionMode) -> Void)?

    private let recordingButton = OverlayButton(title: "Record", target: nil, action: nil)
    private let cancelButton = OverlayButton(title: "", target: nil, action: nil)
    private let restartButton = OverlayButton(title: "", target: nil, action: nil)
    private let hideButton = OverlayButton(title: "", target: nil, action: nil)
    private let freeButton = OverlayButton(title: "Free", target: nil, action: nil)
    private let horizontalButton = OverlayButton(title: "", target: nil, action: nil)
    private let verticalButton = OverlayButton(title: "", target: nil, action: nil)
    private var motionMode = FrameMotionMode.free
    var aspectLabel = "9:16" { didSet { needsDisplay = true } }
    var identityLabel: String? {
        didSet {
            needsLayout = true
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            updateIdentityAppearance()
        }
    }
    var accent: NSColor = .systemCyan {
        didSet {
            updateIdentityAppearance()
            updateMotionButtons()
        }
    }
    var isSelected = true { didSet { updateIdentityAppearance() } }
    private var dragRegionWidth: CGFloat {
        guard let identityLabel else { return 76 }
        let width = (identityLabel as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
        return max(76, min(122, ceil(width) + 44))
    }
    var isRecording = false {
        didSet {
            updateButtons()
            needsLayout = true
            needsDisplay = true
        }
    }
    var isBusy = false {
        didSet {
            updateButtons()
            updateMotionButtons()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 0.97).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.17).cgColor

        recordingButton.bezelStyle = .rounded
        recordingButton.isBordered = false
        recordingButton.wantsLayer = true
        recordingButton.layer?.cornerRadius = 7
        recordingButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        recordingButton.font = .systemFont(ofSize: 12, weight: .semibold)
        recordingButton.imagePosition = .imageLeading
        recordingButton.target = self
        recordingButton.action = #selector(toggleRecording)
        addSubview(recordingButton)

        hideButton.bezelStyle = .rounded
        hideButton.isBordered = false
        hideButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide recording frame")
        hideButton.contentTintColor = .white
        hideButton.target = self
        hideButton.action = #selector(hideFrame)
        hideButton.toolTip = "Hide recording frame"
        hideButton.setAccessibilityLabel("Hide recording frame")
        addSubview(hideButton)

        configureTakeButton(cancelButton, symbol: "trash", label: "Cancel recording and discard current take",
                            help: "Cancel: discard the current take and keep preview open", action: #selector(cancelRecording))
        configureTakeButton(restartButton, symbol: "arrow.counterclockwise", label: "Restart recording and discard current take",
                            help: "Restart: discard the current take and immediately start a new recording", action: #selector(restartRecording))

        configureMotionButton(freeButton, symbol: nil, label: "Move freely", action: #selector(moveFreely))
        configureMotionButton(horizontalButton, symbol: "arrow.left.and.right", label: "Pan horizontally", action: #selector(panHorizontally))
        configureMotionButton(verticalButton, symbol: "arrow.up.and.down", label: "Pan vertically", action: #selector(panVertically))

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Recording frame controls")
        setAccessibilityHelp("Drag the grip or aspect ratio to move the recording area. Choose free, horizontal, or vertical movement.")
        updateMotionButtons()
        updateButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let offset = dragRegionWidth - 76
        freeButton.frame = CGRect(x: 84 + offset, y: 6, width: 38, height: 28)
        horizontalButton.frame = CGRect(x: 128 + offset, y: 6, width: 28, height: 28)
        verticalButton.frame = CGRect(x: 162 + offset, y: 6, width: 28, height: 28)
        recordingButton.frame = CGRect(x: (isRecording ? 268 : 200) + offset, y: 6,
                                       width: isRecording ? 72 : 86, height: 28)
        cancelButton.frame = CGRect(x: 200 + offset, y: 6, width: 28, height: 28)
        restartButton.frame = CGRect(x: 234 + offset, y: 6, width: 28, height: 28)
        hideButton.frame = CGRect(x: 297 + offset, y: 6, width: 26, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = NSColor.white.withAlphaComponent(0.5)
        color.setFill()
        for x: CGFloat in [14, 19] {
            for y: CGFloat in [15, 20, 25] {
                NSBezierPath(ovalIn: CGRect(x: x, y: y - 1, width: 2, height: 2)).fill()
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        ((identityLabel ?? aspectLabel) as NSString).draw(
            in: CGRect(x: 31, y: 12, width: dragRegionWidth - 42, height: 17),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: identityLabel == nil ? 12 : 11, weight: .semibold),
                .foregroundColor: identityLabel == nil ? NSColor.white.withAlphaComponent(0.9) : accent,
                .paragraphStyle: paragraph
            ]
        )
        if isRecording {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: CGRect(x: dragRegionWidth - 9, y: 18, width: 5, height: 5)).fill()
        }
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: CGRect(x: dragRegionWidth, y: 11, width: 1, height: 18)).fill()
    }

    override func resetCursorRects() {
        addCursorRect(CGRect(x: 0, y: 0, width: dragRegionWidth, height: bounds.height), cursor: .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.push()
        onDragBegan?(NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        onDragMoved?(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
    }

    @objc private func toggleRecording() {
        guard !isBusy else { return }
        onToggleRecording?()
    }

    @objc private func hideFrame() {
        guard !isRecording, !isBusy else { return }
        onHide?()
    }

    @objc private func cancelRecording() {
        guard isRecording, !isBusy else { return }
        onCancelRecording?()
    }

    @objc private func restartRecording() {
        guard isRecording, !isBusy else { return }
        onRestartRecording?()
    }

    private func configureTakeButton(_ button: OverlayButton, symbol: String, label: String,
                                     help: String, action: Selector) {
        button.bezelStyle = .rounded
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = .white.withAlphaComponent(0.85)
        button.toolTip = help
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        addSubview(button)
    }

    private func configureMotionButton(_ button: OverlayButton, symbol: String?, label: String, action: Selector) {
        button.bezelStyle = .rounded
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.font = .systemFont(ofSize: 11, weight: .medium)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        button.toolTip = label + "; drag the grip to move the frame"
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        addSubview(button)
    }

    private func setMotionMode(_ mode: FrameMotionMode) {
        guard !isBusy else { return }
        motionMode = mode
        updateMotionButtons()
        onMotionModeChanged?(mode)
    }

    private func updateMotionButtons() {
        for (button, mode) in [(freeButton, FrameMotionMode.free), (horizontalButton, .horizontal), (verticalButton, .vertical)] {
            let selected = mode == motionMode
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? accent : .white.withAlphaComponent(0.7)
            button.layer?.backgroundColor = selected
                ? accent.withAlphaComponent(0.16).cgColor
                : NSColor.clear.cgColor
            button.setAccessibilityValue(selected ? "Selected" : "Not selected")
            button.isEnabled = !isBusy
            button.alphaValue = isBusy ? 0.4 : 1
        }
    }

    private func updateIdentityAppearance() {
        layer?.borderWidth = isSelected ? 1.5 : 1
        layer?.borderColor = accent.withAlphaComponent(isSelected ? 0.65 : 0.22).cgColor
        setAccessibilityLabel("\(identityLabel ?? aspectLabel) recording frame controls\(isSelected ? ", selected" : "")")
        needsDisplay = true
    }

    @objc private func moveFreely() { setMotionMode(.free) }
    @objc private func panHorizontally() { setMotionMode(.horizontal) }
    @objc private func panVertically() { setMotionMode(.vertical) }

    private func updateButtons() {
        recordingButton.title = isRecording ? "Finish" : "Record"
        recordingButton.image = NSImage(
            systemSymbolName: isRecording ? "stop.fill" : "record.circle.fill",
            accessibilityDescription: nil
        )
        recordingButton.contentTintColor = isRecording ? .systemRed : .white
        recordingButton.toolTip = isRecording ? "Finish and save the current take" : "Start recording"
        recordingButton.setAccessibilityLabel(isRecording ? "Finish and save recording" : "Start recording")
        recordingButton.isEnabled = !isBusy
        recordingButton.alphaValue = isBusy ? 0.4 : 1
        hideButton.isHidden = isRecording
        hideButton.isEnabled = !isRecording && !isBusy
        hideButton.alphaValue = isBusy ? 0.4 : 1
        for button in [cancelButton, restartButton] {
            button.isHidden = !isRecording
            button.isEnabled = isRecording && !isBusy
            button.alphaValue = isBusy ? 0.4 : 1
        }
    }
}

@MainActor
private final class OverlayButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
