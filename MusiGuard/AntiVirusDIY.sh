#!/bin/bash
FILE="$1"
NOME_FILE=$(basename "$FILE")
if [ ! -f "$FILE" ]; then echo "Errore: File non trovato."; exit 1; fi
PROBLEMI=""

# Controllo coerenza estensione
REAL_TYPE=$(file -b --mime-type "$FILE")
# FIX: estensione presa dal basename (non dal path intero) e in minuscolo.
# Se il nome non contiene un punto, l'estensione è vuota (prima conteneva l'intero path).
if [[ "$NOME_FILE" == *.* ]]; then
    EXTENSION="${NOME_FILE##*.}"
    EXTENSION=$(tr '[:upper:]' '[:lower:]' <<< "$EXTENSION")
else
    EXTENSION=""
fi
if [[ "$REAL_TYPE" == *"x-shellscript"* || "$REAL_TYPE" == *"x-executable"* || "$REAL_TYPE" == *"x-sharedlib"* || "$REAL_TYPE" == *"x-pie-executable"* ]]; then
    if [[ "$EXTENSION" != "sh" && "$EXTENSION" != "bin" && "$EXTENSION" != "run" && "$EXTENSION" != "appimage" && "$EXTENSION" != "deb" ]]; then
        PROBLEMI+="❌ NATURA INGANNEVOLE: Il file sembra un .$EXTENSION ma contiene CODICE ESEGUIBILE nascosto.\n\n"
    fi
fi

# Controllo SHA256 interattivo
HASH_CALCOLATO=$(sha256sum "$FILE" | awk '{print $1}')
HASH_ATTESO=$(zenity --entry --title="Controllo Impronta SHA256" \
    --text="File in analisi: <b>$NOME_FILE</b>\n\nSe il sito forniva un codice SHA256, incollalo qui.\nAltrimenti, lascia vuoto e premi OK." \
    --width=500 2>/dev/null)
if [ -n "$HASH_ATTESO" ]; then
    HASH_ATTESO=$(tr -d ' ' <<< "$HASH_ATTESO" | tr '[:upper:]' '[:lower:]')
    if [ "$HASH_CALCOLATO" != "$HASH_ATTESO" ]; then
        PROBLEMI+="❌ SHA256 NON CORRISPONDE: Il file potrebbe essere alterato.\n   Calcolato: $HASH_CALCOLATO\n   Atteso: $HASH_ATTESO\n\n"
    fi
fi

# Scansione ClamAV
# FIX: clamscan usa exit code 1 = virus trovato, 2 = errore di scansione.
# Prima trattavi entrambi come "minaccia": un errore (es. file troppo grande)
# risultava in un falso allarme.
if command -v clamscan &> /dev/null; then
    CLAM_OUT=$(clamscan --no-summary "$FILE" 2>&1)
    CLAM_RC=$?
    if [ "$CLAM_RC" -eq 1 ]; then
        PROBLEMI+="☣️ MINACCIA RILEVATA DA CLAMAV:\n$CLAM_OUT\n\n"
    elif [ "$CLAM_RC" -ge 2 ]; then
        PROBLEMI+="⚠️ ERRORE CLAMAV (scansione non riuscita):\n$CLAM_OUT\n\n"
    fi
else
    PROBLEMI+="⚠️ ATTENZIONE: ClamAV non è installato.\n\n"
fi

if [ -n "$PROBLEMI" ]; then echo -e "Sono state rilevate anomalie:\n\n$PROBLEMI"; exit 1; else exit 0; fi
