import CoreGraphics
import Vision

public struct RecognizedText: Sendable {
    public let text: String
    public let confidence: Float
    /// Posizione nell'immagine catturata, in punti, origine in alto a sinistra.
    public let frame: CGRect
}

/// OCR con Vision e selezione del testo che sta sulla riga cliccata.
public enum TextRecognizer {
    /// `pointSize` è la dimensione in punti dell'area catturata, per riportare i riquadri in punti.
    public static func recognize(_ image: CGImage, pointSize: CGSize, languages: [String]) throws -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Titoli e nomi non sono frasi: la correzione linguistica fa più danni che altro.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages

        try VNImageRequestHandler(cgImage: image).perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            let frame = CGRect(x: box.minX * pointSize.width,
                               y: (1 - box.maxY) * pointSize.height,
                               width: box.width * pointSize.width,
                               height: box.height * pointSize.height)
            return RecognizedText(text: candidate.string, confidence: candidate.confidence, frame: frame)
        }
    }

    /// I testi della riga più vicina a `y`, da sinistra a destra. La riga è quella del testo il cui
    /// centro è più vicino a `y`; ne fanno parte i testi con il centro entro `tolerance` dal suo.
    public static func line(in texts: [RecognizedText], nearY y: CGFloat, tolerance: CGFloat) -> [RecognizedText] {
        guard let anchor = texts.min(by: { abs($0.frame.midY - y) < abs($1.frame.midY - y) }) else { return [] }
        return texts
            .filter { abs($0.frame.midY - anchor.frame.midY) <= tolerance }
            .sorted { $0.frame.minX < $1.frame.minX }
    }
}
