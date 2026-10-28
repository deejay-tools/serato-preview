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

/// Cattura della riga sotto il clic, OCR e abbinamento all'indice.
public final class RowIdentifier {
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

        let ocrStart = Date()
        let texts = try TextRecognizer.recognize(image, pointSize: band.size, languages: settings.ocrLanguages, fast: settings.fastOCR)
        let line = TextRecognizer.line(in: texts, nearY: click.location.y - band.minY, tolerance: settings.rowHeight * 0.4)
        let cells = TextRecognizer.cells(line, rightEdge: band.width, truncationGap: settings.truncationGap)
        let ocrDuration = Date().timeIntervalSince(ocrStart)

        let matchStart = Date()
        let matches = cells.isEmpty ? [] : matcher.match(cells)
        let matchDuration = Date().timeIntervalSince(matchStart)

        return Identification(cells: cells, matches: matches, image: image, captureDuration: captureDuration,
                              ocrDuration: ocrDuration, matchDuration: matchDuration)
    }
}
