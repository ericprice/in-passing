import AppKit

@MainActor final class MenuController: NSObject, NSMenuDelegate {
    enum Action: Equatable {
        case about, updates, openAtLogin, accessibility, pauseResume
        case automaticColor, customColor, maximum(Int), customMaximum, clear, quit, storageError
    }
    struct State {
        var trusted = true
        var paused = false
        var maximum = 5
        var customColor = false
        var openAtLogin = false
        var canCheckForUpdates = true
        var wallpaperFallback = false
        var notice = ""
    }
    let menu = NSMenu(title: "In Passing")
    private var statusItem: NSStatusItem?
    private let readState: () -> State
    private let perform: (Action) -> Void

    init(state: @escaping () -> State, perform: @escaping (Action) -> Void) {
        readState = state; self.perform = perform
        super.init()
        populate(menu)
        refresh(menu)
    }
    private func add(_ title: String, _ action: Action, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(selected(_:)), keyEquivalent: action == .quit ? "q" : "")
        item.target = self; item.representedObject = action
        menu.addItem(item)
    }
    private func populate(_ root: NSMenu) {
        root.autoenablesItems = false; root.delegate = self
        add("About In Passing", .about, to: root)
        root.addItem(.separator())
        add("Check for Updates…", .updates, to: root)
        add("Open at Login", .openAtLogin, to: root)
        root.addItem(.separator())
        add("Enable Accessibility…", .accessibility, to: root)
        add("Pause", .pauseResume, to: root)
        root.addItem(.separator())
        let color = NSMenu(title: "Color")
        color.autoenablesItems = false
        add("Match Wallpaper", .automaticColor, to: color)
        add("Custom Color…", .customColor, to: color)
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = color; root.addItem(colorItem)
        let maximum = NSMenu(title: "Maximum Shapes")
        maximum.autoenablesItems = false
        for count in [5, 10, 15, 20] { add(String(count), .maximum(count), to: maximum) }
        maximum.addItem(.separator())
        add("Custom…", .customMaximum, to: maximum)
        let maximumItem = NSMenuItem(title: "Maximum Shapes", action: nil, keyEquivalent: "")
        maximumItem.submenu = maximum; root.addItem(maximumItem)
        root.addItem(.separator())
        add("Clear…", .clear, to: root)
        add("Drawing Could Not Be Saved", .storageError, to: root)
        root.addItem(.separator())
        add("Quit In Passing", .quit, to: root)
    }
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let url = Bundle.main.url(forResource: "in-passing-menu-icon", withExtension: "pdf"),
              let icon = NSImage(contentsOf: url) else { preconditionFailure("The menu icon is missing from the app bundle") }
        icon.size = NSSize(width: 18, height: 18); icon.isTemplate = true
        icon.accessibilityDescription = "In Passing"
        item.button?.image = icon
        item.button?.setAccessibilityLabel("In Passing")
        item.menu = menu; statusItem = item

        // Standard application/Edit menus remain available while a native panel is active.
        let main = NSMenu()
        let app = NSMenuItem(title: "In Passing", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "In Passing"); populate(appMenu); refresh(appMenu)
        app.submenu = appMenu; main.addItem(app)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        edit.submenu = editMenu; main.addItem(edit); NSApp.mainMenu = main
    }
    func menuWillOpen(_ menu: NSMenu) { refresh(menu) }
    func refresh(_ menu: NSMenu) {
        let state = readState()
        func update(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { update(submenu) }
                guard let action = item.representedObject as? Action else { continue }
                item.state = .off; item.isEnabled = true
                switch action {
                case .updates: item.isEnabled = state.canCheckForUpdates
                case .openAtLogin: item.state = state.openAtLogin ? .on : .off
                case .accessibility: item.isHidden = state.trusted
                case .pauseResume:
                    item.title = state.paused ? "Resume" : "Pause"; item.isEnabled = state.trusted
                case .automaticColor:
                    item.state = state.customColor ? .off : .on
                    item.toolTip = state.wallpaperFallback ? "The wallpaper is unavailable; using system appearance." : nil
                case .customColor: item.state = state.customColor ? .on : .off
                case .maximum(let count): item.state = count == state.maximum ? .on : .off
                case .customMaximum: item.state = [5, 10, 15, 20].contains(state.maximum) ? .off : .on
                case .storageError: item.isHidden = state.notice.isEmpty; item.toolTip = state.notice
                default: break
                }
            }
        }
        update(menu)
    }
    @objc private func selected(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? Action else { return }
        perform(action)
        refresh(menu)
    }
}
