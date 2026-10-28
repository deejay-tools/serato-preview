import AppKit
import CoreGraphics

/// Un clic con il modificatore su una finestra di Serato.
public struct SeratoClick: Sendable {
    /// Coordinate globali in punti, origine in alto a sinistra (come CGEvent e CGWindowList).
    public let location: CGPoint
    public let windowID: CGWindowID
    public let windowFrame: CGRect
    public let time: Date
}

/// La finestra principale di Serato, per il tasto che ascolta la riga selezionata.
public struct SeratoWindow: Sendable {
    public let id: CGWindowID
    /// Coordinate globali in punti, origine in alto a sinistra.
    public let frame: CGRect
}

/// Un tasto premuto, anche per ripetizione automatica.
public struct KeyPress {
    public enum Key {
        case up
        case left
        case right
    }

    public let key: Key
    /// Premuto senza ⌘, ⌥, ⌃ né ⇧.
    public let isPlain: Bool
}

/// Event tap globale. Richiede il permesso Accessibilità.
/// - Clic sinistro con il modificatore su una finestra normale di Serato: se `accepts` lo approva
///   viene consumato, insieme ai trascinamenti e al rilascio che lo seguono, e passato a `onClick`.
/// - ↓ con il modificatore, quando Serato è in primo piano: viene consumato e passato a `onSelectedRow`
///   con la finestra principale di Serato.
/// - ↑, ← e → vengono offerti a `onKey`, che decide se consumarli.
/// Ogni altro evento arriva a destinazione invariato. Le callback girano sul main thread.
public final class EventInterceptor {
    public enum StartError: Error, CustomStringConvertible {
        case tapUnavailable

        public var description: String {
            "Impossibile creare l'event tap: concedi il permesso Accessibilità a questa app o al Terminale."
        }
    }

    public var isEnabled = true
    public var modifier: CGEventFlags
    public var accepts: (SeratoClick) -> Bool
    public var onClick: (SeratoClick) -> Void
    /// Tasto premuto: restituire true per consumarlo.
    public var onKey: (KeyPress) -> Bool = { _ in false }
    public var onSelectedRow: (SeratoWindow) -> Void = { _ in }

    public var isRunning: Bool { tap != nil }

    private let bundleID: String
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowing = false
    private var serato: NSRunningApplication?

    private static let keys: [Int64: KeyPress.Key] = [126: .up, 123: .left, 124: .right]
    private static let downKey: Int64 = 125
    private static let modifierMasks: [CGEventFlags] = [.maskAlternate, .maskCommand, .maskControl, .maskShift]

    public init(bundleID: String = "com.serato.seratodj",
                modifier: CGEventFlags = .maskAlternate,
                accepts: @escaping (SeratoClick) -> Bool = { _ in true },
                onClick: @escaping (SeratoClick) -> Void = { _ in }) {
        self.bundleID = bundleID
        self.modifier = modifier
        self.accepts = accepts
        self.onClick = onClick
    }

    deinit { stop() }

    public func start() throws {
        guard tap == nil else { return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw StartError.tapUnavailable }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .leftMouseDown:
            guard isEnabled,
                  hasOnlyModifier(event.flags),
                  let pid = seratoPID(),
                  let window = Self.window(at: event.location, ownedBy: pid) else { return pass }
            let click = SeratoClick(location: event.location, windowID: window.id, windowFrame: window.frame, time: Date())
            guard accepts(click) else { return pass }
            swallowing = true
            onClick(click)
            return nil

        case .leftMouseDragged:
            return swallowing ? nil : pass

        case .leftMouseUp:
            guard swallowing else { return pass }
            swallowing = false
            return nil

        case .keyDown:
            if isEnabled, event.getIntegerValueField(.keyboardEventKeycode) == Self.downKey, hasOnlyModifier(event.flags),
               let pid = seratoPID(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
               let window = Self.mainWindow(ownedBy: pid) {
                onSelectedRow(window)
                return nil
            }
            guard isEnabled, let key = Self.keys[event.getIntegerValueField(.keyboardEventKeycode)] else { return pass }
            let isPlain = Self.modifierMasks.allSatisfy { !event.flags.contains($0) }
            return onKey(KeyPress(key: key, isPlain: isPlain)) ? nil : pass

        default:
            return pass
        }
    }

    /// La finestra principale di Serato, se è aperto. Per i comandi che non arrivano dalla tastiera.
    public func seratoMainWindow() -> SeratoWindow? {
        seratoPID().flatMap(Self.mainWindow(ownedBy:))
    }

    private func hasOnlyModifier(_ flags: CGEventFlags) -> Bool {
        Self.modifierMasks.allSatisfy { flags.contains($0) == modifier.contains($0) }
    }

    private func seratoPID() -> pid_t? {
        if serato == nil || serato?.isTerminated == true {
            serato = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        return serato?.processIdentifier
    }

    /// La finestra più in alto sotto il punto, se è una finestra normale (livello 0) di `pid`.
    /// Menu e popup di Serato hanno un livello diverso e non vengono intercettati; nemmeno le
    /// finestre di altre app sopra Serato, come il mini-player.
    static func window(at point: CGPoint, ownedBy pid: pid_t) -> (id: CGWindowID, frame: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.contains(point) else { continue }
            if (info[kCGWindowAlpha as String] as? Double ?? 1) <= 0 { continue }
            let owner = info[kCGWindowOwnerPID as String] as? pid_t
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            // Sovrapposizioni trasparenti di sistema o di altre app molto in alto: si ignorano.
            if owner != pid && layer >= 1000 { continue }
            guard owner == pid, layer == 0, let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return (id, bounds)
        }
        return nil
    }
}

extension EventInterceptor {
    /// La finestra normale (livello 0) più grande di `pid` sullo schermo.
    static func mainWindow(ownedBy pid: pid_t) -> SeratoWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return list.compactMap { info -> SeratoWindow? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int ?? 0 == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return SeratoWindow(id: id, frame: bounds)
        }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventInterceptor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}
