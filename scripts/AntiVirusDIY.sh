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

# NUOVO: seconda opinione VirusTotal. Lookup del SOLO hash sull'API v3: il
# file NON lascia mai il PC, viaggia una stringa di 64 caratteri. Con 70+
# motori compensa il punto debole di ClamAV da solo. Si accende solo se:
#   1) CONTROLLO_VT=1 nel conf (default: attivo), E
#   2) esiste la chiave API (gratuita: virustotal.com -> profilo -> API key)
#      in ~/.config/musiguard-vt.key (consigliato chmod 600).
# Senza chiave il modulo è spento e non costa nulla. Del file chiave si
# accetta SOLO una riga di 64 hex (stessa filosofia del conf: letto, mai
# eseguito, formato rigido).
CONTROLLO_VT=1
if [ -f "$CONF" ]; then
    VALORE=$(grep -E '^CONTROLLO_VT=[0-9]+$' "$CONF" | tail -n1 | cut -d= -f2)
    [ -n "$VALORE" ] && CONTROLLO_VT="$VALORE"
fi
VT_KEYFILE="${HOME}/.config/musiguard-vt.key"
VT_KEY=""
if [ "$CONTROLLO_VT" = "1" ] && [ -f "$VT_KEYFILE" ] && command -v curl &>/dev/null; then
    VT_KEY=$(grep -iE '^[a-f0-9]{64}$' "$VT_KEYFILE" | head -n1)
fi

# --- Controlli basati sull'hash (appunti + VirusTotal), in background ---
# Verifica SHA dagli APPUNTI, senza alcun popup.
# FIX: sostituisce il vecchio prompt yad/zenity (una finestra a OGNI download).
# Se negli appunti c'e' gia' un SHA256 (64 caratteri esadecimali) copiato dal
# sito del download, lo verifichiamo in automatico; se non c'e', si salta in
# silenzio: nel caso normale non compare nulla e non si calcola nulla.
# FIX: sha256sum viene calcolato SOLO se serve a qualcuno (hash negli appunti
# oppure modulo VirusTotal acceso) — e UNA volta sola per entrambi i controlli.
# Struttura invariata: subshell in background -> tmpfile -> wait (join) piu'
# avanti. I controlli sull'hash (sha256sum + eventuale richiesta di rete sono
# le parti lente) girano in parallelo alle verifiche locali qui sotto; canali
# separati (file vs variabile) -> nessuna race.
# Esiti VirusTotal che NON sono rilevazioni (hash mai visto, rete assente,
# rate limit del piano free: 4 richieste/min, chiave rifiutata): SILENZIO —
# un guasto di rete non deve bloccare i download; resta la copertura ClamAV.
# Strumento appunti della sessione:
#   Wayland (tuo caso): sudo apt install wl-clipboard   -> comando: wl-paste
#   X11:                sudo apt install xclip          -> comando: xclip -o -selection clipboard
HASH_PID=""
HASH_TMP=""
if [ "$CHIEDI_SHA" = "1" ] || [ -n "$VT_KEY" ]; then
HASH_TMP=$(mktemp)
(
    HASH_ATTESO=""
    if [ "$CHIEDI_SHA" = "1" ]; then
        CLIP=""
        if command -v wl-paste &>/dev/null; then
            CLIP=$(wl-paste 2>/dev/null)
        elif command -v xclip &>/dev/null; then
            CLIP=$(xclip -o -selection clipboard 2>/dev/null)
        fi
        # Prima sequenza di 64 hex trovata negli appunti, normalizzata minuscola.
        HASH_ATTESO=$(grep -ioE '[a-f0-9]{64}' <<< "$CLIP" | head -n1 | tr '[:upper:]' '[:lower:]')
    fi
    HASH_CALCOLATO=""
    if [ -n "$HASH_ATTESO" ] || [ -n "$VT_KEY" ]; then
        HASH_CALCOLATO=$(sha256sum "$FILE" | awk '{print $1}')
    fi
    if [ -n "$HASH_ATTESO" ] && [ "$HASH_CALCOLATO" != "$HASH_ATTESO" ]; then
        printf '%s' "❌ SHA256 NON CORRISPONDE (hash preso dagli APPUNTI): il file potrebbe essere alterato — oppure l'hash copiato si riferisce a un ALTRO file (falso positivo possibile, controlla cosa avevi negli appunti).\n   Calcolato: $HASH_CALCOLATO\n   Atteso (appunti): $HASH_ATTESO\n\n" >> "$HASH_TMP"
    fi
    if [ -n "$VT_KEY" ]; then
        # curl -f: su 404 (hash sconosciuto) e 4xx/5xx il body resta vuoto e
        # il parsing sotto non trova nulla -> silenzio, come da politica.
        # --max-time 15: una rete che pende non deve fermare la coda download.
        RISPOSTA=$(curl -sf --max-time 15 -H "x-apikey: $VT_KEY" \
            "https://www.virustotal.com/api/v3/files/$HASH_CALCOLATO" 2>/dev/null)
        if command -v jq &>/dev/null; then
            VT_MAL=$(jq -r '.data.attributes.last_analysis_stats.malicious // ""' <<< "$RISPOSTA" 2>/dev/null)
            VT_SUS=$(jq -r '.data.attributes.last_analysis_stats.suspicious // ""' <<< "$RISPOSTA" 2>/dev/null)
        else
            # Fallback senza jq: il blocco last_analysis_stats è piatto
            # ({"malicious":N,...}), si estrae con grep dopo aver tolto spazi.
            STATS=$(tr -d ' \n' <<< "$RISPOSTA" | grep -oE '"last_analysis_stats":\{[^}]*\}' | head -n1)
            VT_MAL=$(grep -oE '"malicious":[0-9]+' <<< "$STATS" | head -n1 | cut -d: -f2)
            VT_SUS=$(grep -oE '"suspicious":[0-9]+' <<< "$STATS" | head -n1 | cut -d: -f2)
        fi
        [[ "${VT_MAL:-}" =~ ^[0-9]+$ ]] || VT_MAL=0
        [[ "${VT_SUS:-}" =~ ^[0-9]+$ ]] || VT_SUS=0
        if [ "$VT_MAL" -gt 0 ] || [ "$VT_SUS" -gt 0 ]; then
            printf '%s' "☣️ VIRUSTOTAL: questo file è segnalato da $VT_MAL motori antivirus come MALEVOLO e da $VT_SUS come sospetto (verificato il solo hash, il file non è stato inviato).\n   Dettagli: https://www.virustotal.com/gui/file/$HASH_CALCOLATO\n\n" >> "$HASH_TMP"
        fi
    fi
) &
HASH_PID=$!
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

# NUOVO: anti-spoofing del NOME (il controllo MIME sopra guarda il contenuto;
# qui si guarda il nome, cioè quello che l'occhio dell'utente vede davvero).
# 1) Caratteri Unicode direzionali o invisibili: con U+202E (RTLO) un nome
#    tipo "fattura<RTLO>fdp.exe" viene MOSTRATO come "fatturaexe.pdf" — il
#    trucco classico per far cliccare un eseguibile. Nessun download
#    legittimo ha bisogno di questi caratteri nel nome; si copre anche la
#    famiglia zero-width (U+200B..) e gli isolati bidirezionali (U+2066..).
if grep -qP '[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}]' <<< "$NOME_FILE"; then
    PROBLEMI+="❌ NOME INGANNEVOLE: il nome contiene caratteri Unicode invisibili o direzionali (trucco RTLO): quello che leggi NON è il vero nome del file.\n\n"
fi
# 2) Doppia estensione ingannevole ("fattura.pdf.exe"): estensione FINALE
#    eseguibile/script preceduta da un'estensione da documento/media messa
#    lì per ingannare. Copre anche i tipi che il controllo MIME non prende
#    (js/vbs/ps1 per "file" sono solo testo, jar è uno zip). Gli spazi
#    attorno alla penultima estensione si scartano: neutralizza il trucco
#    del riempimento "documento.pdf                .exe".
if [[ "$NOME_FILE" == *.*.* ]]; then
    SENZA_ULTIMA="${NOME_FILE%.*}"
    EXT_PENULTIMA=$(tr '[:upper:]' '[:lower:]' <<< "${SENZA_ULTIMA##*.}" | tr -d ' ')
    case "$EXTENSION" in
        exe|scr|com|pif|bat|cmd|msi|js|jse|vbs|vbe|wsf|ps1|hta|jar|sh|run|bin|appimage)
            case "$EXT_PENULTIMA" in
                pdf|doc|docx|xls|xlsx|ppt|pptx|odt|txt|rtf|csv|jpg|jpeg|png|gif|webp|svg|mp3|wav|flac|mp4|mkv|avi|mov|zip|rar|7z)
                    PROBLEMI+="❌ DOPPIA ESTENSIONE INGANNEVOLE: \"$NOME_FILE\" si spaccia per un .$EXT_PENULTIMA ma in realtà è un .$EXTENSION (eseguibile/script). Trucco classico per far aprire malware.\n\n"
                    ;;
            esac
            ;;
    esac
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

# --- Join: aspetta i controlli basati sull'hash e raccogli l'esito ---
# (saltato in blocco se appunti SHA e VirusTotal sono entrambi spenti)
if [ -n "$HASH_PID" ]; then
    wait "$HASH_PID"
    if [ -s "$HASH_TMP" ]; then PROBLEMI+="$(cat "$HASH_TMP")"; fi
    rm -f "$HASH_TMP"
fi

if [ -n "$PROBLEMI" ]; then echo -e "Sono state rilevate anomalie:\n\n$PROBLEMI"; exit 1; else exit 0; fi
