#!/bin/bash
# PASSO OPZIONALE: crea il "disco elastico" di PreDownload. MusiGuard
# funziona anche senza; questo aggiunge la barriera consigliata nel README:
# un file immagine sparso (default 50GB virtuali: sul disco vero occupa solo
# lo spazio dei file davvero presenti) montato su ~/PreDownload con
# noexec/nosuid/nodev — niente può essere eseguito da lì, nemmeno per sbaglio.
# DA LANCIARE CON SUDO (servono mkfs, /etc/fstab e mount):
#   sudo ~/MusiGuard/scripts/crea-disco-predownload.sh [GB]
# Idempotente, rilanciabile: se l'immagine esiste già NON viene MAI
# riformattata (dentro possono esserci download e quarantena); si sistemano
# solo fstab e montaggio. Eventuali file già presenti in ~/PreDownload
# vengono parcheggiati e rimessi dentro al volume appena montato.
set -eu

DIM_GB="${1:-50}"
case "$DIM_GB" in
    ''|*[!0-9]*) echo "Dimensione non valida: '$DIM_GB' (serve un numero intero di GB)" >&2; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "Serve root: sudo $0" >&2
    exit 1
fi
# Sotto sudo $HOME è quello di root: immagine e cartella vanno invece
# nell'home dell'utente vero, che si risale da SUDO_USER.
if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
    echo "Lancialo con sudo dal tuo utente normale, non da root diretto." >&2
    exit 1
fi
HOME_UTENTE=$(getent passwd "$SUDO_USER" | cut -d: -f6)
IMG="$HOME_UTENTE/pre_download_disk.img"
DIR_PRE="$HOME_UTENTE/PreDownload"

echo "== 1/3 Immagine disco: $IMG =="
if [ -f "$IMG" ]; then
    echo "Esiste già ($(du -h "$IMG" | cut -f1) occupati per davvero): la riuso senza formattarla."
else
    truncate -s "${DIM_GB}G" "$IMG"
    /sbin/mkfs.ext4 -q -F "$IMG"
    chown "$SUDO_USER:" "$IMG"
    echo "Creata: ${DIM_GB}GB virtuali (elastici)."
fi

echo
echo "== 2/3 /etc/fstab =="
# Si cancella l'eventuale riga vecchia e si riscrive: rilanciare lo script
# (anche con una dimensione diversa) non produce mai righe doppie.
# nofail: se un giorno l'immagine mancasse, il boot NON si blocca.
sed -i '\|pre_download_disk\.img|d' /etc/fstab
echo "$IMG $DIR_PRE ext4 loop,rw,nofail,noexec,nosuid,nodev,data=ordered,errors=remount-ro,discard 0 2" >> /etc/fstab
systemctl daemon-reload
echo "Riga scritta (montaggio automatico a ogni avvio)."

echo
echo "== 3/3 Montaggio =="
mkdir -p "$DIR_PRE"
if findmnt -n "$DIR_PRE" >/dev/null; then
    echo "Già montato: niente da fare."
else
    # File già presenti finirebbero nascosti SOTTO il punto di mount:
    # si parcheggiano e si rimettono dentro al volume appena montato.
    PARCHEGGIO=""
    if [ -n "$(ls -A "$DIR_PRE")" ]; then
        PARCHEGGIO=$(mktemp -d "$HOME_UTENTE/.predownload-trasloco.XXXXXX")
        find "$DIR_PRE" -mindepth 1 -maxdepth 1 -exec mv -t "$PARCHEGGIO" {} +
        echo "File preesistenti parcheggiati temporaneamente."
    fi
    mount "$DIR_PRE"
    chown "$SUDO_USER:" "$DIR_PRE"
    if [ -n "$PARCHEGGIO" ]; then
        find "$PARCHEGGIO" -mindepth 1 -maxdepth 1 -exec mv -t "$DIR_PRE" {} +
        rmdir "$PARCHEGGIO"
        echo "File preesistenti rimessi dentro al volume."
    fi
fi

# Verifica finale: le opzioni del mount devono contenere noexec.
if findmnt -no OPTIONS "$DIR_PRE" | grep -q noexec; then
    echo "✅ $DIR_PRE è un volume noexec: nulla è eseguibile da lì."
else
    echo "⚠️ Montato ma SENZA noexec: controlla la riga in /etc/fstab." >&2
    exit 1
fi

# Il guardiano sorveglia PreDownload con inotify: se era già in ascolto
# guardava la vecchia cartella, ora nascosta sotto il mount — va riavviato.
# try-restart: solo se sta girando; il systemctl --user di un altro utente
# richiede il suo XDG_RUNTIME_DIR.
UID_UTENTE=$(id -u "$SUDO_USER")
if runuser -u "$SUDO_USER" -- env XDG_RUNTIME_DIR="/run/user/$UID_UTENTE" \
        systemctl --user try-restart musiguard-guardiano.service 2>/dev/null; then
    echo "Guardiano riavviato: ora sorveglia il volume noexec."
else
    echo "Se il guardiano era attivo, riavvialo: systemctl --user restart musiguard-guardiano"
fi
