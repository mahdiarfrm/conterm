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
        main.addItem(makeEditMenu(delegate: delegate))
        main.addItem(makeViewMenu(delegate: delegate))
        main.addItem(makeToolsMenu(delegate: delegate))
        main.addItem(makeWindowMenu(delegate: delegate))
        main.addItem(makeHelpMenu(delegate: delegate))
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

    /// Key equivalents on items the shortcut monitor also handles are there
    /// to be read: the monitor swallows those chords before the menu sees
    /// them, so nothing fires twice.
    private static func makeFileMenu(delegate: AppDelegate) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Window",
                          action: #selector(AppDelegate.newWindow(_:)),
                          key: "n", target: delegate))
        menu.addItem(item("New Tab",
                          action: #selector(AppDelegate.newTab(_:)),
                          key: "t", target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Split Right",
                          action: #selector(AppDelegate.splitRight(_:)),
                          key: "d", target: delegate))
        menu.addItem(item("Split Down",
                          action: #selector(AppDelegate.splitDown(_:)),
                          key: "d", modifiers: [.command, .shift], target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Rename Tab…",
                          action: #selector(AppDelegate.renameTab(_:)),
                          target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Close Tab/Pane",
                          action: #selector(AppDelegate.closeActive(_:)),
                          key: "w", target: delegate))
        menu.addItem(item("Close Window",
                          action: #selector(AppDelegate.closeWindow(_:)),
                          key: "w", modifiers: [.command, .shift], target: delegate))
        root.submenu = menu
        return root
    }

    /// Edit menu items intentionally have NO keyEquivalents so we don't
    /// fight libghostty's native ⌘C / ⌘V handling inside the terminal
    /// (the surface uses its own keybindings to copy/paste from the pty).
    /// Clicking the menu items still works via the responder chain when
    /// a SwiftUI TextField (palette/settings rename field) has focus.
    private static func makeEditMenu(delegate: AppDelegate) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Cut",   action: #selector(NSText.cut(_:))))
        menu.addItem(item("Copy",  action: #selector(NSText.copy(_:))))
        menu.addItem(item("Paste", action: #selector(NSText.paste(_:))))
        menu.addItem(item("Select All",
                          action: #selector(NSText.selectAll(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Find…",
                          action: #selector(AppDelegate.showSearch(_:)),
                          key: "f", target: delegate))
        menu.addItem(item("Find Next",
                          action: #selector(AppDelegate.findNext(_:)),
                          key: "g", target: delegate))
        menu.addItem(item("Find Previous",
                          action: #selector(AppDelegate.findPrevious(_:)),
                          key: "g", modifiers: [.command, .shift], target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Clear Screen",
                          action: #selector(AppDelegate.clearScreen(_:)),
                          target: delegate))
        root.submenu = menu
        return root
    }

    private static func makeViewMenu(delegate: AppDelegate) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "View")
        menu.addItem(item("Command Palette",
                          action: #selector(AppDelegate.togglePalette(_:)),
                          key: "k", target: delegate))
        menu.addItem(item("Agents",
                          action: #selector(AppDelegate.toggleAgents(_:)),
                          key: "a", modifiers: [.command, .shift], target: delegate))
        menu.addItem(item("Notifications",
                          action: #selector(AppDelegate.toggleNotifications(_:)),
                          target: delegate))
        menu.addItem(.separator())

        // Checked by `AppDelegate.validateMenuItem`, keyed on the tag.
        let layout = NSMenu(title: "Layout")
        for (title, mode) in [("Tabs on Top", MenuTag.layoutHorizontal),
                              ("Tabs in Sidebar", MenuTag.layoutVertical),
                              ("Agents Sidebar", MenuTag.layoutAgents)] {
            let mi = item(title, action: #selector(AppDelegate.setLayout(_:)), target: delegate)
            mi.tag = mode.rawValue
            layout.addItem(mi)
        }
        layout.addItem(.separator())
        let autoHide = item("Auto-hide Sidebar",
                            action: #selector(AppDelegate.toggleAutoHideSidebar(_:)),
                            target: delegate)
        autoHide.tag = MenuTag.autoHideSidebar.rawValue
        layout.addItem(autoHide)
        let layoutRoot = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        layoutRoot.submenu = layout
        menu.addItem(layoutRoot)

        let style = NSMenu(title: "Interface")
        for (title, tag) in [("Liquid Drop", MenuTag.styleLiquidDrop),
                             ("Classic", MenuTag.styleClassic)] {
            let mi = item(title, action: #selector(AppDelegate.setInterfaceStyle(_:)), target: delegate)
            mi.tag = tag.rawValue
            style.addItem(mi)
        }
        let styleRoot = NSMenuItem(title: "Interface", action: nil, keyEquivalent: "")
        styleRoot.submenu = style
        menu.addItem(styleRoot)

        let orbit = item("Orbit",
                         action: #selector(AppDelegate.toggleOrbit(_:)),
                         key: "m", modifiers: [.command, .shift], target: delegate)
        orbit.tag = MenuTag.orbit.rawValue
        menu.addItem(orbit)
        menu.addItem(.separator())
        // No key equivalents: ⌘↑ / ⌘↓ must fall through to the terminal
        // when the shell has no prompt marks, and a menu equivalent would
        // swallow them first.
        menu.addItem(item("Previous Prompt",
                          action: #selector(AppDelegate.previousPrompt(_:)), target: delegate))
        menu.addItem(item("Next Prompt",
                          action: #selector(AppDelegate.nextPrompt(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen",
                          action: #selector(NSWindow.toggleFullScreen(_:)),
                          key: "f", modifiers: [.command, .control]))
        root.submenu = menu
        return root
    }

    /// The pages that report on work: what happened while away, what an
    /// agent did and changed, what the last Ansible run and Terraform plan
    /// said, and a command across hosts.
    private static func makeToolsMenu(delegate: AppDelegate) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Tools")
        menu.addItem(item("While You Were Away",
                          action: #selector(AppDelegate.showBriefing(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Agent History",
                          action: #selector(AppDelegate.showAgentHistory(_:)), target: delegate))
        menu.addItem(item("Review Changes",
                          action: #selector(AppDelegate.showWorktreeReview(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Last Ansible Report",
                          action: #selector(AppDelegate.showAnsibleReport(_:)), target: delegate))
        menu.addItem(item("Last Terraform Plan",
                          action: #selector(AppDelegate.showTerraformPlan(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Fleet Run…",
                          action: #selector(AppDelegate.showFleetRun(_:)), target: delegate))
        root.submenu = menu
        return root
    }

    private static func makeWindowMenu(delegate: AppDelegate) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize",
                          action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item("Zoom",
                          action: #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Next Tab",
                          action: #selector(AppDelegate.selectNextTab(_:)),
                          key: "]", modifiers: [.command, .shift], target: delegate))
        menu.addItem(item("Show Previous Tab",
                          action: #selector(AppDelegate.selectPreviousTab(_:)),
                          key: "[", modifiers: [.command, .shift], target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front",
                          action: #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = menu
        root.submenu = menu
        return root
    }

    private static func makeHelpMenu(delegate: AppDelegate) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Keyboard Shortcuts",
                          action: #selector(AppDelegate.showShortcuts(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Conterm on GitHub",
                          action: #selector(AppDelegate.openProjectPage(_:)), target: delegate))
        menu.addItem(item("Release Notes",
                          action: #selector(AppDelegate.openReleaseNotes(_:)), target: delegate))
        menu.addItem(item("Report an Issue…",
                          action: #selector(AppDelegate.openIssues(_:)), target: delegate))
        NSApp.helpMenu = menu
        root.submenu = menu
        return root
    }

    // MARK: - Helpers

    private static func item(_ title: String,
                              action: Selector?,
                              key: String = "",
                              modifiers: NSEvent.ModifierFlags = [.command],
                              target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { mi.keyEquivalentModifierMask = modifiers }
        if let target { mi.target = target }
        return mi
    }
}

/// Tags on the menu items whose checkmark follows a preference or a mode.
enum MenuTag: Int {
    case layoutHorizontal = 101, layoutVertical, layoutAgents
    case autoHideSidebar = 110
    case styleLiquidDrop = 120, styleClassic
    case orbit = 130
}
