#!/bin/bash
# Sentinella spazio disco: se il filesystem di HOME supera la soglia, arriva
# una notifica desktop coi 5 "pesi massimi" del momento — così il disco pieno
# lo scopri quando c'è ancora margine, non a sistema piantato.
# NON cancella nulla da sola: suggerisce soltanto (le cache di PlatformIO e
# Arduino, per esempio, si potano a mano con: pio system prune).
# La lancia musiguard-sentinella.timer una volta al giorno.
# set -u: variabile non definita = errore fatale, non stringa vuota silenziosa.
set -u

LOG="${HOME}/MusiGuard/sentinella.log"
LOCKFILE="${HOME}/MusiGuard/.sentinella.lock"

# Soglia (percentuale di uso) da ~/.config/musiguard.conf, chiave
# SOGLIA_DISCO_PCT; default 90. Il conf viene LETTO, mai eseguito.
CONF="${HOME}/.config/musiguard.conf"
leggi_conf() {
    local V=""
    [ -f "$CONF" ] && V=$(grep -E "^$1=[0-9]+$" "$CONF" | tail -n1 | cut -d= -f2)
    echo "${V:-$2}"
}
SOGLIA=$(leggi_conf SOGLIA_DISCO_PCT 90)

mkdir -p "$(dirname "$LOG")"
# Lock anti-sovrapposizione e rotazione log: stesso schema della pulizia.
exec 9>"$LOCKFILE"
flock -n 9 || exit 0
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv -f "$LOG" "${LOG}.old"
fi
exec >> "$LOG" 2>&1

USO=$(df --output=pcent "$HOME" | tail -n1 | tr -dc '0-9')
if [ -z "$USO" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRORE: df non ha risposto per $HOME"
    exit 1
fi

if [ "$USO" -lt "$SOGLIA" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: disco al ${USO}% (soglia ${SOGLIA}%)."
    exit 0
fi

# Sopra soglia: si calcolano i pesi massimi SOLO ora (du su tutta la HOME
# costa qualche secondo, inutile pagarlo nei giorni tranquilli).
# sed '2,6': la prima riga di du è il totale della HOME, si scarta.
PESI=$(du -xh --max-depth=1 "$HOME" 2>/dev/null | sort -rh | sed -n '2,6p' \
    | awk -F'\t' '{n=$2; sub(".*/","",n); printf "  %s  %s\n", $1, n}')
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ DISCO AL ${USO}% (soglia ${SOGLIA}%). Pesi massimi:"
echo "$PESI"

if command -v notify-send &>/dev/null; then
    # urgency=critical: la notifica resta finché non la chiudi tu.
    notify-send --app-name="Sentinella disco" --icon=drive-harddisk \
        --urgency=critical \
        "⚠️ Disco al ${USO}%" \
        "Le 5 cartelle più pesanti della home:
$PESI
Suggerimento: le cache PlatformIO/Arduino si potano con 'pio system prune'." 2>/dev/null
fi
