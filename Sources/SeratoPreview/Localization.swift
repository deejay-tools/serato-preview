import AppKit
import SeratoLibrary
import SeratoPreviewCore

/// Lingua corrente dell'interfaccia. La imposta PreviewController all'avvio e a ogni salvataggio.
@MainActor
enum L10n {
    static var language: PreviewSettings.Language = PreviewSettings.Language.system.resolved

    static var locale: Locale {
        Locale(identifier: language == .italian ? "it_IT" : "en_US")
    }
}

/// Testo nella lingua corrente: italiano o inglese.
@MainActor
func tr(_ italian: String, _ english: String) -> String {
    L10n.language == .italian ? italian : english
}

extension PreviewSettings.Language {
    /// Nome mostrato nel selettore: le lingue con il proprio nome, così si ritrovano anche se l'interfaccia è nell'altra.
    @MainActor
    var displayName: String {
        switch self {
        case .system: return tr("Automatica (lingua di sistema)", "Automatic (system language)")
        case .italian: return "Italiano"
        case .english: return "English"
        }
    }
}

/// Descrizione dell'errore nella lingua corrente. Le descrizioni dei moduli restano in italiano per gli
/// strumenti da riga di comando; qui si traducono quelle che l'app può mostrare.
@MainActor
func localizedMessage(for error: Error) -> String {
    switch error {
    case let error as PreviewPlayer.PlayerError:
        switch error {
        case .deviceNotFound:
            return tr("Uscita audio non trovata: controlla le impostazioni.",
                      "Audio output not found: check the settings.")
        case .deviceBusy(let pid):
            let owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            return tr("Uscita audio in uso esclusivo da \(owner).",
                      "Audio output is in exclusive use by \(owner).")
        case .invalidChannels(let channels, let available):
            let pair = channels.map(String.init).joined(separator: "-")
            return tr("Canali \(pair) non disponibili: l'uscita ne ha \(available).",
                      "Channels \(pair) not available: the output has \(available).")
        case .unreadableFile(let name):
            return tr("Impossibile leggere \(name).", "Cannot read \(name).")
        case .engine(let message):
            return tr("Errore audio: \(message)", "Audio error: \(message)")
        }
    case let error as WindowCapture.CaptureError:
        switch error {
        case .windowNotFound(let id):
            return tr("Finestra \(id) non disponibile per la cattura.", "Window \(id) not available for capture.")
        case .emptyRect:
            return tr("Area di cattura vuota.", "Empty capture area.")
        }
    case let error as LibraryError:
        switch error {
        case .notFound(let path):
            return tr("File non trovato: \(path)", "File not found: \(path)")
        case .unstableSnapshot:
            return tr("Serato sta scrivendo la libreria: copia non stabile dopo vari tentativi.",
                      "Serato is writing the library: no stable copy after several attempts.")
        case .sqlite(let message):
            return "SQLite: \(message)"
        }
    default:
        return "\(error)"
    }
}
