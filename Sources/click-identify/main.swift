// click-identify — Fase 3: ⌥+clic su una riga del browser di Serato → log della traccia riconosciuta.
// Il clic viene consumato e Serato non lo riceve; nessun audio.
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

func milliseconds(_ interval: TimeInterval) -> String { String(format: "%.0f ms", interval * 1000) }

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

// MARK: - Impostazioni, indice e OCR

let settings: PreviewSettings
do { settings = try PreviewSettings.load() } catch { fail("Impostazioni non valide in \(PreviewSettings.fileURL.path): \(error)") }
print("Impostazioni: \(PreviewSettings.fileURL.path)")
print("  altezza riga \(settings.rowHeight) pt, righe catturate \(settings.captureRows), margini browser "
      + "\(settings.browserInsets.left)/\(settings.browserInsets.top)/\(settings.browserInsets.right)/\(settings.browserInsets.bottom), "
      + "taglio \(settings.truncationGap) pt, punteggio minimo \(settings.minimumScore), OCR \(settings.fastOCR ? "veloce" : "accurato")")

let loadStart = Date()
let matcher: TrackMatcher
do {
    let index = try SeratoLibraryReader().load()
    matcher = TrackMatcher(tracks: index.tracks)
} catch {
    fail("Libreria di Serato non leggibile: \(error)")
}
print("Indice: \(matcher.trackCount) tracce in \(milliseconds(Date().timeIntervalSince(loadStart)))")

let warmUpStart = Date()
TextRecognizer.warmUp(languages: settings.ocrLanguages, fast: settings.fastOCR)
print("OCR pronto in \(milliseconds(Date().timeIntervalSince(warmUpStart)))")

let identifier = RowIdentifier()
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

    let result: Identification
    do {
        result = try await identifier.identify(click, settings: settings, matcher: matcher)
    } catch {
        log.append("  riconoscimento fallito: \(error)")
        return
    }

    if saveImages {
        let url = imagesFolder.appendingPathComponent("riga-\(Int(click.time.timeIntervalSince1970 * 1000)).png")
        try? ImageWriter.writePNG(result.image, to: url)
        log.append("  immagine: \(url.path)")
    }

    log.append("  OCR (cattura \(milliseconds(result.captureDuration)), testo \(milliseconds(result.ocrDuration))): "
               + (result.cells.isEmpty ? "nessun testo" : result.cells.map { "\"\($0.text)\"" + ($0.truncated ? "✂" : "") }.joined(separator: " | ")))
    guard !result.cells.isEmpty else { return }

    let matchTime = milliseconds(result.matchDuration)
    guard let best = result.best(minimumScore: settings.minimumScore) else {
        log.append("  → nessuna traccia sicura (abbinamento \(matchTime))")
        result.matches.forEach { log.append(String(format: "     %.2f  %@", $0.score, describe($0.track))) }
        return
    }

    var verdict = String(format: "  → %@ punteggio %.2f", describe(best.track), best.score)
    if result.matches.count > 1 {
        let second = result.matches[1]
        verdict += String(format: " (seconda %.2f: %@)", second.score, describe(second.track))
        if result.isAmbiguous { verdict += " AMBIGUO" }
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
        let texts = try TextRecognizer.recognize(image, pointSize: frame.size, languages: settings.ocrLanguages, fast: settings.fastOCR)
        log.append("  testi riconosciuti: \(texts.count) in \(milliseconds(Date().timeIntervalSince(ocrStart))) (x, y, larghezza, altezza in punti)")
        for text in texts.sorted(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
            let f = text.frame
            log.append(String(format: "    %5.0f %5.0f %5.0f %4.0f  %@", f.minX, f.minY, f.width, f.height, text.text))
        }
    } catch {
        log.append("  errore: \(error)")
    }
}

// MARK: - Avvio

let interceptor = EventInterceptor(
    modifier: settings.modifier.flags,
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
      ? "Calibrazione: fai \(settings.modifier.symbol)+clic su una riga del browser di Serato. Ctrl-C per uscire.\n"
      : "Pronto: fai \(settings.modifier.symbol)+clic sul titolo di una traccia nel browser di Serato. Ctrl-C per uscire.\n")

CFRunLoopRun()
