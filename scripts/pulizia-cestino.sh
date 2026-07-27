#!/bin/bash
# MusiGuard: pulizia settimanale (musiguard-cestino.timer -> .service).
# Due cose distinte, in ordine:
#   1. Cestino di sistema: svuotato SOLO se SVUOTA_CESTINO=1 nel conf
#      (modulo opzionale del wizard configura.sh, spento di default perché
#      distruttivo: elimina per sempre quello che è nel Cestino).
#   2. Quarantena di MusiGuard: la domanda "svuoto?" arriva SEMPRE, una
#      volta a settimana, indipendentemente dal punto 1 — non è un modulo
#      disattivabile, la Quarantena può contenere malware e non va lasciata
#      accumulare zitta.
set -u

CONF="${HOME}/.config/musiguard.conf"
DIR_QUARANTENA="${HOME}/PreDownload/.Quarantena"
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

# --- 1. Cestino di sistema (opzionale) ---
if [ "$SVUOTA_CESTINO" = 1 ]; then
    if command -v gio &>/dev/null; then
        # gio trash --empty svuota il Cestino "vero" (rispetta lo standard
        # XDG anche su volumi/mount diversi), non solo ~/.local/share/Trash.
        if gio trash --empty 2>>"$LOG_CESTINO"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🗑️ Cestino di sistema svuotato (gio trash --empty)." >> "$LOG_CESTINO"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ gio trash --empty ha restituito un errore." >> "$LOG_CESTINO"
        fi
    else
        # Fallback manuale sul solo Cestino XDG utente (nessun 'gio' installato).
        TRASH_DIR="${HOME}/.local/share/Trash"
        if [ -d "$TRASH_DIR" ]; then
            rm -rf "${TRASH_DIR:?}/files/"* "${TRASH_DIR:?}/info/"* 2>/dev/null
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🗑️ Cestino di sistema svuotato (fallback manuale, 'gio' non installato)." >> "$LOG_CESTINO"
        fi
    fi
    if command -v notify-send &>/dev/null; then
        notify-send --app-name="MusiGuard" --icon=user-trash -h int:transient:1 -t 5000 \
            "🗑️ Cestino svuotato" "Pulizia settimanale MusiGuard." 2>/dev/null
    fi
fi

# --- 2. Quarantena MusiGuard (sempre, indipendente dal punto 1) ---
# Guardia di sicurezza: prima di un rm -rf ricorsivo ci si assicura che il
# percorso sia esattamente quello atteso (non una variabile HOME vuota o
# rimasta indefinita), stesso spirito prudente del guardiano principale.
case "$DIR_QUARANTENA" in
    */PreDownload/.Quarantena) : ;;
    *) echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERRORE: percorso Quarantena inatteso ('$DIR_QUARANTENA'), pulizia settimanale annullata per sicurezza." >> "$LOG_QUARANTENA"
       exit 1 ;;
esac

if [ -d "$DIR_QUARANTENA" ]; then
    # -mindepth 1 esclude la cartella stessa dal conteggio dei file.
    mapfile -t FILE_QUARANTENA < <(find "$DIR_QUARANTENA" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)
    if [ "${#FILE_QUARANTENA[@]}" -gt 0 ]; then
        # Elenco leggibile per l'utente: nome, dimensione, data. chmod 000 sui
        # singoli file non impedisce di leggere i metadati della cartella.
        # stat + date per riga (non ls|awk): un nome file con spazi
        # spezzerebbe lo split per campi di awk e mostrerebbe dati sbagliati.
        ELENCO=""
        for F in "${FILE_QUARANTENA[@]}"; do
            P="$DIR_QUARANTENA/$F"
            SIZE=$(stat -c '%s' "$P" 2>/dev/null)
            MTIME=$(date -d "@$(stat -c '%Y' "$P" 2>/dev/null || echo 0)" '+%Y-%m-%d %H:%M' 2>/dev/null)
            ELENCO+=$(printf '%-10s %s  %s\n' "${SIZE:-?}" "${MTIME:-?}" "$F")
            ELENCO+=$'\n'
        done
        ELENCO_ESC=$(escape_markup "$ELENCO")
        N=${#FILE_QUARANTENA[@]}
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
