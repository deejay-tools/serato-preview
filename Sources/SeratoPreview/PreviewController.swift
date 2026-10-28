import AppKit
import Combine
import os
import ScreenCaptureKit
import SeratoLibrary
import SeratoPreviewCore

/// Collega intercettazione, riconoscimento e audio. Tutto gira sul main thread tranne OCR e
/// caricamento della libreria.
@MainActor
final class PreviewController: ObservableObject {
    enum Status: Equatable {
        case idle
        case identifying
        case playing(title: String, subtitle: String)
        case message(title: String, subtitle: String, symbol: String)
    }

    enum Permission {
        case accessibility
        case screenRecording

        @MainActor var name: String {
            switch self {
            case .accessibility: return tr("Accessibilità", "Accessibility")
            case .screenRecording: return tr("Registrazione schermo", "Screen Recording")
            }
        }
    }

    enum LibraryState {
        case notLoaded
        case loading
        case loaded(trackCount: Int, at: Date)
        case failed(Error)
    }

    enum SettingsError {
        case invalidFile(Error)
        case saveFailed(Error)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var library: LibraryState = .notLoaded
    @Published private(set) var missingPermissions: [Permission] = []
    @Published private(set) var settings: PreviewSettings
    @Published private(set) var settingsError: SettingsError?
    @Published var isEnabled = true {
        didSet {
            interceptor.isEnabled = isEnabled
            if !isEnabled { stopPreview() }
        }
    }

    var isPreviewing: Bool { player.isPlaying }

    private let log = Logger(subsystem: "local.mac7.SeratoPreview", category: "preview")
    private let identifier = RowIdentifier()
    private let player = PreviewPlayer()
    private let interceptor = EventInterceptor()
    private let midiInput = MIDIInput()
    private var matcher: TrackMatcher?
    private var libraryStamp: [String] = []
    private var loadingLibrary = false
    private var currentTrack: Track?
    private var clickGeneration = 0
    private var messageGeneration = 0
    private var progressTimer: Timer?
    private var permissionTimer: Timer?
    private var libraryTimer: Timer?

    /// Ogni quanto controllare se Serato ha modificato la libreria.
    private let libraryCheckInterval: TimeInterval = 60

    init() {
        do {
            settings = try PreviewSettings.load()
        } catch {
            settings = .defaults
            settingsError = .invalidFile(error)
        }
        L10n.language = settings.language.resolved
    }

    var libraryDescription: String {
        switch library {
        case .notLoaded:
            return tr("Libreria non ancora caricata", "Library not loaded yet")
        case .loading:
            return tr("Caricamento libreria…", "Loading library…")
        case .loaded(let count, let date):
            let tracks = count.formatted(.number.locale(L10n.locale))
            let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))
            return tr("\(tracks) tracce · aggiornata alle \(time)", "\(tracks) tracks · updated at \(time)")
        case .failed(let error):
            return tr("Libreria non leggibile: ", "Cannot read library: ") + localizedMessage(for: error)
        }
    }

    var settingsErrorMessage: String? {
        switch settingsError {
        case nil:
            return nil
        case .invalidFile(let error):
            return tr("settings.json non valido, uso i valori predefiniti: ",
                      "Invalid settings.json, using default values: ") + error.localizedDescription
        case .saveFailed(let error):
            return tr("Impossibile salvare le impostazioni: ", "Cannot save the settings: ") + error.localizedDescription
        }
    }

    // MARK: - Avvio

    func start() {
        configureInterceptor()
        player.onStop = { [weak self] in
            MainActor.assumeIsolated { self?.playbackEnded() }
        }

        midiInput.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.handle(message) }
        }
        do {
            try midiInput.start()
        } catch {
            log.error("MIDI non disponibile: \(String(describing: error), privacy: .public)")
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        checkPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermissions() }
        }

        reloadLibrary()
        libraryTimer = Timer.scheduledTimer(withTimeInterval: libraryCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadLibraryIfChanged() }
        }

        let languages = settings.ocrLanguages, fast = settings.fastOCR
        Task.detached(priority: .utility) { TextRecognizer.warmUp(languages: languages, fast: fast) }
    }

    private func configureInterceptor() {
        interceptor.modifier = settings.modifier.flags
        // Le callback dell'event tap arrivano sul main run loop.
        interceptor.accepts = { [weak self] click in
            MainActor.assumeIsolated {
                guard let self else { return false }
                return self.settings.browserRect(in: click.windowFrame).contains(click.location)
            }
        }
        interceptor.onClick = { [weak self] click in
            MainActor.assumeIsolated { self?.handle(click) }
        }
        interceptor.onKey = { [weak self] key in
            MainActor.assumeIsolated { self?.handle(key) ?? false }
        }
        interceptor.onSelectedRow = { [weak self] window in
            MainActor.assumeIsolated { self?.previewSelectedRow(in: window) }
        }
    }

    private func checkPermissions() {
        var missing: [Permission] = []
        if !AXIsProcessTrusted() { missing.append(.accessibility) }
        if !CGPreflightScreenCaptureAccess() { missing.append(.screenRecording) }
        if missing != missingPermissions { missingPermissions = missing }

        if !interceptor.isRunning && AXIsProcessTrusted() {
            do {
                try interceptor.start()
                log.info("Event tap attivo")
            } catch {
                log.error("Event tap non disponibile: \(String(describing: error), privacy: .public)")
            }
        }
        if missing.isEmpty && interceptor.isRunning {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    // MARK: - Libreria

    func reloadLibrary() {
        guard !loadingLibrary else { return }
        loadingLibrary = true
        if matcher == nil { library = .loading }
        let stamp = Self.currentLibraryStamp()

        Task.detached(priority: .utility) {
            let start = Date()
            let result = Result { () throws -> TrackMatcher in
                TrackMatcher(tracks: try SeratoLibraryReader().load().tracks)
            }
            let elapsed = Date().timeIntervalSince(start)
            await MainActor.run {
                self.loadingLibrary = false
                switch result {
                case .success(let matcher):
                    self.matcher = matcher
                    self.libraryStamp = stamp
                    self.library = .loaded(trackCount: matcher.trackCount, at: Date())
                    self.log.info("Libreria: \(matcher.trackCount) tracce in \(Int(elapsed * 1000)) ms")
                case .failure(let error):
                    self.library = .failed(error)
                    self.log.error("Libreria non leggibile: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func reloadLibraryIfChanged() {
        if Self.currentLibraryStamp() != libraryStamp { reloadLibrary() }
    }

    /// Dimensione e data di master.sqlite e del suo WAL: se cambiano, Serato ha scritto qualcosa.
    private static func currentLibraryStamp() -> [String] {
        let folder = SeratoLibraryReader().libraryFolder
        return ["master.sqlite", "master.sqlite-wal"].map { name in
            let path = folder.appendingPathComponent(name).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "-" }
            let size = attributes[.size] as? Int64 ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(size)@\(modified)"
        }
    }

    // MARK: - Clic e riga selezionata

    private func handle(_ click: SeratoClick) {
        identifyAndPlay { identifier, settings, matcher in
            try await identifier.identify(click, settings: settings, matcher: matcher)
        }
    }

    private func previewSelectedRow(in window: SeratoWindow) {
        let debugImage = Self.logsFolder.appendingPathComponent("ultima-selezione.png")
        identifyAndPlay { identifier, settings, matcher in
            try await identifier.identifySelected(in: window, settings: settings, matcher: matcher, debugImage: debugImage)
        }
    }

    private static let logsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SeratoPreview")

    private func identifyAndPlay(
        _ identify: @escaping (RowIdentifier, PreviewSettings, TrackMatcher) async throws -> Identification
    ) {
        guard let matcher else {
            showMessage(tr("Libreria in caricamento", "Library loading"),
                        tr("Riprova tra qualche secondo", "Try again in a few seconds"), symbol: "hourglass")
            return
        }
        clickGeneration += 1
        let generation = clickGeneration
        if !player.isPlaying { status = .identifying }
        let settings = self.settings

        Task {
            do {
                let result = try await identify(identifier, settings, matcher)
                guard generation == clickGeneration else { return }
                logIdentification(result)
                apply(result)
            } catch {
                guard generation == clickGeneration else { return }
                log.error("Cattura non riuscita: \(String(describing: error), privacy: .public)")
                let nsError = error as NSError
                if case RowIdentifier.SelectionError.notFound = error {
                    showMessage(tr("Nessuna riga selezionata", "No selected row"),
                                tr("Seleziona una traccia visibile nel browser di Serato",
                                   "Select a visible track in the Serato browser"),
                                symbol: "list.bullet.rectangle")
                } else if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
                    showMessage(tr("Manca il permesso Registrazione schermo", "Screen Recording permission missing"),
                                tr("Concedilo in Impostazioni di Sistema, poi esci e riapri l'app",
                                   "Grant it in System Settings, then quit and reopen the app"),
                                symbol: "lock.shield")
                } else {
                    showMessage(tr("Cattura non riuscita", "Capture failed"), localizedMessage(for: error),
                                symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    private func apply(_ result: Identification) {
        guard let best = result.best(minimumScore: settings.minimumScore) else {
            showMessage(tr("Traccia non riconosciuta", "Track not recognized"),
                        result.cells.isEmpty ? tr("Nessun testo sulla riga", "No text on the row") : result.text,
                        symbol: "questionmark.circle")
            return
        }
        let track = best.track

        // Secondo clic sulla traccia in ascolto: stop.
        if player.isPlaying, currentTrack?.id == track.id {
            stopPreview()
            return
        }

        switch track.source {
        case .streaming:
            showMessage(track.title, tr("Streaming: anteprima non disponibile", "Streaming: preview not available"), symbol: "icloud.slash")
        case .unresolved:
            showMessage(track.title, tr("Il disco di questa traccia non è collegato", "The drive for this track is not connected"), symbol: "externaldrive.badge.xmark")
        case .file(let path):
            guard FileManager.default.fileExists(atPath: path) else {
                showMessage(track.title, tr("File non trovato", "File not found"), symbol: "doc.questionmark")
                return
            }
            play(track, url: URL(fileURLWithPath: path))
        }
    }

    private func play(_ track: Track, url: URL) {
        do {
            try player.play(url: url, deviceUID: settings.outputDeviceUID, channels: settings.outputChannels,
                            startFraction: settings.startFraction, volume: Float(settings.volume))
        } catch {
            log.error("Riproduzione non riuscita: \(String(describing: error), privacy: .public)")
            showMessage(tr("Anteprima non riuscita", "Preview failed"), localizedMessage(for: error), symbol: "speaker.slash")
            return
        }
        currentTrack = track
        duration = player.duration
        position = player.position
        status = .playing(title: track.title, subtitle: subtitle(for: track))
        startProgressTimer()
    }

    private func subtitle(for track: Track) -> String {
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if let bpm = track.bpm, bpm > 0 { parts.append("\(Int(bpm.rounded())) BPM") }
        if !track.key.isEmpty { parts.append(track.key) }
        return parts.joined(separator: " · ")
    }

    private func logIdentification(_ result: Identification) {
        let best = result.matches.first.map { String(format: "%.2f %@", $0.score, $0.track.title) } ?? "nessuna"
        log.info("""
            OCR \(Int(result.captureDuration * 1000))+\(Int(result.ocrDuration * 1000)) ms, \
            abbinamento \(Int(result.matchDuration * 1000)) ms: \(result.text, privacy: .public) → \(best, privacy: .public)\
            \(result.isAmbiguous ? " (ambiguo)" : "", privacy: .public)
            """)
    }

    // MARK: - Tastiera

    /// Solo durante l'anteprima e senza modificatori: ↑ ferma, ← → spostano. Altrimenti il tasto va a Serato.
    private func handle(_ press: KeyPress) -> Bool {
        guard player.isPlaying, press.isPlain else { return false }
        switch press.key {
        case .up:
            stopPreview()
        case .left:
            player.seek(by: -settings.seekStep)
            position = player.position
        case .right:
            player.seek(by: settings.seekStep)
            position = player.position
        }
        return true
    }

    // MARK: - MIDI

    /// Il tasto play/stop ascolta la traccia selezionata in Serato o ferma quella in corso;
    /// indietro e avanti agiscono solo durante l'anteprima. Serato riceve comunque gli stessi messaggi.
    private func handle(_ message: MIDIMessage) {
        guard isEnabled else { return }
        let midi = settings.midi
        if midi.playStop?.isPressed(by: message) == true {
            if player.isPlaying {
                stopPreview()
            } else if let window = interceptor.seratoMainWindow() {
                previewSelectedRow(in: window)
            } else {
                showMessage(tr("Serato non è aperto", "Serato is not open"),
                            tr("Apri Serato DJ Pro e seleziona una traccia", "Open Serato DJ Pro and select a track"),
                            symbol: "exclamationmark.triangle")
            }
        } else if player.isPlaying, midi.back?.isPressed(by: message) == true {
            player.seek(by: -settings.seekStep)
            position = player.position
        } else if player.isPlaying, midi.forward?.isPressed(by: message) == true {
            player.seek(by: settings.seekStep)
            position = player.position
        }
    }

    // MARK: - Stato

    func stopPreview() {
        player.stop()
        playbackEnded()
    }

    private func playbackEnded() {
        currentTrack = nil
        progressTimer?.invalidate()
        progressTimer = nil
        position = 0
        duration = 0
        if case .playing = status { status = .idle }
        if status == .identifying { status = .idle }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.isPlaying else { return }
                self.position = self.player.position
            }
        }
    }

    /// Mostra un messaggio per qualche secondo. Ferma l'anteprima in corso: il clic chiedeva un'altra traccia.
    private func showMessage(_ title: String, _ subtitle: String, symbol: String) {
        if player.isPlaying { player.stop() }
        playbackEnded()
        status = .message(title: title, subtitle: subtitle, symbol: symbol)
        messageGeneration += 1
        let generation = messageGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.messageGeneration == generation, case .message = self.status else { return }
                self.status = .idle
            }
        }
    }

    // MARK: - Impostazioni

    func apply(_ newSettings: PreviewSettings) {
        let audioChanged = newSettings.outputDeviceUID != settings.outputDeviceUID
            || newSettings.outputChannels != settings.outputChannels
        do {
            try newSettings.save()
            settingsError = nil
        } catch {
            settingsError = .saveFailed(error)
        }
        // Prima di pubblicare le impostazioni, così chi si aggiorna le trova già nella nuova lingua.
        L10n.language = newSettings.language.resolved
        settings = newSettings
        interceptor.modifier = newSettings.modifier.flags
        if audioChanged { stopPreview() }
    }
}
