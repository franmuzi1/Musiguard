#!/bin/bash

DIR_DOWNLOAD="${HOME}/Downloads"
# FIX: "date +%-d" toglie lo zero iniziale (01 -> 1). Il doppio confronto
# "-eq 1 || -eq 01" era ridondante: per [ ] sono lo stesso numero.
GIORNO_MESE=$(date +%-d)

echo "=== INIZIO MANUTENZIONE AUTOMATICA: $(date) ==="

# --- 1. PULIZIA DOWNLOADS (elementi più vecchi di 7 giorni) ---
# FIX: aggiunto -maxdepth 1. Senza, find scendeva DENTRO le sottocartelle:
# cestinava prima la cartella intera, poi provava a cestinare i file al suo
# interno (già spostati) generando errori nascosti dal 2>/dev/null.
if [ -d "$DIR_DOWNLOAD" ]; then
    if command -v trash-put &> /dev/null; then
        echo "Filtro elementi vecchi in Downloads..."
        find "$DIR_DOWNLOAD" -mindepth 1 -maxdepth 1 -mtime +7 -exec trash-put {} +
    else
        # FIX: prima, senza trash-cli installato, il passo falliva in silenzio.
        echo "AVVISO: trash-cli non installato (sudo apt install trash-cli). Salto la pulizia." >&2
    fi
fi

# --- 2. SVUOTAMENTO CESTINO (solo il 1° del mese) ---
if [ "$GIORNO_MESE" -eq 1 ]; then
    if command -v trash-empty &> /dev/null; then
        echo "Primo giorno del mese: svuotamento del Cestino..."
        # FIX: le versioni recenti di trash-empty chiedono conferma
        # interattiva: in cron resterebbe appeso. -f forza senza chiedere.
        trash-empty -f 2>/dev/null || trash-empty
    fi
fi

# --- 3. PULIZIA DI SISTEMA ---
# FIX: "sudo" in uno script automatico (cron/timer) resta bloccato in attesa
# della password e lo script muore lì. "sudo -n true" verifica se possiamo
# usare sudo SENZA password: se no, saltiamo questa sezione con un avviso
# invece di bloccarci.
if sudo -n true 2>/dev/null; then
    echo "Pulizia pacchetti e cache di sistema..."
    sudo apt-get autoclean -y
    sudo apt-get autoremove -y
    sudo journalctl --vacuum-time=2d
else
    echo "AVVISO: sudo richiede password, salto la pulizia di sistema." >&2
    echo "        Per automatizzarla: esegui questa parte da un timer di root" >&2
    echo "        oppure lancia lo script manualmente con sudo -v prima." >&2
fi

# Cache thumbnail (non serve sudo: è nella tua HOME)
find ~/.cache/thumbnails -type f -mtime +7 -delete 2>/dev/null

echo "=== MANUTENZIONE COMPLETATA: $(date) ==="
