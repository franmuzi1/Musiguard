#!/bin/bash

# Configurazione percorsi
DIR_DOWNLOAD="${HOME}/Downloads"
GIORNO_MESE=$(date +%d) # Estrae il giorno del mese (da 01 a 31)

echo "=== INIZIO MANUTENZIONE AUTOMATICA: $(date) ==="

# --- 1. PULIZIA DOWNLOADS (File più vecchi di 7 giorni) ---
if [ -d "$DIR_DOWNLOAD" ]; then
    echo "Filtro file vecchi in Downloads..."
    # Cerca file modificati più di 7 giorni fa e li sposta nel Cestino
    find "$DIR_DOWNLOAD" -mindepth 1 -mtime +7 -exec trash-put {} + 2>/dev/null
fi

# --- 2. SVUOTAMENTO CESTINO (Solo il 1° giorno del mese) ---
if [ "$GIORNO_MESE" -eq 1 ] || [ "$GIORNO_MESE" -eq 01 ]; then
    echo "Primo giorno del mese: Svuotamento totale del Cestino in corso..."
    trash-empty 2>/dev/null
fi

# --- 3. PULIZIA DI SISTEMA (Sicura e non dannosa) ---
echo "Pulizia pacchetti e cache di sistema..."

# Rimuove i pacchetti .deb obsoleti scaricati da apt
sudo apt-get autoclean -y

# Rimuove le dipendenze residue di programmi disinstallati
sudo apt-get autoremove -y

# Sfoltisce i log di sistema (tiene solo gli ultimi 2 giorni)
sudo journalctl --vacuum-time=2d

# Pulisce la cache dei thumbnail (anteprime immagini) più vecchie di 7 giorni
find ~/.cache/thumbnails -type f -mtime +7 -delete 2>/dev/null

echo "=== MANUTENZIONE COMPLETATA CON SUCCESSO ==="
