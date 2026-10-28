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

### Opzione A: scarica la release (consigliata)

1. Scarica `SeratoPreview-<versione>.zip` dall'[ultima release](https://github.com/deejay-tools/serato-preview/releases/latest).
2. Estrai lo zip e sposta **Serato Preview.app** in `/Applicazioni`.
3. Aprila. L'app è firmata con un certificato Developer ID e notarizzata da Apple, quindi Gatekeeper la apre direttamente, senza bisogno di tasto destro/"Apri comunque".
4. Concedi i due permessi descritti [qui sotto](#4-concedi-i-permessi).

### Opzione B: compila dal codice sorgente

#### 1. Scarica il codice

```sh
git clone https://github.com/deejay-tools/serato-preview.git
cd serato-preview
```

#### 2. Crea un certificato di firma (una volta sola)

macOS lega i permessi Accessibilità e Registrazione schermo alla firma dell'app. Con un certificato fisso i permessi restano anche dopo una nuova compilazione; senza, vanno ridati a ogni build.

1. Apri **Accesso Portachiavi** → menu **Accesso Portachiavi → Assistente Certificato → Crea un certificato…**
2. Nome: `SeratoPreview Signing`, Tipo di identità: **Radice autofirmata**, Tipo di certificato: **Firma del codice**.
3. Clicca **Crea**. Accesso Portachiavi lo segnerà come "non attendibile": per firmare va bene lo stesso.

Per usare un certificato con un altro nome: `SIGN_IDENTITY="Il mio nome" ./Scripts/build-app.sh`.

#### 3. Compila l'app

```sh
./Scripts/build-app.sh
```

Il risultato è `build/Serato Preview.app`. Spostala in `/Applicazioni` (o dove preferisci) e aprila: nella barra dei menu compare l'icona delle cuffie.

#### 4. Concedi i permessi

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

<img src="docs/menu.png" alt="Menu di Serato Preview" width="300">

Dall'icona delle cuffie nella barra dei menu:

- le prime due righe mostrano lo **stato** (Pronto, In ascolto…, Riconosco la traccia…) e quante tracce sono caricate dalla libreria; qui compaiono anche i permessi mancanti, con il collegamento alla pagina giusta delle impostazioni;
- **Attivo**: accende o spegne l'app senza chiuderla; da spenta, ⌥+clic va a Serato come sempre e i tasti MIDI comandano solo Serato;
- **Ferma anteprima**;
- **Impostazioni…** (⌘,);
- **Ricarica libreria**: la libreria si ricarica anche da sola quando Serato la modifica (controllo ogni minuto).

## Impostazioni

<img src="docs/settings.png" alt="Impostazioni di Serato Preview" width="420">

Apri **Impostazioni…** dal menu (⌘,). Le modifiche restano in bozza finché non premi **Salva**; **Annulla** le scarta, **Valori predefiniti** riempie la finestra con i valori iniziali (poi va comunque salvato). Lo screenshot mostra l'interfaccia in inglese.

### Lingua

**Lingua**: italiano, inglese o *Sistema*, che usa l'italiano se è la prima lingua di macOS e l'inglese negli altri casi. Menu e mini-player cambiano appena salvi.

### Attivazione

**Tasto**: il modificatore da tenere premuto mentre clicchi una riga, usato anche con ↓ per ascoltare la riga selezionata. Puoi scegliere fra ⌥, ⌃, ⌘⌥ e ⌃⌥.

### Uscita audio

- **Dispositivo**: dove suona l'anteprima. *Uscita di sistema* segue l'uscita predefinita di macOS; altrimenti scegli una scheda audio precisa. Accanto a ogni nome c'è il numero di canali. Per sentire l'anteprima solo in cuffia, scegli il controller.
- **Canali**: la coppia stereo da usare. Su un controller a 4 canali di solito 1-2 è il master e **3-4 la cuffia** (è così sul DDJ-FLX10). Nel dubbio controlla il manuale del controller.
- **Partenza**: da dove parte l'anteprima, in percentuale della traccia (0-90%). Con 30% di solito si salta l'intro e si arriva nel corpo del pezzo.
- **Volume**: volume dell'anteprima, indipendente da Serato.
- **Salto con ← →**: di quanti secondi si spostano ← → (e i tasti MIDI indietro/avanti), da 1 a 30.

Se cambi dispositivo o canali, l'anteprima in corso si ferma.

### Browser di Serato (punti)

Questi valori dicono all'app dove si trova la lista tracce dentro la finestra di Serato. Sono in punti e si misurano dai bordi della finestra. Servono solo se il riconoscimento non funziona o i clic nella lista non vengono presi (vedi [Calibrare la lista tracce](#calibrare-la-lista-tracce)).

- **Altezza riga**: l'altezza di una riga della lista (28 con la dimensione del carattere predefinita di Serato).
- **Margine sinistro / superiore / destro / inferiore**: distanza della lista tracce dai bordi sinistro, superiore, destro e inferiore della finestra. Un ⌥+clic fuori da questo rettangolo va direttamente a Serato. Il più importante è il *superiore*: deve arrivare subito sotto le intestazioni delle colonne.
- **Righe catturate**: quanto è alta, in righe, la fascia catturata attorno al clic. Con 2 la riga cliccata è sempre catturata intera, ovunque cada il clic al suo interno.
- **Distanza testo troncato**: Serato taglia i titoli lunghi per farli stare nella colonna. Un testo che finisce a meno di questa distanza (in punti) dalla colonna successiva o dal bordo destro viene considerato tagliato, e confrontato come inizio del titolo.

### Riconoscimento

- **Punteggio minimo**: quanto deve essere sicura l'app (0,30-0,95) prima di suonare una traccia. Abbassalo se tracce giuste risultano "non riconosciute"; alzalo se parte la traccia sbagliata.
- **OCR veloce**: lettura del testo più rapida (qualche decina di ms) invece di quella accurata (circa un secondo per riga sui Mac meno recenti). Disattivalo solo se il testo viene letto male.

### Il file settings.json

Tutto viene salvato in `~/Library/Application Support/SeratoPreview/settings.json`. Il pulsante **Apri settings.json** lo apre nell'editor di testo. Alcune opzioni esistono solo lì:

- `midi`: i tasti del controller (vedi [Controller DJ](#controller-dj-midi));
- `ocrLanguages`: lingue per l'OCR, in ordine di priorità (predefinito `["it-IT", "en-US"]`).

Le chiavi mancanti prendono il valore predefinito. Se il file non è leggibile, l'app usa i valori predefiniti e mostra l'errore in fondo alla finestra Impostazioni. Dopo averlo modificato a mano, esci dall'app e riaprila.

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

I log dell'app si vedono in Console filtrando per il sottosistema `it.deejay-tools.SeratoPreview`.

## Licenza

[MIT](LICENSE).

## Avvertenza

Serato Preview è un progetto personale indipendente, non affiliato né approvato da Serato. "Serato" e "Serato DJ Pro" sono marchi dei rispettivi proprietari.
