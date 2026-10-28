# Serato Preview

*[Read in English](README.md)*

Una piccola app per la barra dei menu di macOS che permette di **ascoltare in cuffia una traccia della libreria di Serato DJ Pro** senza caricarla su un deck.

Tieni premuto ⌥ e clicca una riga nel browser di Serato (oppure premi ⌥+↓ sulla riga selezionata): l'app riconosce la traccia, trova il file nella libreria di Serato e lo suona sull'uscita che scegli, per esempio i canali cuffia del controller. I deck continuano a suonare senza disturbi.

## Come funziona

La lista tracce di Serato non espone il suo contenuto a macOS (non ha un albero di Accessibilità), quindi l'app:

1. cattura dallo schermo la riga cliccata (ScreenCaptureKit);
2. ne legge il testo con l'OCR del Mac (Vision), senza internet;
3. abbina il testo alla libreria di Serato, letta **in sola lettura** da `~/Library/Application Support/Serato/Library/master.sqlite`;
4. suona il file con AVAudioEngine sul dispositivo e sui canali scelti.

Non viene inviato nulla in rete e la libreria di Serato non viene mai modificata.

## Requisiti

- macOS 14 Sonoma o successivo (Apple Silicon o Intel)
- Serato DJ Pro 5 (provato con la 5.0.0)
- Swift 5.9 o successivo: bastano i Command Line Tools di Xcode (`xcode-select --install`)
- Facoltativo: un controller DJ con scheda audio multicanale (provato con un Pioneer DDJ-FLX10, cuffia sui canali 3-4)

## Installazione

### 1. Scarica il codice

```sh
git clone https://github.com/gdessi1965/serato-preview.git
cd serato-preview
```

### 2. Crea un certificato di firma (una volta sola)

macOS lega i permessi Accessibilità e Registrazione schermo alla firma dell'app. Con un certificato fisso i permessi restano anche dopo una nuova compilazione; senza, vanno ridati a ogni build.

1. Apri **Accesso Portachiavi** → menu **Accesso Portachiavi → Assistente Certificato → Crea un certificato…**
2. Nome: `SeratoPreview Signing`, Tipo di identità: **Radice autofirmata**, Tipo di certificato: **Firma del codice**.
3. Clicca **Crea**. Accesso Portachiavi lo segnerà come "non attendibile": per firmare va bene lo stesso.

Per usare un certificato con un altro nome: `SIGN_IDENTITY="Il mio nome" ./Scripts/build-app.sh`.

### 3. Compila l'app

```sh
./Scripts/build-app.sh
```

Il risultato è `build/Serato Preview.app`. Spostala in `/Applicazioni` (o dove preferisci) e aprila: nella barra dei menu compare l'icona delle cuffie.

### 4. Concedi i permessi

Al primo avvio macOS chiede due permessi, entrambi in **Impostazioni di Sistema → Privacy e sicurezza**:

- **Accessibilità**: per intercettare ⌥+clic e i tasti dell'anteprima;
- **Registrazione schermo e audio di sistema**: per leggere la riga cliccata.

Se manca qualcosa, il menu dell'app lo segnala con un collegamento alla pagina giusta delle impostazioni. Dopo aver concesso Registrazione schermo, esci dall'app e riaprila.

## Uso

Apri Serato DJ Pro, poi:

| Comando | Cosa fa |
|---|---|
| **⌥ + clic** su una riga del browser | Ascolta quella traccia. Un clic sulla traccia in ascolto la ferma. |
| **⌥ + ↓** | Ascolta la riga selezionata in Serato (quella evidenziata in blu). |
| **↑** | Ferma l'anteprima. |
| **← / →** | Indietro / avanti (5 secondi, di predefinito). |

↑ ← → vengono presi dall'app solo mentre un'anteprima suona; altrimenti vanno a Serato come sempre. Un ⌥+clic fuori dalla lista tracce passa a Serato senza essere toccato.

Durante l'ascolto un piccolo player flottante mostra titolo, artista, BPM, tonalità e avanzamento. Non prende mai il focus della tastiera, che resta a Serato. Si può trascinare dove vuoi e ricorda la posizione.

### Controller DJ (MIDI)

L'app ascolta tutti i controller MIDI senza toglierli a Serato, che continua a ricevere gli stessi messaggi. Assegnazione predefinita (Pioneer DDJ-FLX10, canale MIDI 2):

| Tasto | Nota | Azione |
|---|---|---|
| **SHIFT + LINK** | 67 | Ascolta la traccia selezionata / ferma |
| **SHIFT + MIX POINT SELECT ◀** | 73 | Indietro |
| **SHIFT + MIX POINT SELECT ▶** | 66 | Avanti |

Si usa SHIFT perché senza quei tasti hanno funzioni fisse in Serato (Link, intonazione) che MIDI Learn non può togliere.

Con un controller diverso, scopri cosa mandano i suoi tasti con:

```sh
swift Tools/midi-monitor.swift --notes
```

e cambia il blocco `midi` in `settings.json` (vedi sotto). `kind` può essere `note` o `controlChange`; il canale va da 1 a 16.

```json
"midi" : {
  "playStop" : { "kind" : "note", "channel" : 2, "number" : 67 },
  "back"     : { "kind" : "note", "channel" : 2, "number" : 73 },
  "forward"  : { "kind" : "note", "channel" : 2, "number" : 66 }
}
```

### Menu

Dall'icona delle cuffie:

- **Attivo**: accende o spegne l'app senza chiuderla;
- **Ferma anteprima**;
- **Impostazioni…** (⌘,);
- **Ricarica libreria**: la libreria si ricarica anche da sola quando Serato la modifica (controllo ogni minuto).

## Impostazioni

La finestra **Impostazioni…** permette di scegliere:

- **Lingua**: italiano, inglese o la lingua di sistema;
- **Attivazione**: il tasto modificatore per clic e ↓ (⌥, ⌃, ⌘⌥, ⌃⌥);
- **Uscita audio**: dispositivo, coppia di canali (es. 3-4 per la cuffia del controller), punto di partenza in percentuale della traccia (30% di predefinito), volume, salto con ← →;
- **Browser di Serato**: la geometria della lista tracce (vedi sotto);
- **Riconoscimento**: punteggio minimo per l'abbinamento, OCR veloce.

Tutto viene salvato in `~/Library/Application Support/SeratoPreview/settings.json`, che puoi anche modificare a mano (pulsante **Apri settings.json**). Le chiavi mancanti prendono il valore predefinito.

### Calibrare la lista tracce

L'app deve sapere dove si trova la lista tracce dentro la finestra di Serato. I valori predefiniti sono misurati con la finestra di Serato a 1440×863 (MacBook Pro M1). Se la tua finestra ha dimensioni o layout diversi, o il riconoscimento non funziona:

1. Premi ⌥+↓ su una riga selezionata: l'app salva l'immagine catturata in `~/Library/Logs/SeratoPreview/ultima-selezione.png`.
2. Per più dettagli, dal Terminale (il Terminale ha bisogno degli stessi due permessi):
   ```sh
   swift run click-identify --calibrate
   ```
   Poi ⌥+clic in un punto qualsiasi della finestra di Serato: lo strumento stampa tutti i testi trovati con le coordinate e salva l'immagine. Ctrl-C per uscire.
3. Imposta in Impostazioni: **altezza riga** e **margini** della lista dai bordi della finestra (sinistro, superiore, destro, inferiore, in punti).

## Limiti

- Solo tracce salvate come file locali: non si possono ascoltare le tracce in streaming, né quelle su un disco non collegato (l'app lo segnala).
- Il riconoscimento si basa sul testo visibile: se due canzoni diverse hanno lo stesso titolo e artista nelle colonne visibili, l'app sceglie l'abbinamento migliore. Le copie della stessa canzone in cartelle diverse non sono un problema, perché l'audio è identico.
- Se ridimensioni la finestra di Serato o ne cambi il layout, la lista va ricalibrata.

## Strumenti per sviluppatori

| Comando | Cosa fa |
|---|---|
| `swift run library-dump` | Carica la libreria di Serato e stampa statistiche e campioni |
| `swift run library-dump --search "testo"` | Cerca tracce per titolo o artista |
| `swift run library-dump --match "Titolo\|Artista\|BPM\|Tonalità"` | Mostra come viene abbinata una riga letta dall'OCR |
| `swift run click-identify [--save \| --calibrate]` | Registra la traccia riconosciuta per ogni ⌥+clic, senza audio |
| `swift Tools/audio-test.swift list` | Elenca i dispositivi audio e i loro canali |
| `swift Tools/midi-monitor.swift --notes` | Mostra i messaggi MIDI dei controller |
| `swift Tools/ax-dump.swift` | Mostra cosa espone Serato tramite Accessibilità |

Struttura del progetto:

- `Sources/SeratoLibrary`: lettura della libreria di Serato e abbinamento testo → traccia;
- `Sources/SeratoPreviewCore`: intercettazione degli eventi, cattura dello schermo, OCR, audio, MIDI, impostazioni;
- `Sources/SeratoPreview`: l'app nella barra dei menu (menu, mini-player, impostazioni);
- `Scripts/build-app.sh`: compila e firma la `.app`.

I log dell'app si vedono in Console filtrando per il sottosistema `local.mac7.SeratoPreview`.

## Licenza

[MIT](LICENSE).

## Avvertenza

Serato Preview è un progetto personale indipendente, non affiliato né approvato da Serato. "Serato" e "Serato DJ Pro" sono marchi dei rispettivi proprietari.
