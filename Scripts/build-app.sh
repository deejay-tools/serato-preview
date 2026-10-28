#!/bin/bash
# Compila Serato Preview in release e crea build/Serato Preview.app.
#
# Firma: macOS lega i permessi (Accessibilità, Registrazione schermo) alla firma dell'app.
# Con una firma ad-hoc cambia a ogni build e i permessi vanno ridati ogni volta; con un
# certificato fisso restano. Il certificato si crea una volta sola in Accesso Portachiavi →
# Assistente Certificato → Crea un certificato…: nome "SeratoPreview Signing", tipo
# "Firma del codice". Un nome diverso si passa con SIGN_IDENTITY="…" ./Scripts/build-app.sh

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-SeratoPreview Signing}"
APP="build/Serato Preview.app"

swift build -c release --product SeratoPreview

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SeratoPreview "$APP/Contents/MacOS/SeratoPreview"
cp Support/Info.plist "$APP/Contents/Info.plist"

if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Firmata con \"$IDENTITY\"."
else
    codesign --force --sign - "$APP"
    echo "ATTENZIONE: certificato \"$IDENTITY\" non trovato, firma ad-hoc."
    echo "I permessi Accessibilità e Registrazione schermo andranno ridati dopo ogni build."
fi

echo "Pronta: $APP"
