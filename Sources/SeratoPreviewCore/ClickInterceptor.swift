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

/// Event tap globale. Un clic sinistro con il modificatore su una finestra normale di Serato,
/// se `accepts` lo approva, viene consumato insieme ai trascinamenti e al rilascio che lo seguono,
/// e passato a `onClick`. Ogni altro evento arriva a Serato invariato.
/// Richiede il permesso Accessibilità.
public final class ClickInterceptor {
    public enum StartError: Error, CustomStringConvertible {
        case tapUnavailable

        public var description: String {
            "Impossibile creare l'event tap: concedi il permesso Accessibilità a questa app o al Terminale."
        }
    }

    private let bundleID: String
    private let modifier: CGEventFlags
    private let accepts: (SeratoClick) -> Bool
    private let onClick: (SeratoClick) -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowing = false
    private var serato: NSRunningApplication?

    public init(bundleID: String = "com.serato.seratodj",
                modifier: CGEventFlags = .maskAlternate,
                accepts: @escaping (SeratoClick) -> Bool = { _ in true },
                onClick: @escaping (SeratoClick) -> Void) {
        self.bundleID = bundleID
        self.modifier = modifier
        self.accepts = accepts
        self.onClick = onClick
    }

    deinit { stop() }

    public func start() throws {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
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
            guard hasOnlyModifier(event.flags),
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

        default:
            return pass
        }
    }

    private func hasOnlyModifier(_ flags: CGEventFlags) -> Bool {
        let relevant: [CGEventFlags] = [.maskAlternate, .maskCommand, .maskControl, .maskShift]
        return relevant.allSatisfy { flags.contains($0) == modifier.contains($0) }
    }

    private func seratoPID() -> pid_t? {
        if serato == nil || serato?.isTerminated == true {
            serato = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        return serato?.processIdentifier
    }

    /// La finestra più in alto sotto il punto, se è una finestra normale (livello 0) di `pid`.
    /// Menu e popup di Serato hanno un livello diverso e non vengono intercettati.
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

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ClickInterceptor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}
