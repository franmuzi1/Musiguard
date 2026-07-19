#!/bin/bash
# Setup una-tantum di privacy/sicurezza di rete. DA LANCIARE CON SUDO:
#   sudo ~/MusiGuard/imposta-privacy-rete.sh
# Cosa fa (idempotente, rilanciabile):
#   1. Firewall ufw ATTIVATO DAVVERO : nega tutto in ingresso, con
#      eccezioni per Syncthing e KDE Connect (protocolli autenticati).
#   2. DNS cifrato: systemd-resolved (INSTALLANDOLO se manca: su Debian 13
#      è un pacchetto a parte ) con DNS-over-TLS verso Quad9.
#   3. MAC randomization via NetworkManager: MAC casuale a ogni scansione
#      wifi e a ogni connessione (wifi ed ethernet).
# Il firewall sta PRIMA del DNS apposta: se la parte DNS fallisse (niente
# rete, mirror giù), il firewall resta comunque configurato. Il MAC sta
# per ULTIMO: il nuovo MAC vale dalla prossima riconnessione, e non deve
# rischiare di staccare la rete mentre apt scarica systemd-resolved.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Serve root: sudo $0" >&2
    exit 1
fi

echo "== 1/3 Firewall ufw =="
ufw default deny incoming
ufw default allow outgoing
# Syncthing: trasferimenti (22000) e scoperta locale (21027).
ufw allow 22000/tcp comment 'Syncthing'
ufw allow 22000/udp comment 'Syncthing'
ufw allow 21027/udp comment 'Syncthing discovery'
# KDE Connect (telefono): range ufficiale.
ufw allow 1714:1764/tcp comment 'KDE Connect'
ufw allow 1714:1764/udp comment 'KDE Connect'
ufw --force enable
ufw status verbose

echo
echo "== 2/3 DNS cifrato (DoT verso Quad9) =="
# La configurazione va scritta PRIMA di installare/avviare il servizio,
# così al primo avvio parte già cifrato.
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/dot-quad9.conf <<'EOF'
# DNS-over-TLS rigoroso verso Quad9 (con blocco domini malevoli).
# DNSSEC allow-downgrade: valida quando possibile senza rompere reti strane.
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net
DNSOverTLS=yes
DNSSEC=allow-downgrade
EOF
if ! command -v resolvectl &>/dev/null; then
    echo "systemd-resolved non installato: lo installo (può rimuovere resolvconf, è ok)..."
    apt-get install -y systemd-resolved
fi
systemctl enable systemd-resolved
systemctl restart systemd-resolved
# resolv.conf deve puntare allo stub di resolved (127.0.0.53), che inoltra
# tutto cifrato. NetworkManager su Debian rileva resolved attivo e gli passa
# i DNS della rete da solo (ignorati a favore dei nostri, che sono globali).
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
sleep 2
resolvectl status | grep -E 'DNS Servers|DNSOverTLS|Protocols' | head -6 || true

echo
echo "== 3/3 MAC randomization (NetworkManager) =="
# Drop-in in conf.d: non tocca NetworkManager.conf né eventuali config già
# presenti (se le stesse chiavi ci sono altrove, vince l'ultimo file letto;
# i valori qui sono comunque quelli "giusti", quindi nessun conflitto).
# random = MAC nuovo a ogni connessione. Se una rete (es. filtro MAC del
# router, wifi università) smette di funzionare, per quella singola rete:
#   nmcli connection modify "NOME_RETE" wifi.cloned-mac-address stable
if command -v nmcli &>/dev/null; then
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/30-mac-random.conf <<'EOF'
# MAC casuale nelle scansioni wifi (anti-tracciamento nei luoghi pubblici)
# e a ogni connessione, wifi ed ethernet.
[device]
wifi.scan-rand-mac-address=yes

[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
EOF
    systemctl reload NetworkManager
    echo "MAC randomization attiva (vale dalla prossima riconnessione)."
else
    echo "NetworkManager non trovato: salto la MAC randomization."
fi

echo
echo "Fatto. Verifica DNS cifrato: resolvectl query anthropic.com"
echo "e controlla sopra che compaia DNSOverTLS=yes."
echo "Verifica MAC (dopo una riconnessione): ip link show"
