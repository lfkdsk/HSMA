import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var welcomeWC: WelcomeWindowController?
    private var settingsWC: SettingsWindowController?
    private var didBecomeKeyObserver: Any?

    /// Sparkle's turnkey controller: owns the updater and the standard user
    /// interface — the "update available" prompt, download progress, and the
    /// install-and-relaunch. It's configured entirely through the SU* keys in
    /// Info.plist (feed URL, public key, check interval), so there is no other
    /// setup here. Created with `startingUpdater: true`, it runs its own
    /// scheduled background checks; the menu command below just triggers a
    /// manual one.
    private var updaterController: SPUStandardUpdaterController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Instantiate the document controller BEFORE NSDocumentController.shared
        // is touched anywhere else — first instance wins.
        _ = PlateDocumentController()

        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        observeDocumentWindows()

        // Defer to next runloop tick so an Apple-Event-delivered document gets
        // a chance to land in NSDocumentController.documents before we decide.
        DispatchQueue.main.async { [weak self] in
            self?.routeInitialLaunch()
        }

        // Hand update checking to Sparkle: a scheduled background check (daily,
        // per SUScheduledCheckInterval) plus the manual menu command below. It
        // downloads the DMG, verifies its EdDSA and Developer ID signatures,
        // and prompts before installing and relaunching.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// App ▸ Check for Updates… — routed here through the responder chain and
    /// forwarded to Sparkle, which either offers the update or reports that the
    /// app is up to date.
    @objc func checkForUpdatesFromMenu(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    /// App ▸ Settings… (⌘,) — one shared window, created on first use.
    @objc func showSettingsFromMenu(_ sender: Any?) {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.showWindow(sender)
        settingsWC?.window?.makeKeyAndOrderFront(sender)
    }

    /// Reopens the most recent library if one exists, otherwise shows the welcome
    /// window. Skipped entirely if a document was already opened via Apple Event
    /// (e.g. `open foo.plate` or double-click in Finder).
    private func routeInitialLaunch() {
        if !NSDocumentController.shared.documents.isEmpty {
            return
        }

        if let recent = firstReachableRecent() {
            NSDocumentController.shared.openDocument(withContentsOf: recent, display: true) {
                [weak self] doc, _, _ in
                if doc == nil { self?.showWelcome() }
            }
            return
        }

        showWelcome()
    }

    private func firstReachableRecent() -> URL? {
        for url in NSDocumentController.shared.recentDocumentURLs {
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Close the welcome window the moment any library window takes focus.
    private func observeDocumentWindows() {
        didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow,
                  window.windowController is LibraryWindowController else { return }
            self?.welcomeWC?.close()
        }
    }

    private func showWelcome() {
        if welcomeWC == nil {
            welcomeWC = WelcomeWindowController()
        }
        welcomeWC?.showWindow(nil)
        welcomeWC?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock-icon click with no visible windows → bring welcome back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && NSDocumentController.shared.documents.isEmpty {
            showWelcome()
        }
        return false
    }
}
