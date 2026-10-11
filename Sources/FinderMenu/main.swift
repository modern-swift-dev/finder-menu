import Cocoa
import os
import Security
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handledURL = false
    private var settingsWindow: SettingsWindowController?
    private var settingsCloseObserver: NSObjectProtocol?

    func application(_ application: NSApplication, open urls: [URL]) {
        handledURL = true
        guard sentByOurExtension() else {
            // Logger rather than NSLog, which macOS logs as <private>. The links stay redacted.
            Logger(subsystem: "local.findermenu", category: "links")
                .notice("Ignored a findermenu:// link that didn't come from the Finder extension: \(urls.map(\.absoluteString))")
            finish()
            return
        }
        for url in urls {
            guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let path = c.queryItems?.first(where: { $0.name == "path" })?.value,
                  let dir = folder(for: path) else {
                continue
            }
            switch c.host {
                case "newfile": newFile(in: dir)
                case "terminal": openTerminal(at: dir); return
                case "openwith":
                    let appID = c.queryItems?.first(where: { $0.name == "app" })?.value
                    // No app means "Other App…", where the user picks one themselves.
                    if let appID, !editors.contains(where: { $0.id == appID }) {
                        continue
                    }
                    openFolder(dir, appID: appID)
                    return
                case "up": goUp(from: dir)
                default: break
            }
        }
        finish()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched by a menu item, the findermenu:// link is delivered before this; otherwise the user opened the app.
        if !handledURL {
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Opened directly, the helper behaves like a regular app (Dock icon, ⌘W, ⌘Q) and quits with its window.
    private func showSettings() {
        if settingsWindow == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.mainMenu = makeMainMenu()
            let controller = SettingsWindowController()
            settingsCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: controller.window,
                queue: .main
            ) { _ in NSApp.terminate(nil) }
            settingsWindow = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Finder Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let main = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }

    /// A menu action is done. Quit, unless the settings window is open.
    private func finish() {
        if settingsWindow == nil {
            NSApp.terminate(nil)
        }
    }

    /// Any app can send a findermenu:// link, and so can a website once the browser asks. Opening a
    /// folder they pick in a terminal or IDE can run code from it (a git-aware prompt, an IDE's
    /// folder-open tasks), so only accept links sent by the extension bundled with this app, matched
    /// by code signature hash. Fails closed if the sender can't be identified (e.g. it has quit).
    private func sentByOurExtension() -> Bool {
        guard let token = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr))?.data,
            let ext = Bundle.main.builtInPlugInsURL?.appendingPathComponent("FinderMenuExtension.appex") else {
            return false
        }
        var sender: SecCode?, bundled: SecStaticCode?, info: CFDictionary?, requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token] as CFDictionary, [], &sender) == errSecSuccess,
              let sender,
              SecStaticCodeCreateWithPath(ext as CFURL, [], &bundled) == errSecSuccess,
              let bundled,
              SecCodeCopySigningInformation(bundled, [], &info) == errSecSuccess,
              let cdhash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              SecRequirementCreateWithString(
                  "cdhash H\"\(cdhash.map { String(format: "%02x", $0) }.joined())\"" as CFString,
                  [],
                  &requirement
              ) == errSecSuccess else {
            return false
        }
        return SecCodeCheckValidity(sender, [], requirement) == errSecSuccess
    }

    /// Only act on existing absolute paths. Files and packages such as .app bundles resolve to the
    /// folder that contains them.
    private func folder(for path: String) -> String? {
        guard path.hasPrefix("/") else {
            return nil
        }
        let path = (path as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return nil
        }
        let dir = isDir.boolValue && !isPackage(path) ? path : (path as NSString).deletingLastPathComponent
        return isPackage(dir) ? nil : dir
    }

    /// Checks the real location, so a symlink to an .app counts as a package too.
    private func isPackage(_ path: String) -> Bool {
        NSWorkspace.shared.isFilePackage(atPath: (path as NSString).resolvingSymlinksInPath)
    }

    /// Moves the Finder window showing `dir` (front-most match, else the front window) up one level.
    private func goUp(from dir: String) {
        func lit(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let parent = (dir as NSString).deletingLastPathComponent
        let script = """
        tell application "Finder"
            set dest to (POSIX file \(lit(parent)) as alias)
            repeat with w in Finder windows
                try
                    if POSIX path of (target of w as alias) is \(lit(dir + "/")) then
                        set target of w to dest
                        return
                    end if
                end try
            end repeat
            if (count of Finder windows) > 0 then set target of front Finder window to dest
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            NSLog("Finder Menu go-up failed: \(error)")
        }
    }

    /// Uses the terminal picked in settings (or with `finder-menu terminal <app>`), otherwise the first installed one.
    private func openTerminal(at dir: String) {
        let ws = NSWorkspace.shared
        for id in [chosenTerminal].compactMap(\.self) + terminals.map(\.id) {
            guard let app = ws.urlForApplication(withBundleIdentifier: id) else {
                continue
            }
            let quit: (NSRunningApplication?, Error?) -> Void = { _, _ in DispatchQueue.main.async { self.finish() } }
            switch terminals.first(where: { $0.id == id })?.launch ?? .openFolder {
                case .openFolder:
                    open(dir, withAppAt: app)
                case let .link(makeURL):
                    guard let url = makeURL(dir) else {
                        finish(); return
                    }
                    ws.open(url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: quit)
                case let .arguments(makeArguments):
                    let config = NSWorkspace.OpenConfiguration()
                    config.arguments = makeArguments(dir)
                    config.createsNewApplicationInstance = true
                    ws.openApplication(at: app, configuration: config, completionHandler: quit)
            }
            return
        }
        finish()
    }

    /// No app ID means "Other App…": let the user pick any app.
    private func openFolder(_ dir: String, appID: String?) {
        if let appID {
            open(dir, withAppAt: NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID))
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Open “\((dir as NSString).lastPathComponent)” with:"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        open(dir, withAppAt: panel.runModal() == .OK ? panel.url : nil)
    }

    private func open(_ dir: String, withAppAt app: URL?) {
        guard let app else {
            finish(); return
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: dir, isDirectory: true)],
            withApplicationAt: app,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in
            DispatchQueue.main.async { self.finish() }
        }
    }

    private func newFile(in dir: String) {
        var name = "untitled.txt"
        var problem: String?
        while true {
            let info = (problem.map { $0 + "\n\n" } ?? "") + "In: " + (dir as NSString).abbreviatingWithTildeInPath
            guard let entered = askFileName(info: info, suggested: name) else {
                return
            }

            name = entered.trimmingCharacters(in: .whitespaces)
            let full = (dir as NSString).appendingPathComponent(name)
            if name.isEmpty || name.contains("/") || name == "." || name == ".." {
                problem = "⚠️ That isn't a valid file name."
            } else if FileManager.default.fileExists(atPath: full) {
                problem = "⚠️ \"\(name)\" already exists."
            } else if !FileManager.default.createFile(atPath: full, contents: nil) {
                problem = "⚠️ Couldn't create the file here (no permission?)."
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
                return
            }
        }
    }

    private func askFileName(info: String, suggested: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "New File"
        alert.informativeText = info
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = suggested
        field.placeholderString = "name.ext"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
