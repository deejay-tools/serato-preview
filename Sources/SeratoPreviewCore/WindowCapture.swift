import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Cattura una porzione di una finestra con ScreenCaptureKit, anche se coperta da altre finestre.
/// Richiede il permesso Registrazione schermo.
public actor WindowCapture {
    public enum CaptureError: Error, CustomStringConvertible {
        case windowNotFound(CGWindowID)
        case emptyRect

        public var description: String {
            switch self {
            case .windowNotFound(let id): return "Finestra \(id) non disponibile per la cattura."
            case .emptyRect: return "Area di cattura vuota."
            }
        }
    }

    private var windows: [CGWindowID: SCWindow] = [:]

    public init() {}

    /// `rect` e `windowFrame` sono in coordinate globali (punti, origine in alto a sinistra).
    public func capture(windowID: CGWindowID, windowFrame: CGRect, rect: CGRect) async throws -> CGImage {
        let window = try await scWindow(windowID)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)

        let local = rect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
            .intersection(CGRect(origin: .zero, size: windowFrame.size))
        guard !local.isNull, local.width >= 1, local.height >= 1 else { throw CaptureError.emptyRect }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = local
        configuration.width = Int((local.width * scale).rounded())
        configuration.height = Int((local.height * scale).rounded())
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func scWindow(_ id: CGWindowID) async throws -> SCWindow {
        if let window = windows[id] { return window }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        guard let window = windows[id] else { throw CaptureError.windowNotFound(id) }
        return window
    }
}

public enum ImageWriter {
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
