import CoreGraphics

public extension CGRect {
    var hasArea: Bool { !isNull && !isInfinite && width > 0 && height > 0 }
}

public func activeTraces(_ traces: [WindowTrace], maximum: Int) -> [WindowTrace] {
    Array(traces.suffix(max(1, maximum)))
}

/// Coordinates are display points; backing scale preserves the same pixel proportion.
public func outlineWidth(screenWidth: Double) -> Double { screenWidth * 0.005 }

public func prefersWhiteOutline(luminance: Double) -> Bool {
    let value = min(1, max(0, luminance))
    return (1.05 / (value + 0.05)) > ((value + 0.05) / 0.05)
}
