#!/bin/bash
FILE="$1"
NOME_FILE=$(basename "$FILE")
if [ ! -f "$FILE" ]; then echo "Errore: File non trovato."; exit 1; fi
PROBLEMI=""

# --- Impostazioni prompt SHA (modificabili) ---
SHA_TIMEOUT=3      # secondi: passati questi il prompt sparisce e viene saltato
SHA_WIDTH=320      # larghezza

# Interruttore da ~/.config/musiguard.conf (se il file manca resta tutto
# attivo): CHIEDI_SHA=0 elimina del tutto il prompt SHA, nessuna finestra.
# Dal conf si possono anche ridefinire SHA_TIMEOUT e SHA_WIDTH.
CHIEDI_SHA=1
[ -f "${HOME}/.config/musiguard.conf" ] && . "${HOME}/.config/musiguard.conf"

HASH_CALCOLATO=$(sha256sum "$FILE" | awk '{print $1}')

# Prompt SHA in BACKGROUND: non blocca le altre verifiche, che partono subito.
# Il sottoshell scrive l'eventuale problema in un file temporaneo; il main lo
# legge SOLO dopo "wait" (join) -> nessuna race: prompt e ClamAV girano in
# parallelo ma scrivono su canali diversi (file vs variabile).
# NOTA POSIZIONE: siamo su Wayland, che per design NON lascia posizionare le
# finestre da un'app -> il popup esce centrato e non e' modificabile da qui.
# --undecorated + entry inline + height=1 lo tengono piccolo e sottile.
SHA_PID=""
SHA_TMP=""
if [ "$CHIEDI_SHA" = "1" ]; then
SHA_TMP=$(mktemp)
(
    HASH_ATTESO=""
    if command -v yad &>/dev/null; then
        HASH_ATTESO=$(yad --entry --undecorated --borders=6 \
            --entry-label="SHA256:" \
            --width="$SHA_WIDTH" --height=1 \
            --timeout="$SHA_TIMEOUT" --timeout-indicator=bottom 2>/dev/null)
    elif command -v zenity &>/dev/null; then
        HASH_ATTESO=$(zenity --entry --title="SHA256" \
            --text="SHA256? (incolla entro ${SHA_TIMEOUT}s o ignora)" \
            --width="$SHA_WIDTH" --timeout="$SHA_TIMEOUT" 2>/dev/null)
    fi
    if [ -n "$HASH_ATTESO" ]; then
        HASH_ATTESO=$(tr -d ' ' <<< "$HASH_ATTESO" | tr '[:upper:]' '[:lower:]')
        if [ "$HASH_CALCOLATO" != "$HASH_ATTESO" ]; then
            printf '%s' "❌ SHA256 NON CORRISPONDE: Il file potrebbe essere alterato.\n   Calcolato: $HASH_CALCOLATO\n   Atteso: $HASH_ATTESO\n\n" > "$SHA_TMP"
        fi
    fi
) &
SHA_PID=$!
fi

# ============================================================================
# ALTERNATIVA (non attiva): SHA dagli APPUNTI, senza alcun popup
# ----------------------------------------------------------------------------
# Idea: invece di CHIEDERE lo SHA a ogni download, guarda se negli appunti c'e'
# gia' un SHA256 (64 caratteri esadecimali). Se c'e', lo verifica in automatico;
# se non c'e', salta in silenzio. Cosi' nel caso normale non compare nulla, e
# risolve l'invasivita' alla radice (nessuna finestra da posizionare).
#
# Richiede lo strumento appunti della sessione:
#   Wayland (tuo caso): sudo apt install wl-clipboard   -> comando: wl-paste
#   X11:                sudo apt install xclip          -> comando: xclip -o -selection clipboard
#
# ATTENZIONE (falsi positivi): se negli appunti c'e' un SHA a caso NON legato a
# questo file (es. l'hash di un altro download), verrebbe segnalato come
# "non corrisponde" e il file finirebbe in quarantena a torto. Valuta se in
# quel caso vuoi solo avvisare invece di bloccare.
#
# Per ATTIVARLA: commenta il blocco "Prompt SHA in BACKGROUND" qui sopra
# (dalla riga SHA_TMP=... fino a SHA_PID=$!) e scommenta questo blocco.
#
# SHA_TMP=$(mktemp)
# (
#     CLIP=""
#     if command -v wl-paste &>/dev/null; then
#         CLIP=$(wl-paste 2>/dev/null)
#     elif command -v xclip &>/dev/null; then
#         CLIP=$(xclip -o -selection clipboard 2>/dev/null)
#     fi
#     # Prima sequenza di 64 hex trovata negli appunti, normalizzata minuscola.
#     HASH_ATTESO=$(grep -ioE '[a-f0-9]{64}' <<< "$CLIP" | head -n1 | tr '[:upper:]' '[:lower:]')
#     if [ -n "$HASH_ATTESO" ] && [ "$HASH_CALCOLATO" != "$HASH_ATTESO" ]; then
#         printf '%s' "❌ SHA256 NON CORRISPONDE (da appunti): Il file potrebbe essere alterato.\n   Calcolato: $HASH_CALCOLATO\n   Atteso: $HASH_ATTESO\n\n" > "$SHA_TMP"
#     fi
# ) &
# SHA_PID=$!
# ============================================================================

# --- Verifiche che partono SUBITO, in parallelo al prompt/appunti SHA ---

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
fi

# Scansione ClamAV (parte lenta: carica ~1GB di firme).
# exit 1 = virus, 2 = errore di scansione (non e' una minaccia).
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

# --- Join: aspetta il prompt/appunti SHA e raccogli l'esito ---
# (saltato in blocco se CHIEDI_SHA=0: nessun processo da aspettare)
if [ -n "$SHA_PID" ]; then
    wait "$SHA_PID"
    if [ -s "$SHA_TMP" ]; then PROBLEMI+="$(cat "$SHA_TMP")"; fi
    rm -f "$SHA_TMP"
fi

if [ -n "$PROBLEMI" ]; then echo -e "Sono state rilevate anomalie:\n\n$PROBLEMI"; exit 1; else exit 0; fi
