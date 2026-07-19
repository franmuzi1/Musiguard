#!/bin/bash
# Installa (o aggiorna) i servizi utente di MusiGuard e li avvia:
#   - musiguard-guardiano.service  (watcher download, sempre attivo in sessione)
#   - musiguard-pulizia.timer      (manutenzione giornaliera)
# Rilanciarlo dopo ogni modifica alle unit: ricopia e ricarica tutto.
# Ritira anche le unit con i VECCHI nomi (guardiano.service, pulizia.*):
# la vecchia guardiano.service era la causa delle istanze doppie.
set -u

DIR_SRC="$(cd "$(dirname "$0")" && pwd)"
UNIT_DIR="${HOME}/.config/systemd/user"
UNITS=(musiguard-guardiano.service musiguard-pulizia.service musiguard-pulizia.timer)
UNITS_VECCHIE=(guardiano.service pulizia.timer pulizia.service)

for U in "${UNITS[@]}"; do
    if [ ! -f "$DIR_SRC/$U" ]; then
        echo "Errore: $DIR_SRC/$U non trovato." >&2
        exit 1
    fi
done

# Se il guardiano gira già a mano, il lock farebbe uscire subito l'istanza
# del servizio: meglio avvisare ed uscire che installare un servizio zombie.
# NB: non scatta per il servizio stesso (systemctl restart lo ferma prima).
if systemctl --user is-active --quiet musiguard-guardiano.service; then
    : # il servizio è già nostro: il restart sotto lo gestisce
elif [ -e "${HOME}/MusiGuard/.guardiano.lock" ] && ! flock -n -x "${HOME}/MusiGuard/.guardiano.lock" true 2>/dev/null; then
    echo "AVVISO: c'è già un guardiano in esecuzione (probabilmente lanciato a mano)." >&2
    echo "        Chiudilo prima di installare il servizio, poi rilancia questo script." >&2
    exit 1
fi

# Ritira le unit coi vecchi nomi, se presenti (ignora gli errori: potrebbero
# non essere mai state installate su questa macchina).
for U in "${UNITS_VECCHIE[@]}"; do
    systemctl --user disable --now "$U" 2>/dev/null || true
    rm -f "$UNIT_DIR/$U"
done

mkdir -p "$UNIT_DIR"
for U in "${UNITS[@]}"; do cp "$DIR_SRC/$U" "$UNIT_DIR/"; done
systemctl --user daemon-reload
systemctl --user enable musiguard-guardiano.service musiguard-pulizia.timer
systemctl --user restart musiguard-guardiano.service
systemctl --user start musiguard-pulizia.timer

echo
systemctl --user status musiguard-guardiano.service --no-pager || true
echo
systemctl --user list-timers musiguard-pulizia.timer --no-pager || true
echo
echo "Fatto. Comandi utili:"
echo "  log guardiano:    journalctl --user -u musiguard-guardiano -f"
echo "  log pulizia:      cat ~/MusiGuard/manutenzione.log"
echo "  stato:            systemctl --user status musiguard-guardiano musiguard-pulizia.timer"
echo "  stop/disinstallo: systemctl --user disable --now musiguard-guardiano.service musiguard-pulizia.timer"
