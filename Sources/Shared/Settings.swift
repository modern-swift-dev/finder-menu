import Foundation

// Settings live in the helper app's preferences (local.findermenu). The settings window and
// `finder-menu terminal` write them; the sandboxed extension can only read them, through the
// shared-preference exception in Resources/Extension.entitlements.
let settingsDomain = "local.findermenu"
let settings: UserDefaults = Bundle.main.bundleIdentifier == settingsDomain
    ? .standard : UserDefaults(suiteName: settingsDomain) ?? .standard

/// The right-click menu's items, in menu order. The settings window lists them; the extension skips hidden ones.
let menuItems: [(id: String, title: String, symbol: String)] = [
    ("new-file", "New File…", "doc.badge.plus"),
    ("terminal", "Open Terminal Here", "terminal"),
    ("open-with", "Open Folder With", "arrow.up.forward.app"),
    ("copy-path", "Copy Path", "doc.on.doc"),
    ("parent-folder", "Go to Parent Folder", "arrow.turn.left.up")
]

func isHidden(_ item: String) -> Bool {
    settings.bool(forKey: "Hide.\(item)")
}

func setHidden(_ item: String, _ hidden: Bool) {
    if hidden {
        settings.set(true, forKey: "Hide.\(item)")
    } else {
        settings.removeObject(forKey: "Hide.\(item)")
    }
}

/// Bundle ID of the terminal for Open Terminal Here; nil means pick the first installed one automatically.
var chosenTerminal: String? {
    get { settings.string(forKey: "Terminal") }
    set {
        if let newValue {
            settings.set(newValue, forKey: "Terminal")
        } else {
            settings.removeObject(forKey: "Terminal")
        }
    }
}
