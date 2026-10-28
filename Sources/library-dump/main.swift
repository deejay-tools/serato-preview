// library-dump — Fase 2: carica la libreria di Serato e stampa statistiche, campioni e tempi.
//
// Uso:
//   swift run library-dump                      riepilogo + 10 campioni + verifica di 300 file
//   swift run library-dump --search "testo"     tracce il cui titolo o artista contiene il testo
//   swift run library-dump --samples 20 --check 1000
//   swift run library-dump --match "In my eyes|Milk Inc.|139.0|Am"
//                                               abbinamento di una riga come la leggerebbe l'OCR
//                                               (pezzi separati da |)

import Foundation
import SeratoLibrary

let arguments = CommandLine.arguments

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func milliseconds(_ interval: TimeInterval) -> String { String(format: "%.0f ms", interval * 1000) }

func describe(_ track: Track) -> String {
    var parts = ["\(track.title) — \(track.artist)"]
    if let bpm = track.bpm, bpm > 0 { parts.append(String(format: "%.1f BPM", bpm)) }
    if !track.key.isEmpty { parts.append(track.key) }
    if let length = track.lengthMs { parts.append(String(format: "%d:%02d", length / 60000, length / 1000 % 60)) }
    switch track.source {
    case .file(let path): parts.append(path)
    case .streaming(let uri): parts.append(uri)
    case .unresolved(let location, let portable): parts.append("[location \(location) non collegata] \(portable)")
    }
    return parts.joined(separator: " | ")
}

let index: LibraryIndex
do {
    index = try SeratoLibraryReader().load()
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}

// MARK: - Abbinamento di prova

if let row = option("--match") {
    let buildStart = Date()
    let matcher = TrackMatcher(tracks: index.tracks)
    print("Indice per l'abbinamento: \(milliseconds(Date().timeIntervalSince(buildStart)))")

    let cells = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    let matchStart = Date()
    let matches = matcher.match(cells, limit: 5)
    print("Riga: \(cells.map { "\"\($0)\"" }.joined(separator: " | ")) (\(milliseconds(Date().timeIntervalSince(matchStart))))")
    for match in matches {
        let artist = match.artistRecall.map { String(format: "%.2f", $0) } ?? "-"
        print(String(format: "  %.2f (titolo %.2f, artista %@, precisione %.2f)  ", match.score, match.titleRecall, artist, match.precision)
              + describe(match.track))
    }
    exit(0)
}

// MARK: - Riepilogo

let tracks = index.tracks
let files = tracks.filter { $0.path != nil }
let streaming = tracks.filter { if case .streaming = $0.source { return true } else { return false } }
let unresolved = tracks.filter { if case .unresolved = $0.source { return true } else { return false } }

print("=== Libreria Serato ===")
print("Copia di master.sqlite: \(milliseconds(index.snapshotDuration)), lettura: \(milliseconds(index.queryDuration))")
print("Tracce totali: \(tracks.count)")
print("  file locali: \(files.count)")
print("  streaming: \(streaming.count)")
print("  su dischi non collegati: \(unresolved.count)")
print("  segnalate mancanti da Serato: \(tracks.filter(\.isMissing).count)")

print("\nLocation:")
for location in index.locations {
    let count = tracks.filter {
        switch $0.source {
        case .unresolved(let id, _): return id == location.id
        default: return false
        }
    }.count
    let uuid = location.uuid.map { $0.map { String(format: "%02X", $0) }.joined() } ?? "-"
    let root = location.root ?? (count > 0 ? "NON TROVATA (\(count) tracce)" : "-")
    print("  [\(location.id)] \(uuid.prefix(8))… → \(root)")
}

// MARK: - Ricerca o campioni

if let query = option("--search") {
    let matches = tracks.filter {
        $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
    }
    print("\nRisultati per \"\(query)\": \(matches.count)")
    matches.prefix(50).forEach { print("  " + describe($0)) }
} else {
    let sampleCount = Int(option("--samples") ?? "") ?? 10
    print("\nCampioni (file locali):")
    files.shuffled().prefix(sampleCount).forEach { print("  " + describe($0)) }
    print("\nCampioni (streaming):")
    streaming.shuffled().prefix(3).forEach { print("  " + describe($0)) }
}

// MARK: - Verifica esistenza file

let checkCount = min(Int(option("--check") ?? "") ?? 300, files.count)
if checkCount > 0 {
    let start = Date()
    let sample = files.shuffled().prefix(checkCount)
    let missing = sample.filter { !FileManager.default.fileExists(atPath: $0.path!) }
    print("\nVerifica esistenza su \(checkCount) file a caso: \(checkCount - missing.count) trovati, \(missing.count) mancanti (\(milliseconds(Date().timeIntervalSince(start))))")
    missing.prefix(10).forEach { print("  mancante: \($0.path!)") }
}
