import AppKit
import SwiftUI

@MainActor final class DrawingPreferences: ObservableObject {
    enum ColorMode: String, CaseIterable { case automatic, custom }
    private let defaults: UserDefaults
    @Published var maximumShapes: Int {
        didSet { defaults.set(maximumShapes, forKey: "maximumShapes") }
    }
    @Published var colorMode: ColorMode {
        didSet { defaults.set(colorMode.rawValue, forKey: "strokeColorMode") }
    }
    @Published var customColor: NSColor {
        didSet {
            guard let color = customColor.usingColorSpace(.sRGB) else { return }
            defaults.set([color.redComponent, color.greenComponent, color.blueComponent], forKey: "customStrokeColor")
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["maximumShapes": 5])
        maximumShapes = min(100, max(1, defaults.integer(forKey: "maximumShapes")))
        colorMode = defaults.string(forKey: "strokeColorMode").flatMap(ColorMode.init(rawValue:)) ?? .automatic
        if let rgb = defaults.array(forKey: "customStrokeColor") as? [Double], rgb.count == 3,
           rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            customColor = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        } else { customColor = .white }
    }
    func chooseMaximum() {
        let alert = NSAlert()
        alert.messageText = "Maximum Shapes"
        alert.informativeText = "Keep the most recent 1–100 shapes on your desktop."
        alert.addButton(withTitle: "Set Maximum"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: String(maximumShapes))
        field.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
        field.setAccessibilityLabel("Maximum Shapes")
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            if let value = Int(field.stringValue), (1...100).contains(value) { maximumShapes = value; return }
            alert.informativeText = "Enter a whole number from 1 to 100."
        }
    }
}
