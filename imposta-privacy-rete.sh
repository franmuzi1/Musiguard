#!/bin/bash
# Setup una-tantum di privacy/sicurezza di rete. DA LANCIARE CON SUDO:
#   sudo ~/MusiGuard/imposta-privacy-rete.sh
# Cosa fa (idempotente, rilanciabile):
#   1. DNS cifrato: systemd-resolved con DNS-over-TLS verso Quad9 — chi
#      gestisce la rete non vede più in chiaro i domini che risolvi.
#   2. Firewall ufw ATTIVATO DAVVERO (il servizio era enabled ma ufw.conf
#      diceva ENABLED=no: girava a vuoto): nega tutto in ingresso, con
#      eccezioni per Syncthing e KDE Connect (protocolli autenticati).
# NON tocca il MAC randomization: già configurato in NetworkManager.conf.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Serve root: sudo $0" >&2
    exit 1
fi

echo "== 1/2 DNS cifrato (DoT verso Quad9) =="
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/dot-quad9.conf <<'EOF'
# DNS-over-TLS rigoroso verso Quad9 (con blocco domini malevoli).
# DNSSEC allow-downgrade: valida quando possibile senza rompere reti strane.
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net
DNSOverTLS=yes
DNSSEC=allow-downgrade
EOF
systemctl enable --now systemd-resolved
# Il resolv.conf attuale è il link di resolvconf(8): si punta allo stub di
# resolved (127.0.0.53), che inoltra tutto cifrato. NetworkManager su Debian
# rileva resolved attivo e gli passa i DNS della rete da solo (che resolved
# ignora a favore dei nostri, visto che sono globali).
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
sleep 2
resolvectl status | grep -E 'DNS Servers|DNSOverTLS|Protocols' | head -6 || true

echo
echo "== 2/2 Firewall ufw =="
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
echo "Fatto. Verifica DNS cifrato: resolvectl query anthropic.com"
echo "(su ogni riga di stato deve comparire DNSOverTLS=yes)"
