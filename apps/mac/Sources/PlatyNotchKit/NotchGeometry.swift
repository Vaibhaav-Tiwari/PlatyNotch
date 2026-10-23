import CoreGraphics

/// Pure screen geometry for the notch panel. Coordinates are AppKit's (origin bottom-left).
public enum NotchGeometry {
    public static let pillHeight: CGFloat = 28

    /// The physical notch, i.e. the gap between the two auxiliary top areas
    /// (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`). Nil when either is missing.
    public static func notchRect(screenFrame: CGRect, auxLeft: CGRect?, auxRight: CGRect?) -> CGRect? {
        guard let auxLeft, let auxRight else { return nil }
        let width = auxRight.minX - auxLeft.maxX
        guard width > 0 else { return nil }
        let height = max(auxLeft.height, auxRight.height)
        return CGRect(x: auxLeft.maxX, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// Fallback for screens without a notch: a pill centered just below the menu bar.
    public static func pillRect(screenFrame: CGRect, visibleFrame: CGRect, width: CGFloat) -> CGRect {
        CGRect(x: screenFrame.midX - width / 2, y: visibleFrame.maxY - pillHeight,
               width: width, height: pillHeight)
    }

    /// Panel frame top-aligned to the screen top, centered on `anchor`, clamped inside the screen.
    public static func panelFrame(anchor: CGRect, size: CGSize, screenFrame: CGRect) -> CGRect {
        let w = min(size.width, screenFrame.width)
        let h = min(size.height, screenFrame.height)
        let x = min(max(anchor.midX - w / 2, screenFrame.minX), screenFrame.maxX - w)
        return CGRect(x: x, y: screenFrame.maxY - h, width: w, height: h)
    }
}
