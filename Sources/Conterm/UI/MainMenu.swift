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
        menu.addItem(item("Reload Configuration",
                          action: #selector(AppDelegate.reloadConfiguration(_:)),
                          key: ",", modifiers: [.command, .shift], target: delegate))
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
        let openIn = NSMenu(title: "Open Directory In")
        openIn.addItem(item("Finder", action: #selector(AppDelegate.openInFinder(_:)),
                            target: delegate))
        openIn.addItem(item("Cursor", action: #selector(AppDelegate.openInCursor(_:)),
                            target: delegate))
        openIn.addItem(item("VS Code", action: #selector(AppDelegate.openInVSCode(_:)),
                            target: delegate))
        menu.addItem(submenu("Open Directory In", openIn))
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
        menu.addItem(submenu("Layout", layout))

        let style = NSMenu(title: "Interface")
        for (title, tag) in [("Liquid Drop", MenuTag.styleLiquidDrop),
                             ("Classic", MenuTag.styleClassic)] {
            let mi = item(title, action: #selector(AppDelegate.setInterfaceStyle(_:)), target: delegate)
            mi.tag = tag.rawValue
            style.addItem(mi)
        }
        menu.addItem(submenu("Interface", style))

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
        // The active pane's text size, through libghostty's own bindings.
        menu.addItem(item("Bigger",
                          action: #selector(AppDelegate.biggerText(_:)), key: "=", target: delegate))
        menu.addItem(item("Smaller",
                          action: #selector(AppDelegate.smallerText(_:)), key: "-", target: delegate))
        menu.addItem(item("Actual Size",
                          action: #selector(AppDelegate.actualSizeText(_:)), key: "0", target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen",
                          action: #selector(NSWindow.toggleFullScreen(_:)),
                          key: "f", modifiers: [.command, .control]))
        root.submenu = menu
        return root
    }

    /// The pages that report on work (what happened while away, what an
    /// agent did and changed, the last Ansible run and Terraform plan), the
    /// ways to reach hosts, and the palette's history and notes lists.
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
        menu.addItem(item("Connect to Host…",
                          action: #selector(AppDelegate.connectToHost(_:)), target: delegate))
        menu.addItem(item("Fleet Run…",
                          action: #selector(AppDelegate.showFleetRun(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Clipboard History",
                          action: #selector(AppDelegate.showClipboardHistory(_:)), target: delegate))
        menu.addItem(item("Shell History",
                          action: #selector(AppDelegate.showShellHistory(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Notes",
                          action: #selector(AppDelegate.showNotes(_:)), target: delegate))
        menu.addItem(item("New Note",
                          action: #selector(AppDelegate.newNote(_:)), target: delegate))
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
        menu.addItem(submenu("Select Tab", LiveMenu.tabs(delegate: delegate)))
        menu.addItem(submenu("Select Pane", LiveMenu.panes(delegate: delegate)))
        menu.addItem(item("Tab Groups…",
                          action: #selector(AppDelegate.showTabGroups(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Jump to Pane…",
                          action: #selector(AppDelegate.jumpToPane(_:)), target: delegate))
        menu.addItem(item("Next Blocked Agent",
                          action: #selector(AppDelegate.nextBlockedAgent(_:)), target: delegate))
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

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.submenu = menu
        return root
    }

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

/// A submenu rebuilt from the key window's state each time it opens: its
/// tabs, or the panes of its current tab. The first nine carry the ⌘ / ⌥
/// digit their shortcut uses. Those chords belong to the shortcut monitor,
/// so the menu is never searched for them.
@MainActor
final class LiveMenu: NSObject, NSMenuDelegate {
    private let build: (NSMenu) -> Void
    /// Menus hold their delegate weakly.
    private static var retained: [LiveMenu] = []

    private init(_ build: @escaping (NSMenu) -> Void) { self.build = build }

    private static func make(_ title: String, _ build: @escaping (NSMenu) -> Void) -> NSMenu {
        let source = LiveMenu(build)
        retained.append(source)
        let menu = NSMenu(title: title)
        menu.delegate = source
        return menu
    }

    static func tabs(delegate: AppDelegate) -> NSMenu {
        make("Select Tab") { [weak delegate] menu in
            guard let state = delegate?.state else { return }
            for (i, tab) in state.tabs.enumerated() {
                let mi = NSMenuItem(title: tab.title.isEmpty ? "Tab \(i + 1)" : tab.title,
                                    action: #selector(AppDelegate.selectTabFromMenu(_:)),
                                    keyEquivalent: i < 9 ? "\(i + 1)" : "")
                mi.keyEquivalentModifierMask = [.command]
                mi.target = delegate
                mi.representedObject = tab.id
                mi.state = tab.id == state.selectedID ? .on : .off
                menu.addItem(mi)
            }
        }
    }

    static func panes(delegate: AppDelegate) -> NSMenu {
        make("Select Pane") { [weak delegate] menu in
            guard let state = delegate?.state, let tab = state.selectedTab else { return }
            for (i, pane) in tab.paneTree.root.leaves().enumerated() {
                let mi = NSMenuItem(title: OrbitModel.paneLabel(pane),
                                    action: #selector(AppDelegate.selectPaneFromMenu(_:)),
                                    keyEquivalent: i < 9 ? "\(i + 1)" : "")
                mi.keyEquivalentModifierMask = [.option]
                mi.target = delegate
                mi.representedObject = i + 1
                mi.state = pane.id == tab.paneTree.activePaneID ? .on : .off
                menu.addItem(mi)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        build(menu)
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }

    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent,
                              target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }
}

/// Tags on the menu items whose checkmark follows a preference or a mode.
enum MenuTag: Int {
    case layoutHorizontal = 101, layoutVertical, layoutAgents
    case autoHideSidebar = 110
    case styleLiquidDrop = 120, styleClassic
    case orbit = 130
}
