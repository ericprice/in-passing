import CoreGraphics
import Foundation

public struct WindowTrace: Codable, Identifiable, Equatable {
    public let id: UUID
    public let closedAt: Date
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    /// AX coordinates: origin at the top left of the primary display.
    /// Optional so drawings made by the first version remain readable.
    public let desktop: CGRect?

    public init?(frame: CGRect, desktop: CGRect, at: Date = Date()) {
        guard desktop.width > 0, desktop.height > 0,
              [frame.minX, frame.minY, frame.width, frame.height, desktop.minX, desktop.minY, desktop.width, desktop.height].allSatisfy({ $0.isFinite }) else { return nil }
        let clipped = frame.intersection(desktop)
        guard !clipped.isNull, clipped.width >= 20, clipped.height >= 20 else { return nil }
        id = UUID(); closedAt = at
        x = (clipped.minX - desktop.minX) / desktop.width
        y = (clipped.minY - desktop.minY) / desktop.height
        width = clipped.width / desktop.width
        height = clipped.height / desktop.height
        self.desktop = desktop
    }

    public func frame(in currentDesktop: CGRect) -> CGRect {
        let bounds = desktop ?? currentDesktop
        return CGRect(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height,
                      width: width * bounds.width, height: height * bounds.height)
    }
}

/// Records one mark per visible-to-hidden/closed transition. Restoring rearms the window.
public struct WindowLedger {
    private struct Entry { var frame: CGRect; var visible: Bool }
    private var frames: [UUID: Entry] = [:]
    public init() {}
    public var count: Int { frames.count }
    /// An explicit visibility is used only when establishing a new baseline.
    public mutating func update(_ id: UUID, frame: CGRect, visible: Bool? = nil) {
        frames[id] = Entry(frame: frame, visible: visible ?? frames[id]?.visible ?? true)
    }
    public mutating func setVisible(_ id: UUID, _ visible: Bool) -> CGRect? {
        guard var entry = frames[id] else { return nil }
        let disappeared = entry.visible && !visible
        entry.visible = visible; frames[id] = entry
        return disappeared ? entry.frame : nil
    }
    public mutating func close(_ id: UUID) -> CGRect? {
        guard let entry = frames.removeValue(forKey: id), entry.visible else { return nil }
        return entry.frame
    }
    public mutating func reset() { frames.removeAll() }
}
