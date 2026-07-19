#!/bin/bash
# Sincro Syncthing "a orario": avvia il servizio, aspetta che la
# sincronizzazione arrivi al 100% (via API REST locale), poi lo spegne.
# Filosofia: una sincro al giorno come la pulizia, invece di un demone
# sempre acceso. Se Syncthing sta già girando (avviato a mano), non si
# tocca nulla. La lancia musiguard-sincro.timer.
# Config letta da quella di Syncthing stesso (indirizzo GUI + chiave API):
# niente da configurare qui. Tetto di attesa: SINCRO_MAX_MINUTI nel
# musiguard.conf (default 30); allo scadere si spegne comunque — capita
# quando gli altri dispositivi (telefono) sono offline.
# set -u: variabile non definita = errore fatale, non stringa vuota silenziosa.
set -u

LOG="${HOME}/MusiGuard/sincro.log"
LOCKFILE="${HOME}/MusiGuard/.sincro.lock"
CONF="${HOME}/.config/musiguard.conf"
leggi_conf() {
    local V=""
    [ -f "$CONF" ] && V=$(grep -E "^$1=[0-9]+$" "$CONF" | tail -n1 | cut -d= -f2)
    echo "${V:-$2}"
}
MAX_MINUTI=$(leggi_conf SINCRO_MAX_MINUTI 30)

mkdir -p "$(dirname "$LOG")"
# Lock anti-sovrapposizione e rotazione log: stesso schema della pulizia.
exec 9>"$LOCKFILE"
flock -n 9 || exit 0
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv -f "$LOG" "${LOG}.old"
fi
exec >> "$LOG" 2>&1

avvisa() { # titolo corpo [icona]
    command -v notify-send &>/dev/null && \
        notify-send --app-name="Sincro Syncthing" --icon="${3:-emblem-synchronizing}" "$1" "$2" 2>/dev/null
}

# Se gira già (l'hai avviato tu): non è compito nostro fermarlo.
if systemctl --user is-active --quiet syncthing.service; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncthing già attivo (avviato a mano?): non tocco nulla."
    exit 0
fi

# Indirizzo GUI e chiave API dalla config di Syncthing (v2: ~/.local/state;
# vecchie versioni: ~/.config). La chiave si accetta solo dal suo tag.
CFG=""
for C in "${HOME}/.local/state/syncthing/config.xml" "${HOME}/.config/syncthing/config.xml"; do
    [ -f "$C" ] && CFG="$C" && break
done
if [ -z "$CFG" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRORE: config di Syncthing non trovata."
    avvisa "❌ Sincro fallita" "Config di Syncthing non trovata." dialog-error
    exit 1
fi
GUI=$(awk '/<gui/,/<\/gui>/' "$CFG")
APIKEY=$(sed -n 's/.*<apikey>\([^<]*\)<\/apikey>.*/\1/p' <<< "$GUI" | head -n1)
ADDR=$(sed -n 's/.*<address>\([^<]*\)<\/address>.*/\1/p' <<< "$GUI" | head -n1)
[ -z "$ADDR" ] && ADDR="127.0.0.1:8384"
# GUI in ascolto su tutte le interfacce: per parlarle localmente va bene loopback.
ADDR="${ADDR/0.0.0.0/127.0.0.1}"
PROTO="http"; CURL_TLS=()
grep -q 'tls="true"' <<< "$GUI" && { PROTO="https"; CURL_TLS=(-k); }
if [ -z "$APIKEY" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRORE: chiave API non trovata in $CFG."
    avvisa "❌ Sincro fallita" "Chiave API di Syncthing non trovata." dialog-error
    exit 1
fi
api() { curl -sf "${CURL_TLS[@]}" --max-time 10 -H "X-API-Key: $APIKEY" "$PROTO://$ADDR/rest/$1" 2>/dev/null; }

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🟢 Avvio Syncthing (tetto: ${MAX_MINUTI} min)."
if ! systemctl --user start syncthing.service; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRORE: avvio di syncthing.service fallito."
    avvisa "❌ Sincro fallita" "Impossibile avviare syncthing.service." dialog-error
    exit 1
fi
INIZIO=$(date +%s)

# Attesa che l'API risponda (max ~90s).
API_SU=0
for _ in $(seq 1 30); do
    api system/ping >/dev/null && { API_SU=1; break; }
    sleep 3
done
if [ "$API_SU" -ne 1 ]; then
    systemctl --user stop syncthing.service
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRORE: l'API di Syncthing non risponde su $PROTO://$ADDR."
    avvisa "❌ Sincro fallita" "L'API di Syncthing non risponde. Controlla ~/MusiGuard/sincro.log" dialog-error
    exit 1
fi

# Attesa sincronizzazione: /rest/db/completion senza parametri = completamento
# aggregato di tutte le cartelle e i dispositivi. Si chiude quando resta al
# 100% per due letture consecutive (assestamento), o allo scadere del tetto.
SCADENZA=$((INIZIO + MAX_MINUTI * 60))
COMPLETO=0
STABILE=0
PCT="?"
while [ "$(date +%s)" -lt "$SCADENZA" ]; do
    RISPOSTA=$(api db/completion)
    P=$(jq -r '.completion // empty' <<< "$RISPOSTA" 2>/dev/null)
    if [[ "$P" =~ ^[0-9.]+$ ]]; then
        PCT="${P%.*}"
        if [ "$PCT" -ge 100 ]; then
            STABILE=$((STABILE + 1))
            [ "$STABILE" -ge 2 ] && { COMPLETO=1; break; }
        else
            STABILE=0
        fi
    fi
    sleep 20
done

systemctl --user stop syncthing.service
MINUTI=$(( ($(date +%s) - INIZIO + 30) / 60 ))
if [ "$COMPLETO" -eq 1 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Sincronizzazione completa in ~${MINUTI} min. Syncthing spento."
    avvisa "✅ Sincro completata" "Tutto sincronizzato in ~${MINUTI} min. Syncthing spento fino a domani."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏳ Tetto di ${MAX_MINUTI} min raggiunto al ${PCT}%. Syncthing spento comunque."
    avvisa "⏳ Sincro parziale (${PCT}%)" "Tempo scaduto: probabilmente gli altri dispositivi erano offline. Riproverà domani." dialog-warning
fi
