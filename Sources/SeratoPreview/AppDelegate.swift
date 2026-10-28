import AppKit
import Combine
import SwiftUI
import SeratoPreviewCore

/// App nella barra dei menu: icona con menu, mini-player e finestra impostazioni.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = PreviewController()
    private var statusItem: NSStatusItem!
    private var miniPlayer: MiniPlayerPanel!
    private var settingsWindow: NSWindow?
    private var settingsCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Serato Preview")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        miniPlayer = MiniPlayerPanel(controller: controller)
        // Il titolo della finestra segue la lingua quando si salvano le impostazioni.
        settingsCancellable = controller.$settings.sink { [weak self] _ in
            self?.settingsWindow?.title = Self.settingsWindowTitle
        }
        controller.start()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabledItem(statusLine))
        menu.addItem(disabledItem(controller.libraryDescription))
        if !controller.missingPermissions.isEmpty {
            let names = controller.missingPermissions.map(\.name).joined(separator: ", ")
            menu.addItem(disabledItem(tr("Permessi mancanti: ", "Missing permissions: ") + names))
            if controller.missingPermissions.contains(.accessibility) {
                menu.addItem(item(tr("Apri impostazioni Accessibilità…", "Open Accessibility settings…"),
                                  #selector(openAccessibilitySettings)))
            }
            if controller.missingPermissions.contains(.screenRecording) {
                menu.addItem(item(tr("Apri impostazioni Registrazione schermo…", "Open Screen Recording settings…"),
                                  #selector(openScreenRecordingSettings)))
            }
        }
        menu.addItem(.separator())

        let symbol = controller.settings.modifier.symbol
        let enabled = item(tr("Attivo (\(symbol)+clic)", "Enabled (\(symbol)+click)"), #selector(toggleEnabled))
        enabled.state = controller.isEnabled ? .on : .off
        menu.addItem(enabled)
        let stop = item(tr("Ferma anteprima", "Stop preview"), #selector(stopPreview))
        stop.isEnabled = controller.isPreviewing
        menu.addItem(stop)
        menu.addItem(.separator())

        menu.addItem(item(tr("Impostazioni…", "Settings…"), #selector(openSettings), key: ","))
        menu.addItem(item(tr("Ricarica libreria", "Reload library"), #selector(reloadLibrary)))
        menu.addItem(.separator())
        menu.addItem(item(tr("Esci da Serato Preview", "Quit Serato Preview"), #selector(quit), key: "q"))
    }

    private var statusLine: String {
        switch controller.status {
        case .playing(let title, _): return tr("In ascolto: ", "Playing: ") + title
        case .identifying: return tr("Riconosco la traccia…", "Recognizing the track…")
        default: return controller.isEnabled ? tr("Pronto", "Ready") : tr("Disattivato", "Disabled")
        }
    }

    private static var settingsWindowTitle: String {
        tr("Impostazioni Serato Preview", "Serato Preview Settings")
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Azioni

    @objc private func toggleEnabled() {
        controller.isEnabled.toggle()
    }

    @objc private func stopPreview() {
        controller.stopPreview()
    }

    @objc private func reloadLibrary() {
        controller.reloadLibrary()
    }

    @objc private func openSettings() {
        // Contenuto ricreato a ogni apertura, così la bozza riparte dalle impostazioni salvate.
        let hosting = NSHostingController(rootView: SettingsView(controller: controller))
        if let settingsWindow {
            settingsWindow.contentViewController = hosting
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = Self.settingsWindowTitle
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @objc private func quit() {
        controller.stopPreview()
        NSApp.terminate(nil)
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}
