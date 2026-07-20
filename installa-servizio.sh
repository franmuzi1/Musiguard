#!/bin/bash
# Installa (o aggiorna) il servizio utente di MusiGuard e lo avvia:
#   - musiguard-guardiano.service  (watcher download, sempre attivo in sessione)
# Rilanciarlo dopo ogni modifica alle unit: ricopia e ricarica tutto.
# Ritira anche le unit con i VECCHI nomi (guardiano.service, pulizia.*):
# la vecchia guardiano.service era la causa delle istanze doppie.
set -u

DIR_SRC="$(cd "$(dirname "$0")" && pwd)"
UNIT_DIR="${HOME}/.config/systemd/user"
UNITS=(musiguard-guardiano.service)
UNITS_VECCHIE=(guardiano.service pulizia.timer pulizia.service)

for U in "${UNITS[@]}"; do
    if [ ! -f "$DIR_SRC/systemd/$U" ]; then
        echo "Errore: $DIR_SRC/systemd/$U non trovato." >&2
        exit 1
    fi
done
if [ ! -f "$DIR_SRC/scripts/configura.sh" ]; then
    echo "Errore: $DIR_SRC/scripts/configura.sh non trovato." >&2
    exit 1
fi

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
for U in "${UNITS[@]}"; do cp "$DIR_SRC/systemd/$U" "$UNIT_DIR/"; done
systemctl --user daemon-reload

# PRIMO AVVIO: se il conf non esiste, partono le configurazioni guidate.
# Prima quella del volume virtuale isolato (così il guardiano nasce già sul
# volume noexec), poi il wizard dei moduli (scrive il conf e attiva/disattiva
# i servizi da solo). In seguito si rilanciano a mano:
#   sudo ./scripts/crea-disco-predownload.sh   e   ./scripts/configura.sh
CONF="${HOME}/.config/musiguard.conf"
if [ ! -f "$CONF" ]; then
    if [ -f "${HOME}/pre_download_disk.img" ]; then
        echo "Volume virtuale isolato: già presente (~/pre_download_disk.img), salto la guida."
    else
        SPIEGA="MusiGuard può creare un volume virtuale isolato per ~/PreDownload, dove atterrano i download.

Vantaggi: è un disco separato montato noexec/nosuid — nulla di scaricato può essere eseguito da lì, nemmeno per sbaglio, e la quarantena resta confinata dentro.

Il volume è ELASTICO: la dimensione scelta è solo un tetto virtuale. 100GB dichiarati NON occupano davvero 100GB — sul disco vero pesa solo quanto i file davvero presenti.

Serve la password di amministratore (sudo). Creare il volume adesso?"
        CREA=0
        GB=50
        if command -v zenity &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            if zenity --question --title="Configurazione guidata volume virtuale isolato" \
                    --text="$SPIEGA" --ok-label="Crea il volume" --cancel-label="Salta" \
                    --width=540 2>/dev/null; then
                GB=$(zenity --entry --title="Configurazione guidata volume virtuale isolato" \
                    --text="Dimensione virtuale in GB (tetto elastico, non spazio occupato):" \
                    --entry-text=50 2>/dev/null) || GB=50
                CREA=1
            fi
        else
            echo
            echo "== Configurazione guidata volume virtuale isolato =="
            echo "$SPIEGA"
            read -rp "[S/n] " RISPOSTA
            if [[ ! "$RISPOSTA" =~ ^[nN] ]]; then
                read -rp "Dimensione virtuale in GB [50]: " GB_SCELTI
                GB="${GB_SCELTI:-50}"
                CREA=1
            fi
        fi
        if [ "$CREA" = 1 ]; then
            # Dimensione non numerica (o vuota): si ripiega sul default.
            case "$GB" in ''|*[!0-9]*) GB=50 ;; esac
            sudo "$DIR_SRC/scripts/crea-disco-predownload.sh" "$GB" || {
                echo "Volume non creato: MusiGuard funziona comunque; per riprovare:"
                echo "  sudo $DIR_SRC/scripts/crea-disco-predownload.sh"
            }
        else
            echo "Volume saltato: creabile in ogni momento con sudo ./scripts/crea-disco-predownload.sh"
        fi
    fi
    "$DIR_SRC/scripts/configura.sh"
fi

# Applica le scelte dei moduli (default: tutto attivo).
leggi() {
    local V=""
    [ -f "$CONF" ] && V=$(grep -E "^$1=[0-9]+$" "$CONF" | tail -n1 | cut -d= -f2)
    echo "${V:-$2}"
}
if [ "$(leggi ATTIVA_GUARDIANO 1)" = 1 ]; then
    systemctl --user enable musiguard-guardiano.service
    systemctl --user restart musiguard-guardiano.service
else
    systemctl --user disable --now musiguard-guardiano.service 2>/dev/null || true
    echo "Guardiano disattivato da configurazione (riattivabile con ./scripts/configura.sh)."
fi

echo
systemctl --user status musiguard-guardiano.service --no-pager || true
echo
echo "Fatto. Comandi utili:"
echo "  log guardiano:    journalctl --user -u musiguard-guardiano -f"
echo "  stato:            systemctl --user status musiguard-guardiano"
echo "  stop/disinstallo: systemctl --user disable --now musiguard-guardiano.service"
