#!/bin/bash
# set -u: variabile non definita = errore fatale, non stringa vuota silenziosa.
set -u

# "${1-}" invece di "$1": con set -u, $1 mancante ucciderebbe lo script con un
# errore bash invece del nostro messaggio "File non trovato" qui sotto.
FILE="${1-}"
NOME_FILE=$(basename "$FILE")
if [ ! -f "$FILE" ]; then echo "Errore: File non trovato."; exit 1; fi
PROBLEMI=""

# Interruttore da ~/.config/musiguard.conf (se il file manca resta tutto
# attivo): CHIEDI_SHA=0 disattiva del tutto il controllo SHA dagli appunti.
#
# FIX: prima il conf veniva ESEGUITO con "." (source): chiunque potesse
# scriverci dentro eseguiva codice come te. Ora viene solo LETTO: si accetta
# esclusivamente la riga "CHIEDI_SHA=numero", tutto il resto (comandi, altre
# variabili, valori non numerici) viene ignorato.
# Come col source, se la chiave compare più volte vince l'ultima.
CHIEDI_SHA=1
CONF="${HOME}/.config/musiguard.conf"
if [ -f "$CONF" ]; then
    VALORE=$(grep -E '^CHIEDI_SHA=[0-9]+$' "$CONF" | tail -n1 | cut -d= -f2)
    [ -n "$VALORE" ] && CHIEDI_SHA="$VALORE"
fi

# Verifica SHA dagli APPUNTI, senza alcun popup.
# FIX: sostituisce il vecchio prompt yad/zenity (una finestra a OGNI download).
# Se negli appunti c'e' gia' un SHA256 (64 caratteri esadecimali) copiato dal
# sito del download, lo verifichiamo in automatico; se non c'e', si salta in
# silenzio: nel caso normale non compare nulla e non si calcola nulla.
# FIX: sha256sum viene calcolato SOLO se negli appunti c'e' un hash — prima
# era in testa allo script e hashava ogni singolo file (costoso sui file
# grossi) anche quando l'hash non serviva a nessuno.
# Struttura invariata: subshell in background -> tmpfile -> wait (join) piu'
# avanti. Il confronto (sha256sum e' la parte lenta) gira in parallelo alle
# altre verifiche; canali separati (file vs variabile) -> nessuna race.
# Strumento appunti della sessione:
#   Wayland (tuo caso): sudo apt install wl-clipboard   -> comando: wl-paste
#   X11:                sudo apt install xclip          -> comando: xclip -o -selection clipboard
SHA_PID=""
SHA_TMP=""
if [ "$CHIEDI_SHA" = "1" ]; then
SHA_TMP=$(mktemp)
(
    CLIP=""
    if command -v wl-paste &>/dev/null; then
        CLIP=$(wl-paste 2>/dev/null)
    elif command -v xclip &>/dev/null; then
        CLIP=$(xclip -o -selection clipboard 2>/dev/null)
    fi
    # Prima sequenza di 64 hex trovata negli appunti, normalizzata minuscola.
    HASH_ATTESO=$(grep -ioE '[a-f0-9]{64}' <<< "$CLIP" | head -n1 | tr '[:upper:]' '[:lower:]')
    if [ -n "$HASH_ATTESO" ]; then
        HASH_CALCOLATO=$(sha256sum "$FILE" | awk '{print $1}')
        if [ "$HASH_CALCOLATO" != "$HASH_ATTESO" ]; then
            printf '%s' "❌ SHA256 NON CORRISPONDE (hash preso dagli APPUNTI): il file potrebbe essere alterato — oppure l'hash copiato si riferisce a un ALTRO file (falso positivo possibile, controlla cosa avevi negli appunti).\n   Calcolato: $HASH_CALCOLATO\n   Atteso (appunti): $HASH_ATTESO\n\n" > "$SHA_TMP"
        fi
    fi
) &
SHA_PID=$!
fi

# --- Verifiche che partono SUBITO, in parallelo al controllo appunti SHA ---

# Coerenza estensione / contenuto reale
REAL_TYPE=$(file -b --mime-type "$FILE")
if [[ "$NOME_FILE" == *.* ]]; then
    EXTENSION=$(tr '[:upper:]' '[:lower:]' <<< "${NOME_FILE##*.}")
else
    EXTENSION=""
fi
if [[ "$REAL_TYPE" == *"x-shellscript"* || "$REAL_TYPE" == *"x-executable"* || "$REAL_TYPE" == *"x-sharedlib"* || "$REAL_TYPE" == *"x-pie-executable"* ]]; then
    if [[ "$EXTENSION" != "sh" && "$EXTENSION" != "bin" && "$EXTENSION" != "run" && "$EXTENSION" != "appimage" && "$EXTENSION" != "deb" ]]; then
        PROBLEMI+="❌ NATURA INGANNEVOLE: Il file sembra un .$EXTENSION ma contiene CODICE ESEGUIBILE nascosto.\n\n"
    fi
# FIX: prima erano coperti solo gli eseguibili Linux (ELF/script): un .exe
# Windows (PE) rinominato "fattura.pdf" passava questo controllo. I mime dei
# PE sono x-dosexec / x-msdownload; qui la whitelist è separata (solo exe/msi):
# le estensioni lecite per gli ELF non hanno senso per un PE.
elif [[ "$REAL_TYPE" == *"x-dosexec"* || "$REAL_TYPE" == *"x-msdownload"* ]]; then
    if [[ "$EXTENSION" != "exe" && "$EXTENSION" != "msi" ]]; then
        PROBLEMI+="❌ NATURA INGANNEVOLE: Il file sembra un .$EXTENSION ma è un ESEGUIBILE WINDOWS camuffato.\n\n"
    fi
fi

# Scansione ClamAV. exit 1 = virus, >=2 = errore di scansione (non minaccia).
# FIX: se c'e' clamdscan (pacchetto clamav-daemon) usiamo quello: le firme
# sono gia' in memoria nel demone e la scansione e' quasi istantanea, mentre
# clamscan le ricarica (~1GB, ~30s) A OGNI file — con piu' download in coda
# diventano minuti. --fdpass passa il file per file descriptor, cosi' il
# demone (utente clamav) lo legge anche senza permessi sulla nostra HOME.
# Se il demone non risponde (rc>=2), fallback su clamscan classico.
CLAM_RC=""
CLAM_OUT=""
if command -v clamdscan &> /dev/null; then
    CLAM_OUT=$(clamdscan --no-summary --fdpass "$FILE" 2>&1)
    CLAM_RC=$?
    if [ "$CLAM_RC" -ge 2 ] && command -v clamscan &> /dev/null; then
        CLAM_OUT=$(clamscan --no-summary "$FILE" 2>&1)
        CLAM_RC=$?
    fi
elif command -v clamscan &> /dev/null; then
    CLAM_OUT=$(clamscan --no-summary "$FILE" 2>&1)
    CLAM_RC=$?
fi
if [ -z "$CLAM_RC" ]; then
    PROBLEMI+="⚠️ ATTENZIONE: ClamAV non è installato.\n\n"
elif [ "$CLAM_RC" -eq 1 ]; then
    PROBLEMI+="☣️ MINACCIA RILEVATA DA CLAMAV:\n$CLAM_OUT\n\n"
elif [ "$CLAM_RC" -ge 2 ]; then
    PROBLEMI+="⚠️ ERRORE CLAMAV (scansione non riuscita):\n$CLAM_OUT\n\n"
fi

# --- Join: aspetta il controllo appunti SHA e raccogli l'esito ---
# (saltato in blocco se CHIEDI_SHA=0: nessun processo da aspettare)
if [ -n "$SHA_PID" ]; then
    wait "$SHA_PID"
    if [ -s "$SHA_TMP" ]; then PROBLEMI+="$(cat "$SHA_TMP")"; fi
    rm -f "$SHA_TMP"
fi

if [ -n "$PROBLEMI" ]; then echo -e "Sono state rilevate anomalie:\n\n$PROBLEMI"; exit 1; else exit 0; fi
