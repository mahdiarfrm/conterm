import AppKit

/// Standard macOS menu bar. Built programmatically because we don't have
/// an Interface Builder NIB. Wires every entry to AppDelegate (for
/// state mutations) or to the standard responder chain (for Edit menu
/// entries — copy/paste/etc. — which AppKit dispatches via selector).
@MainActor
enum MainMenu {
    static func install(delegate: AppDelegate) {
        let main = NSMenu()
        main.addItem(makeAppMenu(delegate: delegate))
        main.addItem(makeFileMenu(delegate: delegate))
        main.addItem(makeEditMenu())
        main.addItem(makeViewMenu(delegate: delegate))
        main.addItem(makeWindowMenu())
        main.addItem(makeHelpMenu())
        NSApp.mainMenu = main
    }

    // MARK: - Sub-menus

    private static func makeAppMenu(delegate: AppDelegate) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Conterm")

        menu.addItem(item("About Conterm",
                          action: #selector(AppDelegate.showAboutPanel(_:)),
                          target: delegate))
        menu.addItem(item("Check for Updates…",
                          action: #selector(AppDelegate.checkForUpdates(_:)),
                          target: delegate))
        menu.addItem(.separator())
        let settings = item("Settings…",
                             action: #selector(AppDelegate.openSettings(_:)),
                             key: ",", target: delegate)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(item("Hide Conterm",
                          action: #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = item("Hide Others",
                               action: #selector(NSApplication.hideOtherApplications(_:)),
                               key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(item("Show All",
                          action: #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Conterm",
                          action: #selector(AppDelegate.quitOrCloseWindow(_:)),
                          key: "q", target: delegate))

        root.submenu = menu
        return root
    }

    private static func makeFileMenu(delegate: AppDelegate) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Window",
                          action: #selector(AppDelegate.newWindow(_:)),
                          key: "n", target: delegate))
        menu.addItem(item("New Tab",
                          action: #selector(AppDelegate.newTab(_:)),
                          key: "t", target: delegate))
        menu.addItem(item("Close Tab/Pane",
                          action: #selector(AppDelegate.closeActive(_:)),
                          key: "w", target: delegate))
        let closeWindow = item("Close Window",
                               action: #selector(AppDelegate.closeWindow(_:)),
                               key: "w", target: delegate)
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(closeWindow)
        menu.addItem(.separator())
        menu.addItem(item("Split Right",
                          action: #selector(AppDelegate.splitRight(_:)),
                          key: "d", target: delegate))
        let splitDown = item("Split Down",
                              action: #selector(AppDelegate.splitDown(_:)),
                              key: "d", target: delegate)
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(splitDown)
        root.submenu = menu
        return root
    }

    /// Edit menu items intentionally have NO keyEquivalents so we don't
    /// fight libghostty's native ⌘C / ⌘V handling inside the terminal
    /// (the surface uses its own keybindings to copy/paste from the pty).
    /// Clicking the menu items still works via the responder chain when
    /// a SwiftUI TextField (palette/settings rename field) has focus.
    private static func makeEditMenu() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Cut",   action: #selector(NSText.cut(_:))))
        menu.addItem(item("Copy",  action: #selector(NSText.copy(_:))))
        menu.addItem(item("Paste", action: #selector(NSText.paste(_:))))
        menu.addItem(item("Select All",
                          action: #selector(NSText.selectAll(_:))))
        root.submenu = menu
        return root
    }

    private static func makeViewMenu(delegate: AppDelegate) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "View")
        menu.addItem(item("Command Palette",
                          action: #selector(AppDelegate.togglePalette(_:)),
                          key: "k", target: delegate))
        menu.addItem(item("Toggle Vertical Tabs",
                          action: #selector(AppDelegate.toggleVerticalTabs(_:)),
                          target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen",
                          action: #selector(NSWindow.toggleFullScreen(_:)),
                          key: "f"))
        root.submenu = menu
        return root
    }

    private static func makeWindowMenu() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize",
                          action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item("Zoom",
                          action: #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front",
                          action: #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = menu
        root.submenu = menu
        return root
    }

    private static func makeHelpMenu() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Conterm Help", action: nil))
        NSApp.helpMenu = menu
        root.submenu = menu
        return root
    }

    // MARK: - Helpers

    private static func item(_ title: String,
                              action: Selector?,
                              key: String = "",
                              target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if let target { mi.target = target }
        return mi
    }
}
