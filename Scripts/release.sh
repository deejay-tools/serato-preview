#!/bin/bash
# Crea la release distribuibile: build/SeratoPreview-<versione>.zip con dentro
# Serato Preview.app universale (Apple Silicon + Intel), firmata Developer ID e notarizzata.
# Chi la scarica la copia in Applicazioni e la apre senza avvisi di Gatekeeper.
#
# Una volta sola, su questo Mac:
#  1. Certificato "Developer ID Application" nel portachiavi (Xcode → Settings → Accounts →
#     Manage Certificates → + → Developer ID Application, oppure da developer.apple.com).
#  2. Credenziali per la notarizzazione salvate nel portachiavi con il profilo "SeratoPreview":
#       xcrun notarytool store-credentials SeratoPreview \
#           --apple-id <email> --team-id <TEAMID> --password <password specifica per app>
#     La password specifica per app si crea su account.apple.com → Accesso e sicurezza.
#
# La versione è CFBundleShortVersionString di Support/Info.plist: aggiornarla prima di ogni release.
# Un profilo diverso si passa con NOTARY_PROFILE="…" ./Scripts/release.sh

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-SeratoPreview}"
APP="build/Serato Preview.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
ZIP="build/SeratoPreview-$VERSION.zip"

# Impronta SHA-1 del certificato Developer ID: si controlla subito, prima di compilare.
HASH=$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ { print $2; exit }')
if [ -z "$HASH" ]; then
    echo "ERRORE: nessun certificato \"Developer ID Application\" nel portachiavi." >&2
    exit 1
fi

BUILD_ARGS=(-c release --arch arm64 --arch x86_64 --product SeratoPreview)
swift build "${BUILD_ARGS[@]}"
BIN_PATH=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH/SeratoPreview" "$APP/Contents/MacOS/SeratoPreview"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Hardened runtime e timestamp sono obbligatori per la notarizzazione.
codesign --force --options runtime --timestamp --sign "$HASH" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Si notarizza uno zip, poi il ticket si "pinza" sull'app e lo zip si rifà con l'app pinzata,
# così Gatekeeper la accetta anche senza connessione.
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

spctl --assess --type execute --verbose=2 "$APP"
echo "Pronta: $ZIP (versione $VERSION, da allegare alla release su GitHub)"
