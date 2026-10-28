import CoreGraphics
import Foundation
import SeratoLibrary

/// Risultato del riconoscimento della riga cliccata.
public struct Identification {
    public let cells: [RowCell]
    /// In ordine di punteggio decrescente.
    public let matches: [TrackMatch]
    public let image: CGImage
    public let captureDuration: TimeInterval
    public let ocrDuration: TimeInterval
    public let matchDuration: TimeInterval

    public var text: String { cells.map(\.text).joined(separator: " | ") }

    public func best(minimumScore: Double) -> TrackMatch? {
        guard let first = matches.first, first.score >= minimumScore else { return nil }
        return first
    }

    /// Le prime due tracce sono brani diversi con punteggi quasi uguali. Lo stesso brano in due
    /// cartelle non conta: per l'anteprima un file vale l'altro.
    public var isAmbiguous: Bool {
        guard matches.count > 1 else { return false }
        let first = matches[0], second = matches[1]
        let sameSong = TrackMatcher.normalize(first.track.title + " " + first.track.artist)
            == TrackMatcher.normalize(second.track.title + " " + second.track.artist)
        return first.score - second.score < 0.05 && !sameSong
    }
}

/// Cattura della riga sotto il clic, o di quella selezionata, OCR e abbinamento all'indice.
public final class RowIdentifier {
    public enum SelectionError: Error, CustomStringConvertible {
        /// Nessuna riga evidenziata visibile; `bands` descrive le fasce di colore trovate.
        case notFound(bands: String)

        public var description: String {
            switch self {
            case .notFound(let bands): return "Nessuna riga selezionata visibile nel browser. Fasce: \(bands)"
            }
        }
    }

    private let capture = WindowCapture()

    public init() {}

    public func identify(_ click: SeratoClick, settings: PreviewSettings, matcher: TrackMatcher) async throws -> Identification {
        // Fascia di `captureRows` righe centrata sul clic, larga quanto l'area del browser.
        let browser = settings.browserRect(in: click.windowFrame)
        let height = settings.rowHeight * settings.captureRows
        let band = CGRect(x: browser.minX, y: click.location.y - height / 2, width: browser.width, height: height)
            .intersection(click.windowFrame)

        let captureStart = Date()
        let image = try await capture.capture(windowID: click.windowID, windowFrame: click.windowFrame, rect: band)
        let captureDuration = Date().timeIntervalSince(captureStart)

        return try recognize(image, band: band, rowY: click.location.y - band.minY, captureDuration: captureDuration,
                             settings: settings, matcher: matcher)
    }

    /// Riga evidenziata nel browser: cattura tutta la lista, trova la selezione e legge solo quella fascia.
    /// `debugImage`, se indicato, riceve la cattura dell'intera lista.
    public func identifySelected(in window: SeratoWindow, settings: PreviewSettings, matcher: TrackMatcher,
                                 debugImage: URL? = nil) async throws -> Identification {
        let browser = settings.browserRect(in: window.frame).intersection(window.frame)

        let captureStart = Date()
        let image = try await capture.capture(windowID: window.id, windowFrame: window.frame, rect: browser)
        if let debugImage { try? ImageWriter.writePNG(image, to: debugImage) }
        let scale = Double(image.height) / browser.height
        let found = SelectedRowFinder.find(in: image, rowHeightPixels: settings.rowHeight * scale)
        guard let selected = found.selected else {
            throw SelectionError.notFound(bands: found.bands.map(\.description).joined(separator: ", "))
        }

        // Ritaglio di `captureRows` righe centrato sulla selezione, come per il clic.
        let rowY = selected.center / scale
        let height = settings.rowHeight * settings.captureRows
        let top = max(rowY - height / 2, 0), bottom = min(rowY + height / 2, browser.height)
        let pixelRect = CGRect(x: 0, y: (top * scale).rounded(), width: Double(image.width),
                               height: ((bottom - top) * scale).rounded())
        guard let crop = image.cropping(to: pixelRect) else { throw WindowCapture.CaptureError.emptyRect }
        let band = CGRect(x: browser.minX, y: browser.minY + top, width: browser.width, height: bottom - top)
        let captureDuration = Date().timeIntervalSince(captureStart)

        return try recognize(crop, band: band, rowY: rowY - top, captureDuration: captureDuration,
                             settings: settings, matcher: matcher)
    }

    /// `rowY`: centro della riga cercata, in punti dall'alto di `band`.
    private func recognize(_ image: CGImage, band: CGRect, rowY: CGFloat, captureDuration: TimeInterval,
                           settings: PreviewSettings, matcher: TrackMatcher) throws -> Identification {
        let ocrStart = Date()
        let texts = try TextRecognizer.recognize(image, pointSize: band.size, languages: settings.ocrLanguages, fast: settings.fastOCR)
        let line = TextRecognizer.line(in: texts, nearY: rowY, tolerance: settings.rowHeight * 0.4)
        let cells = TextRecognizer.cells(line, rightEdge: band.width, truncationGap: settings.truncationGap)
        let ocrDuration = Date().timeIntervalSince(ocrStart)

        let matchStart = Date()
        let matches = cells.isEmpty ? [] : matcher.match(cells)
        let matchDuration = Date().timeIntervalSince(matchStart)

        return Identification(cells: cells, matches: matches, image: image, captureDuration: captureDuration,
                              ocrDuration: ocrDuration, matchDuration: matchDuration)
    }
}
