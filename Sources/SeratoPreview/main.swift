// Serato Preview — anteprima in cuffia dal browser di Serato DJ Pro con ⌥+clic.
// App nella barra dei menu, senza icona nel Dock. Si impacchetta con Scripts/build-app.sh.

import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
