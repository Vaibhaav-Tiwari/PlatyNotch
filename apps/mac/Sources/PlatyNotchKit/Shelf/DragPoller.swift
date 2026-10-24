import Foundation

/// A drag session seen by `DragPoller`.
public enum DragEvent: Equatable, Sendable {
    case began, ended
}

/// Detects a drag from two cheap signals only: the left mouse button is down and the
/// drag pasteboard's `changeCount` moved since the button went down (every drag writes
/// that pasteboard when it starts). It never reads what is on the pasteboard.
///
/// The UI samples it on mouse-down / dragged / up events and, only while the button is
/// down, on a short poll; with the button up nothing polls.
public struct DragPoller: Sendable {
    public private(set) var isDragging = false
    /// The change count when the current press began (or at the last sample with the button up).
    private var baseline: Int

    public init(changeCount: Int) {
        baseline = changeCount
    }

    /// The left button went down: whatever the drag pasteboard holds now is not a new drag.
    public mutating func pressed(changeCount: Int) {
        if !isDragging { baseline = changeCount }
    }

    /// `.began` when the change count moved while the button is down; `.ended` when the
    /// button is up after a drag. At most one drag per press.
    public mutating func sample(changeCount: Int, mouseDown: Bool) -> DragEvent? {
        if mouseDown {
            guard !isDragging, changeCount != baseline else { return nil }
            isDragging = true
            baseline = changeCount
            return .began
        }
        baseline = changeCount
        guard isDragging else { return nil }
        isDragging = false
        return .ended
    }

    /// Ends a drag without a button-up (the detector stopped).
    public mutating func cancel(changeCount: Int) -> DragEvent? {
        sample(changeCount: changeCount, mouseDown: false)
    }
}
