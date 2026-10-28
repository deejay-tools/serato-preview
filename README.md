# Serato Preview

*[Leggi in italiano](README.it.md)*

A small macOS menu-bar app that lets you **preview a track from the Serato DJ Pro library in your headphones** without loading it onto a deck.

Hold ⌥ and click a row in Serato's browser (or press ⌥+↓ on the selected row): the app recognizes the track, finds the file in your Serato library and plays it on the output you choose, for example the headphone channels of your controller. The decks keep playing undisturbed.

## How it works

Serato's track list doesn't expose its contents to macOS (no Accessibility tree), so the app:

1. captures the clicked row from the screen (ScreenCaptureKit);
2. reads its text with on-device OCR (Vision);
3. matches the text against Serato's library, read **read-only** from `~/Library/Application Support/Serato/Library/master.sqlite`;
4. plays the file with AVAudioEngine on the chosen device and channels.

Nothing is sent over the network and Serato's library is never modified.

## Requirements

- macOS 14 Sonoma or later (Apple Silicon or Intel)
- Serato DJ Pro 5 (tested with 5.0.0)
- Swift 5.9 or later: the Xcode Command Line Tools are enough (`xcode-select --install`)
- Optional: a DJ controller with a multi-channel audio interface (tested with a Pioneer DDJ-FLX10, headphones on channels 3-4)

## Installation

### 1. Get the code

```sh
git clone https://github.com/gdessi1965/serato-preview.git
cd serato-preview
```

### 2. Create a signing certificate (once)

macOS ties the Accessibility and Screen Recording permissions to the app's signature. With a fixed certificate the permissions survive rebuilds; without it you have to grant them again after every build.

1. Open **Keychain Access** → menu **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `SeratoPreview Signing`, Identity Type: **Self Signed Root**, Certificate Type: **Code Signing**.
3. Click **Create**. Keychain Access will mark it as "not trusted": that's fine for signing.

To use a certificate with a different name: `SIGN_IDENTITY="My name" ./Scripts/build-app.sh`.

### 3. Build the app

```sh
./Scripts/build-app.sh
```

The result is `build/Serato Preview.app`. Move it to `/Applications` (or wherever you like) and open it: a headphones icon appears in the menu bar.

### 4. Grant the permissions

On first launch macOS asks for two permissions, both under **System Settings → Privacy & Security**:

- **Accessibility**: to intercept ⌥+click and the preview keys;
- **Screen & System Audio Recording**: to read the clicked row.

If something is missing, the app's menu shows it with a shortcut to the right settings page. After granting Screen Recording, quit and reopen the app.

## Usage

Open Serato DJ Pro, then:

| Action | What it does |
|---|---|
| **⌥ + click** on a row in the browser | Previews that track. Clicking the track that is playing stops it. |
| **⌥ + ↓** | Previews the row selected in Serato (the one highlighted in blue). |
| **↑** | Stops the preview. |
| **← / →** | Seeks back / forward (5 seconds by default). |

↑ ← → are taken by the app only while a preview is playing; otherwise they go to Serato as usual. ⌥+click outside the track list is passed to Serato untouched.

While a track is playing, a small floating player shows title, artist, BPM, key and progress. It never takes the keyboard focus, which stays with Serato. You can drag it anywhere and it remembers its position.

### DJ controller (MIDI)

The app listens to every MIDI controller without taking it away from Serato, which keeps receiving the same messages. Default mapping (Pioneer DDJ-FLX10, MIDI channel 2):

| Button | Note | Action |
|---|---|---|
| **SHIFT + LINK** | 67 | Previews the selected track / stops |
| **SHIFT + MIX POINT SELECT ◀** | 73 | Back |
| **SHIFT + MIX POINT SELECT ▶** | 66 | Forward |

SHIFT is used because without it those buttons have fixed functions in Serato (Link, pitch) that MIDI Learn can't remove.

For a different controller, find out what its buttons send with:

```sh
swift Tools/midi-monitor.swift --notes
```

then change the `midi` block in `settings.json` (see below). `kind` can be `note` or `controlChange`; channel is 1-16.

```json
"midi" : {
  "playStop" : { "kind" : "note", "channel" : 2, "number" : 67 },
  "back"     : { "kind" : "note", "channel" : 2, "number" : 73 },
  "forward"  : { "kind" : "note", "channel" : 2, "number" : 66 }
}
```

### Menu

From the headphones icon:

- **Enabled**: turns the app on or off without quitting it;
- **Stop preview**;
- **Settings…** (⌘,);
- **Reload library**: the library is also reloaded automatically when Serato changes it (checked every minute).

## Settings

The **Settings…** window lets you choose:

- **Language**: Italian, English or the system language;
- **Activation**: the modifier key for click and ↓ (⌥, ⌃, ⌘⌥, ⌃⌥);
- **Audio output**: device, channel pair (e.g. 3-4 for the controller's headphones), start point as a percentage of the track (30% by default), volume, seek step;
- **Serato browser**: the geometry of the track list (see below);
- **Recognition**: minimum score for a match, fast OCR.

Everything is saved in `~/Library/Application Support/SeratoPreview/settings.json`, which you can also edit by hand (**Open settings.json** button). Missing keys take their default value.

### Calibrating the track list

The app needs to know where Serato's track list is inside the window. The defaults were measured on a 1440×863 Serato window (MacBook Pro M1). If your window has a different size or layout, or recognition fails:

1. Press ⌥+↓ on a selected row: the app saves the captured image in `~/Library/Logs/SeratoPreview/ultima-selezione.png`.
2. For more detail, from Terminal (the Terminal needs the same two permissions):
   ```sh
   swift run click-identify --calibrate
   ```
   Then ⌥+click anywhere in the Serato window: the tool prints every text it finds with its coordinates and saves the image. Ctrl-C to quit.
3. Set in Settings: **row height**, the **margins** of the list from the window edges (left, top, right, bottom, in points).

## Limitations

- Only tracks stored as local files: streaming tracks can't be previewed, nor tracks on a drive that isn't connected (the app tells you).
- Recognition is based on the visible text: if two different songs have the same title and artist in the visible columns, the app picks the best match. Copies of the same song in different folders are fine, since the audio is identical.
- If you resize the Serato window or change its layout, you need to recalibrate the list.

## Developer tools

| Command | What it does |
|---|---|
| `swift run library-dump` | Loads the Serato library and prints statistics and samples |
| `swift run library-dump --search "text"` | Finds tracks by title or artist |
| `swift run library-dump --match "Title\|Artist\|BPM\|Key"` | Shows how a row read by OCR is matched |
| `swift run click-identify [--save \| --calibrate]` | Logs the track recognized for each ⌥+click, without audio |
| `swift Tools/audio-test.swift list` | Lists audio devices and their channels |
| `swift Tools/midi-monitor.swift --notes` | Shows the MIDI messages from the controllers |
| `swift Tools/ax-dump.swift` | Dumps what Serato exposes through Accessibility |

Project layout:

- `Sources/SeratoLibrary`: reading the Serato library and text → track matching;
- `Sources/SeratoPreviewCore`: event interception, screen capture, OCR, audio, MIDI, settings;
- `Sources/SeratoPreview`: the menu-bar app (menu, mini player, settings);
- `Scripts/build-app.sh`: builds and signs the `.app`.

App logs are visible in Console.app by filtering on the subsystem `local.mac7.SeratoPreview`.

## Disclaimer

Serato Preview is an independent personal project, not affiliated with or endorsed by Serato. "Serato" and "Serato DJ Pro" are trademarks of their respective owners.
