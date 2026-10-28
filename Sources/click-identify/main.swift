// click-identify — Fase 3: ⌥+clic su una riga del browser di Serato → log della traccia riconosciuta.
// Il clic viene consumato e Serato non lo riceve; per ora nessun audio.
//
// Uso (dal Terminale, con permessi Accessibilità e Registrazione schermo):
//   swift run click-identify               log di ogni ⌥+clic
//   swift run click-identify --save        salva anche l'immagine catturata di ogni clic
//   swift run click-identify --calibrate   ⌥+clic ovunque nella finestra: cattura tutta la finestra,
//                                          stampa i testi con le coordinate e salva l'immagine
// Ctrl-C per uscire.

import AppKit
import Foundation
import SeratoLibrary
import SeratoPreviewCore

let arguments = CommandLine.arguments
let calibrate = arguments.contains("--calibrate")
let saveImages = arguments.contains("--save") || calibrate
let imagesFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SeratoPreview")

setvbuf(stdout, nil, _IOLBF, 0)

func milliseconds(_ start: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000) }

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

// MARK: - Permessi

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
    fail("Manca il permesso Accessibilità: Impostazioni di Sistema → Privacy e sicurezza → Accessibilità, poi rilancia.")
}
guard CGPreflightScreenCaptureAccess() else {
    CGRequestScreenCaptureAccess()
    fail("""
    Manca il permesso Registrazione schermo: Impostazioni di Sistema → Privacy e sicurezza →
    Registrazione schermo e audio di sistema, abilita il Terminale, chiudilo e riaprilo, poi rilancia.
    """)
}

// MARK: - Impostazioni e indice

let settings: PreviewSettings
do { settings = try PreviewSettings.load() } catch { fail("Impostazioni non valide in \(PreviewSettings.fileURL.path): \(error)") }
print("Impostazioni: \(PreviewSettings.fileURL.path)")
print("  altezza riga \(settings.rowHeight) pt, righe catturate \(settings.captureRows), margini browser "
      + "\(settings.browserInsets.left)/\(settings.browserInsets.top)/\(settings.browserInsets.right)/\(settings.browserInsets.bottom), "
      + "punteggio minimo \(settings.minimumScore)")

let loadStart = Date()
let matcher: TrackMatcher
do {
    let index = try SeratoLibraryReader().load()
    matcher = TrackMatcher(tracks: index.tracks)
} catch {
    fail("Libreria di Serato non leggibile: \(error)")
}
print("Indice: \(matcher.trackCount) tracce in \(milliseconds(loadStart))")

let capture = WindowCapture()

// MARK: - Gestione del clic

func describe(_ track: Track) -> String {
    let artist = track.artist.isEmpty ? "" : " — \(track.artist)"
    let kind: String
    switch track.source {
    case .file: kind = "file"
    case .streaming: kind = "streaming"
    case .unresolved: kind = "disco non collegato"
    }
    return "\(track.title)\(artist) [\(kind)]"
}

func identify(_ click: SeratoClick) async {
    var log = ["[\(timestamp())] ⌥+clic (\(Int(click.location.x)), \(Int(click.location.y)))"]
    defer { print(log.joined(separator: "\n") + "\n") }

    // Banda di `captureRows` righe centrata sul clic, larga quanto l'area del browser.
    let browser = settings.browserRect(in: click.windowFrame)
    let height = settings.rowHeight * settings.captureRows
    let band = CGRect(x: browser.minX, y: click.location.y - height / 2, width: browser.width, height: height)
        .intersection(click.windowFrame)

    let captureStart = Date()
    let image: CGImage
    do {
        image = try await capture.capture(windowID: click.windowID, windowFrame: click.windowFrame, rect: band)
    } catch {
        log.append("  cattura fallita: \(error)")
        return
    }
    let captureTime = milliseconds(captureStart)

    if saveImages {
        let url = imagesFolder.appendingPathComponent("riga-\(Int(click.time.timeIntervalSince1970 * 1000)).png")
        try? ImageWriter.writePNG(image, to: url)
        log.append("  immagine: \(url.path)")
    }

    let ocrStart = Date()
    let texts: [RecognizedText]
    do {
        texts = try TextRecognizer.recognize(image, pointSize: band.size, languages: settings.ocrLanguages)
    } catch {
        log.append("  OCR fallito: \(error)")
        return
    }
    let line = TextRecognizer.line(in: texts, nearY: click.location.y - band.minY, tolerance: settings.rowHeight * 0.4)
    log.append("  OCR (cattura \(captureTime), testo \(milliseconds(ocrStart))): "
               + (line.isEmpty ? "nessun testo" : line.map { "\"\($0.text)\"" }.joined(separator: " | ")))
    guard !line.isEmpty else { return }

    let matchStart = Date()
    let matches = matcher.match(line.map(\.text))
    let matchTime = milliseconds(matchStart)

    guard let best = matches.first, best.score >= settings.minimumScore else {
        log.append("  → nessuna traccia sicura (abbinamento \(matchTime))")
        matches.forEach { log.append(String(format: "     %.2f  %@", $0.score, describe($0.track))) }
        return
    }

    var verdict = String(format: "  → %@ punteggio %.2f", describe(best.track), best.score)
    if matches.count > 1 {
        let second = matches[1]
        verdict += String(format: " (seconda %.2f: %@)", second.score, describe(second.track))
        // Lo stesso brano in due cartelle non è un'ambiguità: un file vale l'altro.
        let sameSong = TrackMatcher.normalize(best.track.title + " " + best.track.artist)
            == TrackMatcher.normalize(second.track.title + " " + second.track.artist)
        if best.score - second.score < 0.05 && !sameSong { verdict += " AMBIGUO" }
    }
    log.append(verdict + " (abbinamento \(matchTime))")

    switch best.track.source {
    case .file(let path):
        log.append("  → \(path)" + (FileManager.default.fileExists(atPath: path) ? "" : " (FILE NON TROVATO)"))
    case .streaming:
        log.append("  → traccia in streaming: anteprima non disponibile")
    case .unresolved(let location, let portable):
        log.append("  → disco della location \(location) non collegato: \(portable)")
    }
}

func calibrate(_ click: SeratoClick) async {
    var log = ["[\(timestamp())] CALIBRAZIONE ⌥+clic"]
    defer { print(log.joined(separator: "\n") + "\n") }

    let frame = click.windowFrame
    log.append("  finestra: origine (\(Int(frame.minX)), \(Int(frame.minY))), dimensione \(Int(frame.width))×\(Int(frame.height))")
    log.append("  clic relativo alla finestra: (\(Int(click.location.x - frame.minX)), \(Int(click.location.y - frame.minY)))")

    do {
        let image = try await capture.capture(windowID: click.windowID, windowFrame: frame, rect: frame)
        let url = imagesFolder.appendingPathComponent("finestra-\(Int(click.time.timeIntervalSince1970 * 1000)).png")
        try ImageWriter.writePNG(image, to: url)
        log.append("  immagine: \(url.path) (\(image.width)×\(image.height) px)")

        let ocrStart = Date()
        let texts = try TextRecognizer.recognize(image, pointSize: frame.size, languages: settings.ocrLanguages)
        log.append("  testi riconosciuti: \(texts.count) in \(milliseconds(ocrStart)) (x, y, larghezza, altezza in punti)")
        for text in texts.sorted(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
            let f = text.frame
            log.append(String(format: "    %5.0f %5.0f %5.0f %4.0f  %@", f.minX, f.minY, f.width, f.height, text.text))
        }
    } catch {
        log.append("  errore: \(error)")
    }
}

// MARK: - Avvio

let interceptor = ClickInterceptor(
    accepts: { click in
        calibrate || settings.browserRect(in: click.windowFrame).contains(click.location)
    },
    onClick: { click in
        Task { calibrate ? await calibrate(click) : await identify(click) }
    }
)

do { try interceptor.start() } catch { fail("\(error)") }

if NSRunningApplication.runningApplications(withBundleIdentifier: "com.serato.seratodj").isEmpty {
    print("Attenzione: Serato non è aperto. Lo aspetto…")
}
print(calibrate
      ? "Calibrazione: fai ⌥+clic su una riga del browser di Serato. Ctrl-C per uscire.\n"
      : "Pronto: fai ⌥+clic sul titolo di una traccia nel browser di Serato. Ctrl-C per uscire.\n")

CFRunLoopRun()
