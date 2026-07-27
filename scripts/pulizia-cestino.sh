#!/bin/bash
# MusiGuard: pulizia settimanale (musiguard-cestino.timer -> .service).
# Due controlli distinti, stesso trattamento (elenco + domanda, mai
# cancellazione silenziosa):
#   1. Cestino di sistema: la domanda arriva SOLO se SVUOTA_CESTINO=1 nel
#      conf (modulo opzionale del wizard configura.sh, spento di default).
#   2. Quarantena di MusiGuard: la domanda arriva SEMPRE, indipendentemente
#      dal punto 1 — non è un modulo disattivabile, la Quarantena può
#      contenere malware e non va lasciata accumulare zitta.
set -u

CONF="${HOME}/.config/musiguard.conf"
DIR_QUARANTENA="${HOME}/PreDownload/.Quarantena"
DIR_CESTINO="${HOME}/.local/share/Trash/files"
LOG_QUARANTENA="${HOME}/MusiGuard/quarantena.log"
LOG_CESTINO="${HOME}/MusiGuard/cestino.log"

leggi_conf() {
    local V=""
    [ -f "$CONF" ] && V=$(grep -E "^$1=[0-9]+$" "$CONF" | tail -n1 | cut -d= -f2)
    echo "${V:-$2}"
}
SVUOTA_CESTINO=$(leggi_conf SVUOTA_CESTINO 0)

# Lock anti-doppia-istanza: stesso schema del guardiano (flock -n, fd 9).
LOCKFILE="${HOME}/MusiGuard/.cestino.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "Pulizia settimanale già in esecuzione (lock: $LOCKFILE), esco." >&2
    exit 0
fi

escape_markup() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<< "$1"
}

# Elenco leggibile per l'utente: nome, dimensione, data. stat + date riga per
# riga (non ls|awk): un nome file con spazi spezzerebbe lo split per campi di
# awk e mostrerebbe dati sbagliati.
costruisci_elenco() {
    local DIR="$1" F P SIZE MTIME
    shift
    for F in "$@"; do
        P="$DIR/$F"
        SIZE=$(stat -c '%s' "$P" 2>/dev/null)
        MTIME=$(date -d "@$(stat -c '%Y' "$P" 2>/dev/null || echo 0)" '+%Y-%m-%d %H:%M' 2>/dev/null)
        printf '%-10s %s  %s\n' "${SIZE:-?}" "${MTIME:-?}" "$F"
    done
}

# --- 1. Cestino di sistema (opzionale: solo se SVUOTA_CESTINO=1) ---
# Guardia di sicurezza: prima di toccare qualunque cosa ci si assicura che il
# percorso sia esattamente quello atteso (non una variabile HOME vuota o
# rimasta indefinita), stesso spirito prudente del guardiano principale.
case "$DIR_CESTINO" in
    */.local/share/Trash/files) : ;;
    *) echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERRORE: percorso Cestino inatteso ('$DIR_CESTINO'), controllo saltato per sicurezza." >> "$LOG_CESTINO"
       DIR_CESTINO="" ;;
esac

if [ "$SVUOTA_CESTINO" = 1 ] && [ -n "$DIR_CESTINO" ] && [ -d "$DIR_CESTINO" ]; then
    mapfile -t FILE_CESTINO < <(find "$DIR_CESTINO" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)
    if [ "${#FILE_CESTINO[@]}" -gt 0 ]; then
        N=${#FILE_CESTINO[@]}
        ELENCO_ESC=$(escape_markup "$(costruisci_elenco "$DIR_CESTINO" "${FILE_CESTINO[@]}")")
        if command -v zenity &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            if zenity --question --title="🗑️ Pulizia settimanale: Cestino di sistema" \
                --text="Ci sono <b>$N</b> elementi nel Cestino:\n\n<tt>$ELENCO_ESC</tt>\n\nVuoi eliminarli TUTTI definitivamente adesso?" \
                --ok-label="🗑️ Elimina tutti" --cancel-label="🗑️ Lascia nel Cestino" \
                --width=560 2>/dev/null; then
                # gio trash --empty svuota il Cestino "vero" (rispetta lo
                # standard XDG anche su volumi/mount diversi, pulisce anche i
                # metadati .trashinfo in info/), preferito al rm manuale.
                if command -v gio &>/dev/null && gio trash --empty 2>>"$LOG_CESTINO"; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🗑️ Pulizia settimanale: Cestino svuotato ($N elementi, conferma utente, gio trash --empty)." >> "$LOG_CESTINO"
                else
                    rm -rf -- "${FILE_CESTINO[@]/#/$DIR_CESTINO/}"
                    rm -rf "${DIR_CESTINO%/files}/info/"* 2>/dev/null
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🗑️ Pulizia settimanale: Cestino svuotato ($N elementi, conferma utente, fallback manuale)." >> "$LOG_CESTINO"
                fi
                zenity --notification --text="🗑️ Cestino svuotato: $N elementi eliminati." 2>/dev/null
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🛡️ Pulizia settimanale: Cestino lasciato invariato dall'utente ($N elementi)." >> "$LOG_CESTINO"
            fi
        else
            # Nessuna sessione grafica: si avvisa soltanto, non si elimina
            # nulla senza conferma esplicita dell'utente.
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ℹ️ Pulizia settimanale: $N elementi nel Cestino, nessuna sessione grafica per chiedere conferma (lasciati intatti)." >> "$LOG_CESTINO"
            if command -v notify-send &>/dev/null; then
                notify-send --app-name="MusiGuard" --icon=dialog-warning "🗑️ Cestino di sistema" "$N elementi nel Cestino da rivedere: cestino.log." 2>/dev/null
            fi
        fi
    fi
fi

# --- 2. Quarantena MusiGuard (sempre, indipendente dal punto 1) ---
case "$DIR_QUARANTENA" in
    */PreDownload/.Quarantena) : ;;
    *) echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERRORE: percorso Quarantena inatteso ('$DIR_QUARANTENA'), pulizia settimanale annullata per sicurezza." >> "$LOG_QUARANTENA"
       exit 1 ;;
esac

if [ -d "$DIR_QUARANTENA" ]; then
    # -mindepth 1 esclude la cartella stessa dal conteggio dei file.
    mapfile -t FILE_QUARANTENA < <(find "$DIR_QUARANTENA" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)
    if [ "${#FILE_QUARANTENA[@]}" -gt 0 ]; then
        N=${#FILE_QUARANTENA[@]}
        # chmod 000 sui singoli file non impedisce di leggere i metadati
        # della cartella (dimensione/data), quindi costruisci_elenco funziona.
        ELENCO_ESC=$(escape_markup "$(costruisci_elenco "$DIR_QUARANTENA" "${FILE_QUARANTENA[@]}")")
        if command -v zenity &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            if zenity --question --title="🔒 Pulizia settimanale: Quarantena MusiGuard" \
                --text="Ci sono <b>$N</b> file in quarantena (sospetti, mai eseguibili) da tempo:\n\n<tt>$ELENCO_ESC</tt>\n\nVuoi eliminarli TUTTI definitivamente adesso?" \
                --ok-label="🗑️ Elimina tutti" --cancel-label="🛡️ Lascia in quarantena" \
                --width=560 2>/dev/null; then
                rm -rf -- "${FILE_QUARANTENA[@]/#/$DIR_QUARANTENA/}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🗑️ Pulizia settimanale: eliminati $N file dalla quarantena (conferma utente)." >> "$LOG_QUARANTENA"
                zenity --notification --text="🗑️ Quarantena svuotata: $N file eliminati." 2>/dev/null
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🛡️ Pulizia settimanale: quarantena lasciata invariata dall'utente ($N file)." >> "$LOG_QUARANTENA"
            fi
        else
            # Nessuna sessione grafica: si avvisa soltanto, non si elimina nulla
            # senza conferma esplicita dell'utente.
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ℹ️ Pulizia settimanale: $N file in quarantena, nessuna sessione grafica per chiedere conferma (lasciati intatti)." >> "$LOG_QUARANTENA"
            if command -v notify-send &>/dev/null; then
                notify-send --app-name="MusiGuard" --icon=dialog-warning "🔒 Quarantena MusiGuard" "$N file in quarantena da rivedere: journalctl o quarantena.log." 2>/dev/null
            fi
        fi
    fi
fi
