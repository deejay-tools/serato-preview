import Foundation

// Abbinamento tra il testo letto con l'OCR su una riga del browser e le tracce della libreria.
//
// L'OCR restituisce i pezzi di testo della riga (titolo, artista, BPM, nome file, …) in un ordine
// e con una suddivisione che dipendono dalle colonne visibili in Serato, quindi il confronto lavora
// sulle parole e non sulle colonne:
// - richiamo: quante parole di titolo e artista della traccia compaiono nella riga;
// - precisione: quante parole della riga sono spiegate dalla traccia (anche album, genere,
//   anno, BPM, tonalità, durata, nome file e cartella), utile per distinguere versioni con lo
//   stesso titolo.
// Serato taglia i testi troppo lunghi al bordo della colonna, senza "…": una cella troncata
// (`RowCell.truncated`) permette che la sua ultima parola sia solo l'inizio di una parola della
// traccia, e le parole del campo che seguono quel punto non penalizzano.
// Le parole si confrontano prima in modo esatto e poi approssimato (Levenshtein) per tollerare
// gli errori dell'OCR. A parità di punteggio vince un file locale, l'unico che si può ascoltare.

public struct RowCell: Sendable {
    public let text: String
    /// Il testo è tagliato al bordo della colonna.
    public let truncated: Bool

    public init(text: String, truncated: Bool) {
        self.text = text
        self.truncated = truncated || text.hasSuffix("…") || text.hasSuffix("...")
    }
}

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
        let allSet: Set<String>
    }

    private struct RowToken {
        let text: String
        /// Ultima parola di una cella troncata: può essere l'inizio di una parola più lunga.
        let clipped: Bool
    }

    private let entries: [Entry]
    private let postings: [String: [Int]]
    private let candidateLimit = 60

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
            if let path = track.path {
                extra += Self.tokens(path)
            }

            let index = entries.count
            for token in Set(title + artist) { postings[token, default: []].append(index) }
            let allSet = Set(title + artist + extra)
            entries.append(Entry(track: track, title: title, artist: artist, all: Array(allSet), allSet: allSet))
        }

        self.entries = entries
        self.postings = postings
    }

    /// Variante per testi senza posizione: una cella è troncata solo se termina con "…".
    public func match(_ texts: [String], limit: Int = 3) -> [TrackMatch] {
        match(texts.map { RowCell(text: $0, truncated: false) }, limit: limit)
    }

    /// Le migliori tracce per le celle di una riga, in ordine di punteggio decrescente.
    public func match(_ cells: [RowCell], limit: Int = 3) -> [TrackMatch] {
        var row: [RowToken] = []
        for cell in cells {
            let tokens = Self.tokens(cell.text)
            for (index, token) in tokens.enumerated() {
                row.append(RowToken(text: token, clipped: cell.truncated && index == tokens.count - 1))
            }
        }
        guard !row.isEmpty else { return [] }
        let rowSet = Set(row.map(\.text))

        // Candidati: tracce che condividono almeno una parola esatta, pesata per rarità.
        var weights: [Int: Double] = [:]
        let total = Double(max(entries.count, 1))
        for token in rowSet {
            guard let list = postings[token] else { continue }
            let weight = log(total / Double(list.count)) + 0.1
            for index in list { weights[index, default: 0] += weight }
        }
        let candidates = weights.sorted { $0.value > $1.value }.prefix(candidateLimit).map(\.key)

        return candidates
            .map { score(entries[$0], row: row, rowSet: rowSet) }
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 1e-9 { return lhs.score > rhs.score }
                return lhs.track.path != nil && rhs.track.path == nil
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Punteggio

    private func score(_ entry: Entry, row: [RowToken], rowSet: Set<String>) -> TrackMatch {
        let titleRecall = Self.recall(entry.title, in: row, rowSet: rowSet) ?? 0
        let artistRecall = Self.recall(entry.artist, in: row, rowSet: rowSet)
        let recall = artistRecall.map { 0.65 * titleRecall + 0.35 * $0 } ?? titleRecall

        let explained = row.filter { token in
            entry.allSet.contains(token.text) || entry.all.contains { Self.similar($0, token) }
        }.count
        let precision = Double(explained) / Double(row.count)

        return TrackMatch(
            track: entry.track,
            score: 0.75 * recall + 0.25 * precision,
            titleRecall: titleRecall,
            artistRecall: artistRecall,
            precision: precision
        )
    }

    /// Frazione delle parole del campo presenti nella riga. Se l'ultima parola trovata corrisponde
    /// al punto in cui una cella è stata tagliata, le parole successive del campo non contano.
    private static func recall(_ field: [String], in row: [RowToken], rowSet: Set<String>) -> Double? {
        guard !field.isEmpty else { return nil }
        var matched = 0
        var lastMatched = -1
        var lastIsClipped = false
        for (index, token) in field.enumerated() {
            let exact = rowSet.contains(token)
            let hits = row.filter { $0.text == token || (!exact && similar(token, $0)) }
            guard !hits.isEmpty else { continue }
            matched += 1
            lastMatched = index
            lastIsClipped = hits.contains(where: \.clipped)
        }
        let considered = lastIsClipped ? lastMatched + 1 : field.count
        return Double(matched) / Double(considered)
    }

    /// Confronto non esatto: `token` viene dalla libreria, `row` dall'OCR.
    private static func similar(_ token: String, _ row: RowToken) -> Bool {
        if row.clipped && token.hasPrefix(row.text) { return true }
        let tokenLength = token.utf8.count
        let rowLength = row.text.utf8.count
        let longest = max(tokenLength, rowLength)
        guard longest >= 4 else { return false }
        let allowed = longest >= 8 ? 2 : 1
        guard abs(tokenLength - rowLength) <= allowed else { return false }
        return levenshtein(Array(token.utf8), Array(row.text.utf8), limit: allowed) <= allowed
    }

    /// Distanza di modifica, con uscita anticipata appena supera `limit`.
    private static func levenshtein(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return rowMinimum }
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
