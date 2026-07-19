#!/bin/bash
# Configurazione dei moduli MusiGuard. Parte da sola alla PRIMA installazione
# (quando ~/.config/musiguard.conf non esiste) e si può rilanciare quando si
# vuole: ./configura.sh — i valori attuali sono preimpostati nella finestra.
# Scrive SOLO righe CHIAVE=numero: il conf viene letto, mai eseguito.
set -u

CONF="${HOME}/.config/musiguard.conf"
UNIT_DIR="${HOME}/.config/systemd/user"

# Legge una chiave numerica dal conf; se manca vale il default (2° argomento).
leggi() {
    local V=""
    [ -f "$CONF" ] && V=$(grep -E "^$1=[0-9]+$" "$CONF" | tail -n1 | cut -d= -f2)
    echo "${V:-$2}"
}

# Stato attuale come default del wizard (tutto attivo al primo avvio).
# SMISTA: si legge anche la vecchia chiave SMISTA_CATEGORIE (conf esistenti).
GUARDIANO=$(leggi ATTIVA_GUARDIANO 1)
PULIZIA=$(leggi ATTIVA_PULIZIA 1)
SHA=$(leggi CHIEDI_SHA 1)
ESTRAI=$(leggi ESTRAI_ARCHIVI 1)
SMISTA=$(leggi SMISTA_ESTENSIONE "$(leggi SMISTA_CATEGORIE 1)")
MAX_MB=$(leggi MAX_ESTRAZIONE_MB 10240)

b2z() { [ "$1" = 1 ] && echo TRUE || echo FALSE; }

if command -v zenity &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    # --print-column=2 restituisce gli ID delle righe spuntate, separati da |.
    SEL=$(zenity --list --checklist --title="MusiGuard — Configurazione moduli" \
        --text="Scegli i moduli da attivare (riconfigurabile con ./configura.sh):" \
        --column="Attivo" --column="ID" --column="Modulo" \
        --hide-column=2 --print-column=2 --separator="|" \
        "$(b2z "$GUARDIANO")" guardiano "🛡️ Antivirus download: controlla che i file scaricati NON siano pericolosi (da solo non smista: i file sicuri vanno in Downloads)" \
        "$(b2z "$PULIZIA")"   pulizia   "🧹 Pulizia giornaliera (Downloads vecchi, cestino, cache)" \
        "$(b2z "$SHA")"       sha       "🔎 Verifica SHA256 dagli appunti" \
        "$(b2z "$ESTRAI")"    estrai    "📦 Estrazione automatica degli archivi" \
        "$(b2z "$SMISTA")"    smista    "📂 Smistamento per estensione (senza: tutto in Downloads)" \
        --width=640 --height=360 2>/dev/null) || {
        echo "Configurazione annullata: nessuna modifica."
        exit 0
    }
    attivo() { [[ "|$SEL|" == *"|$1|"* ]] && echo 1 || echo 0; }
    GUARDIANO=$(attivo guardiano)
    PULIZIA=$(attivo pulizia)
    SHA=$(attivo sha)
    ESTRAI=$(attivo estrai)
    SMISTA=$(attivo smista)
else
    # Fallback senza sessione grafica: domande in terminale.
    chiedi() { # testo default -> 0/1
        local R
        if [ "$2" = 1 ]; then
            read -rp "$1 [S/n] " R; [[ "$R" =~ ^[nN] ]] && echo 0 || echo 1
        else
            read -rp "$1 [s/N] " R; [[ "$R" =~ ^[sS] ]] && echo 1 || echo 0
        fi
    }
    echo "MusiGuard — configurazione moduli (Invio = valore tra parentesi)"
    GUARDIANO=$(chiedi "🛡️ Attivare l'antivirus download? (controlla che i file non siano pericolosi; da solo non smista)" "$GUARDIANO")
    PULIZIA=$(chiedi "🧹 Attivare la pulizia giornaliera?" "$PULIZIA")
    SHA=$(chiedi "🔎 Attivare la verifica SHA256 dagli appunti?" "$SHA")
    ESTRAI=$(chiedi "📦 Attivare l'estrazione automatica degli archivi?" "$ESTRAI")
    SMISTA=$(chiedi "📂 Attivare lo smistamento per estensione?" "$SMISTA")
fi

mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<EOF
# MusiGuard — configurazione moduli (generata da configura.sh, rilanciabile).
# Solo righe CHIAVE=numero: tutto il resto viene ignorato, mai eseguito.
ATTIVA_GUARDIANO=$GUARDIANO
ATTIVA_PULIZIA=$PULIZIA
CHIEDI_SHA=$SHA
ESTRAI_ARCHIVI=$ESTRAI
SMISTA_ESTENSIONE=$SMISTA
# Tetto (MB) alla dimensione decompressa degli archivi estratti in automatico.
MAX_ESTRAZIONE_MB=$MAX_MB
EOF
echo "Configurazione salvata in $CONF"

# Applica subito lo stato ai servizi, se le unit sono installate; il guardiano
# legge il conf all'avvio, quindi per fargli vedere le modifiche va riavviato.
if [ -f "$UNIT_DIR/musiguard-guardiano.service" ]; then
    if [ "$GUARDIANO" = 1 ]; then
        systemctl --user enable musiguard-guardiano.service >/dev/null 2>&1
        systemctl --user restart musiguard-guardiano.service
        echo "Guardiano: attivo (riavviato con la nuova configurazione)."
    else
        systemctl --user disable --now musiguard-guardiano.service 2>/dev/null
        echo "Guardiano: disattivato."
    fi
    if [ "$PULIZIA" = 1 ]; then
        systemctl --user enable --now musiguard-pulizia.timer >/dev/null 2>&1
        echo "Pulizia giornaliera: attiva."
    else
        systemctl --user disable --now musiguard-pulizia.timer 2>/dev/null
        echo "Pulizia giornaliera: disattivata."
    fi
else
    echo "Unit systemd non ancora installate: lancia ./installa-servizio.sh"
fi
