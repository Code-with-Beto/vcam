import CoreGraphics

/// A composition aid, not a platform-certified crop or a limit on what gets recorded.
enum SafeAreaGuide {
    static let edgeInset: CGFloat = 0.08
    static let captionBottomInset: CGFloat = 0.20

    static func aspectLabel(for size: CGSize) -> String {
        guard size.width > 0, size.height > 0 else { return "Frame" }
        let ratio = size.width / size.height
        if abs(ratio - 9.0 / 16.0) < 0.015 { return "9:16" }
        if abs(ratio - 16.0 / 9.0) < 0.015 { return "16:9" }
        if abs(ratio - 1) < 0.015 { return "1:1" }
        return size.width > size.height ? "Wide" : "Tall"
    }

    static func normalizedBottomInset(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return edgeInset }
        return min(max(value, edgeInset), 0.40)
    }

    /// Returns the generous content guide in AppKit's bottom-left coordinates.
    static func contentRect(in bounds: CGRect, bottomInset: CGFloat = edgeInset) -> CGRect {
        let bottom = normalizedBottomInset(bottomInset)
        return CGRect(
            x: bounds.minX + bounds.width * edgeInset,
            y: bounds.minY + bounds.height * bottom,
            width: bounds.width * (1 - edgeInset * 2),
            height: bounds.height * (1 - edgeInset - bottom)
        )
    }
}
