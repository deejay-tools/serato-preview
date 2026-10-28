import AppKit
import SwiftUI
import SeratoPreviewCore

/// App nella barra dei menu: icona con menu, mini-player e finestra impostazioni.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = PreviewController()
    private var statusItem: NSStatusItem!
    private var miniPlayer: MiniPlayerPanel!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Serato Preview")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        miniPlayer = MiniPlayerPanel(controller: controller)
        controller.start()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabledItem(statusLine))
        menu.addItem(disabledItem(controller.libraryDescription))
        if !controller.missingPermissions.isEmpty {
            menu.addItem(disabledItem("Permessi mancanti: " + controller.missingPermissions.joined(separator: ", ")))
            if controller.missingPermissions.contains("Accessibilità") {
                menu.addItem(item("Apri impostazioni Accessibilità…", #selector(openAccessibilitySettings)))
            }
            if controller.missingPermissions.contains("Registrazione schermo") {
                menu.addItem(item("Apri impostazioni Registrazione schermo…", #selector(openScreenRecordingSettings)))
            }
        }
        menu.addItem(.separator())

        let enabled = item("Attivo (\(controller.settings.modifier.symbol)+clic)", #selector(toggleEnabled))
        enabled.state = controller.isEnabled ? .on : .off
        menu.addItem(enabled)
        let stop = item("Ferma anteprima", #selector(stopPreview))
        stop.isEnabled = controller.isPreviewing
        menu.addItem(stop)
        menu.addItem(.separator())

        menu.addItem(item("Impostazioni…", #selector(openSettings), key: ","))
        menu.addItem(item("Ricarica libreria", #selector(reloadLibrary)))
        menu.addItem(.separator())
        menu.addItem(item("Esci da Serato Preview", #selector(quit), key: "q"))
    }

    private var statusLine: String {
        switch controller.status {
        case .playing(let title, _): return "In ascolto: \(title)"
        case .identifying: return "Riconosco la traccia…"
        default: return controller.isEnabled ? "Pronto" : "Disattivato"
        }
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
            window.title = "Impostazioni Serato Preview"
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
