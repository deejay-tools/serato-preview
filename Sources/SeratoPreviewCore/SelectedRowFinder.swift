import CoreGraphics
import Foundation

/// Trova la riga selezionata nella cattura del browser di Serato, che non espone nulla via Accessibilità.
///
/// Per ogni linea di pixel si prende il colore di sfondo (il più frequente, campionando le colonne).
/// Le linee consecutive con lo stesso sfondo formano fasce. Lo sfondo normale e le righe alternate
/// ricorrono in molte fasce; l'evidenziazione della selezione è un colore che compare in una sola
/// fascia, alta circa una riga. Tra più candidate vince quella più lontana dallo sfondo dominante.
public enum SelectedRowFinder {
    public struct Band: CustomStringConvertible {
        /// In pixel dell'immagine, dall'alto.
        public let start: Int
        public let end: Int
        public let color: (r: Int, g: Int, b: Int)
        public var height: Int { end - start }
        public var center: Double { Double(start + end) / 2 }

        public var description: String {
            String(format: "%d-%d (%d px) #%02x%02x%02x", start, end, height, color.r, color.g, color.b)
        }
    }

    public struct Result {
        public let selected: Band?
        /// Tutte le fasce trovate, per il log quando la selezione non si trova.
        public let bands: [Band]
    }

    /// `rowHeightPixels`: altezza di una riga in pixel dell'immagine.
    public static func find(in image: CGImage, rowHeightPixels: Double) -> Result {
        guard let pixels = rgbaPixels(of: image) else { return Result(selected: nil, bands: []) }
        let width = image.width, height = image.height

        // Sfondo di ogni linea: colore più frequente (5 bit per canale) su una colonna ogni 3.
        var lineColors: [UInt32?] = []
        lineColors.reserveCapacity(height)
        let step = 3
        let samples = (width + step - 1) / step
        for y in 0..<height {
            var counts: [UInt32: Int] = [:]
            let row = y * width * 4
            for x in stride(from: 0, to: width, by: step) {
                let i = row + x * 4
                let key = UInt32(pixels[i] >> 3) << 10 | UInt32(pixels[i + 1] >> 3) << 5 | UInt32(pixels[i + 2] >> 3)
                counts[key, default: 0] += 1
            }
            // Linee senza uno sfondo prevalente (testo fitto, separatori sfumati) non contano.
            let top = counts.max { $0.value < $1.value }
            lineColors.append(top.flatMap { $0.value * 3 >= samples ? $0.key : nil })
        }

        // Fasce di linee consecutive con lo stesso sfondo.
        var bands: [Band] = []
        var keys: [UInt32] = []
        var y = 0
        while y < height {
            guard let key = lineColors[y] else { y += 1; continue }
            var end = y + 1
            while end < height, let next = lineColors[end], close(next, key) { end += 1 }
            bands.append(Band(start: y, end: end, color: rgb(key)))
            keys.append(key)
            y = end
        }

        // Sfondo dominante: il colore che copre più linee.
        var coverage: [UInt32: Int] = [:]
        for (band, key) in zip(bands, keys) { coverage[key, default: 0] += band.height }
        guard let dominant = coverage.max(by: { $0.value < $1.value })?.key else { return Result(selected: nil, bands: bands) }

        var occurrences: [UInt32: Int] = [:]
        for key in keys { occurrences[keys.first { close($0, key) } ?? key, default: 0] += 1 }

        let candidates = zip(bands, keys).filter { band, key in
            let ratio = Double(band.height) / rowHeightPixels
            return ratio >= 0.5 && ratio <= 1.5
                && occurrences[keys.first { close($0, key) } ?? key] == 1
                && distance(key, dominant) >= 12
        }
        let selected = candidates.max { distance($0.1, dominant) < distance($1.1, dominant) }?.0
        return Result(selected: selected, bands: bands)
    }

    private static func rgb(_ key: UInt32) -> (r: Int, g: Int, b: Int) {
        (Int(key >> 10 & 31) << 3, Int(key >> 5 & 31) << 3, Int(key & 31) << 3)
    }

    /// Colori quantizzati che differiscono di al massimo un gradino per canale.
    private static func close(_ a: UInt32, _ b: UInt32) -> Bool {
        let x = rgb(a), y = rgb(b)
        return abs(x.r - y.r) <= 8 && abs(x.g - y.g) <= 8 && abs(x.b - y.b) <= 8
    }

    /// Massima differenza tra i canali, su scala 0-255.
    private static func distance(_ a: UInt32, _ b: UInt32) -> Int {
        let x = rgb(a), y = rgb(b)
        return max(abs(x.r - y.r), abs(x.g - y.g), abs(x.b - y.b))
    }

    private static func rgbaPixels(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
