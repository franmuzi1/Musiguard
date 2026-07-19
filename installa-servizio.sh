#!/bin/bash
# Installa (o aggiorna) il servizio utente del guardiano e lo avvia.
# Rilanciarlo dopo ogni modifica alla unit: ricopia e ricarica tutto.
set -u

UNIT_NOME="musiguard-guardiano.service"
UNIT_SRC="$(cd "$(dirname "$0")" && pwd)/$UNIT_NOME"
UNIT_DIR="${HOME}/.config/systemd/user"

if [ ! -f "$UNIT_SRC" ]; then
    echo "Errore: $UNIT_SRC non trovato." >&2
    exit 1
fi

# Se il guardiano gira già a mano, il lock farebbe uscire subito l'istanza
# del servizio: meglio avvisare ed uscire che installare un servizio zombie.
if [ -e "${HOME}/MusiGuard/.guardiano.lock" ] && ! flock -n -x "${HOME}/MusiGuard/.guardiano.lock" true 2>/dev/null; then
    echo "AVVISO: c'è già un guardiano in esecuzione (probabilmente lanciato a mano)." >&2
    echo "        Chiudilo prima di installare il servizio, poi rilancia questo script." >&2
    exit 1
fi

mkdir -p "$UNIT_DIR"
cp "$UNIT_SRC" "$UNIT_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NOME"

echo
systemctl --user status "$UNIT_NOME" --no-pager || true
echo
echo "Fatto. Comandi utili:"
echo "  log in diretta:  journalctl --user -u $UNIT_NOME -f"
echo "  stato:           systemctl --user status $UNIT_NOME"
echo "  stop/disinstallo: systemctl --user disable --now $UNIT_NOME"
