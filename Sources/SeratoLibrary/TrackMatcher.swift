import Foundation

// Abbinamento tra il testo letto con l'OCR su una riga del browser e le tracce della libreria.
//
// L'OCR restituisce i pezzi di testo della riga (titolo, artista, BPM, tonalità, …) in un ordine
// e con una suddivisione che dipendono dalle colonne visibili in Serato, quindi il confronto lavora
// sulle parole e non sulle colonne:
// - richiamo: quante parole di titolo e artista della traccia compaiono nella riga;
//   se la riga è troncata ("…") le parole finali mancanti non penalizzano, ma almeno metà
//   delle parole del campo deve essere considerata;
// - precisione: quante parole della riga sono spiegate dalla traccia (anche album, genere,
//   anno, BPM, tonalità, durata), utile per distinguere versioni con lo stesso titolo.
// Le parole si confrontano in modo approssimato (Levenshtein) per tollerare gli errori dell'OCR.
// A parità di punteggio vince un file locale, l'unico che si può ascoltare.

public struct TrackMatch: Sendable {
    public let track: Track
    /// Punteggio complessivo tra 0 e 1.
    public let score: Double
    public let titleRecall: Double
    public let artistRecall: Double?
    public let precision: Double
}

public final class TrackMatcher: @unchecked Sendable {
    private struct Entry {
        let track: Track
        let title: [String]
        let artist: [String]
        let all: [String]
    }

    private let entries: [Entry]
    private let postings: [String: [Int]]

    public var trackCount: Int { entries.count }

    public init(tracks: [Track]) {
        var entries: [Entry] = []
        var postings: [String: [Int]] = [:]
        entries.reserveCapacity(tracks.count)

        for track in tracks {
            let title = Self.tokens(track.title)
            let artist = Self.tokens(track.artist)
            var extra = Self.tokens(track.album) + Self.tokens(track.genre) + Self.tokens(track.year) + Self.tokens(track.key)
            if let bpm = track.bpm, bpm > 0 {
                extra.append(String(Int(bpm)))
                extra.append(String(Int(bpm.rounded())))
            }
            if let length = track.lengthMs {
                extra += Self.tokens(String(format: "%d:%02d", length / 60000, length / 1000 % 60))
            }

            let index = entries.count
            for token in Set(title + artist) { postings[token, default: []].append(index) }
            entries.append(Entry(track: track, title: title, artist: artist, all: Array(Set(title + artist + extra))))
        }

        self.entries = entries
        self.postings = postings
    }

    /// Le migliori tracce per i pezzi di testo di una riga, in ordine di punteggio decrescente.
    public func match(_ cells: [String], limit: Int = 3) -> [TrackMatch] {
        let text = cells.joined(separator: " ")
        let truncated = text.contains("…") || text.contains("...")
        let rowTokens = Self.tokens(text)
        guard !rowTokens.isEmpty else { return [] }

        // Candidati: tracce che condividono almeno una parola esatta, pesata per rarità.
        var weights: [Int: Double] = [:]
        let total = Double(max(entries.count, 1))
        for token in Set(rowTokens) {
            guard let list = postings[token] else { continue }
            let weight = log(total / Double(list.count)) + 0.1
            for index in list { weights[index, default: 0] += weight }
        }
        let candidates = weights.sorted { $0.value > $1.value }.prefix(150).map(\.key)

        return candidates
            .map { score(entries[$0], rowTokens: rowTokens, truncated: truncated) }
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 1e-9 { return lhs.score > rhs.score }
                return lhs.track.path != nil && rhs.track.path == nil
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Punteggio

    private func score(_ entry: Entry, rowTokens: [String], truncated: Bool) -> TrackMatch {
        let titleRecall = Self.recall(entry.title, in: rowTokens, truncated: truncated) ?? 0
        let artistRecall = Self.recall(entry.artist, in: rowTokens, truncated: truncated)
        let recall = artistRecall.map { 0.65 * titleRecall + 0.35 * $0 } ?? titleRecall

        let explained = rowTokens.filter { row in
            entry.all.contains { Self.same($0, row, allowPrefix: truncated) }
        }.count
        let precision = Double(explained) / Double(rowTokens.count)

        return TrackMatch(
            track: entry.track,
            score: 0.75 * recall + 0.25 * precision,
            titleRecall: titleRecall,
            artistRecall: artistRecall,
            precision: precision
        )
    }

    private static func recall(_ field: [String], in row: [String], truncated: Bool) -> Double? {
        guard !field.isEmpty else { return nil }
        let matched = field.map { token in row.contains { same(token, $0, allowPrefix: truncated) } }
        var considered = matched.count
        if truncated {
            let lastMatched = matched.lastIndex(of: true).map { $0 + 1 } ?? 0
            let minimum = Int((Double(matched.count) / 2).rounded(.up))
            considered = max(lastMatched, minimum)
        }
        return Double(matched.prefix(considered).filter { $0 }.count) / Double(considered)
    }

    /// `token` viene dalla libreria, `row` dall'OCR.
    private static func same(_ token: String, _ row: String, allowPrefix: Bool) -> Bool {
        if token == row { return true }
        if allowPrefix && row.count >= 3 && token.hasPrefix(row) { return true }
        let longest = max(token.count, row.count)
        guard longest >= 4 else { return false }
        let allowed = longest >= 8 ? 2 : 1
        guard abs(token.count - row.count) <= allowed else { return false }
        return levenshtein(Array(token.unicodeScalars), Array(row.unicodeScalars)) <= allowed
    }

    private static func levenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - Normalizzazione

    /// Minuscole, senza accenti, punteggiatura sostituita da spazi.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            result.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        return String(result)
    }

    /// Parole di almeno 2 caratteri.
    public static func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init).filter { $0.count >= 2 }
    }
}
