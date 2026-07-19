#!/bin/bash
# set -u: usare una variabile mai definita diventa un errore fatale invece di
# una stringa vuota silenziosa (è il bug che rendeva morta la sezione 1).
set -u

DIR_DOWN="${HOME}/Downloads"
# Il percorso corretto per i tuoi log dentro i dotfiles:
LOG_MANUTENZIONE="${HOME}/MusiGuard/manutenzione.log"
LOCKFILE="${HOME}/MusiGuard/.manutenzione.lock"
# FIX: "date +%-d" toglie lo zero iniziale (01 -> 1). Il doppio confronto
# "-eq 1 || -eq 01" era ridondante: per [ ] sono lo stesso numero.
GIORNO_MESE=$(date +%-d)

# FIX: se la cartella del log non esiste, "exec >>" (e il lockfile qui sotto,
# che vive nella stessa cartella) ucciderebbero lo script sul nascere.
mkdir -p "$(dirname "$LOG_MANUTENZIONE")"

# FIX: lock anti-sovrapposizione. Da cron due run possono accavallarsi (es.
# la precedente è ancora appesa su apt): senza lock lavorerebbero sugli
# stessi file. flock -n non aspetta: la seconda istanza esce subito in
# silenzio. Il fd 9 resta aperto per tutta la vita dello script, quindi il
# lock si rilascia da solo alla sua uscita (anche in caso di crash).
exec 9>"$LOCKFILE"
flock -n 9 || exit 0

# FIX: rotazione minima del log. Lo script gira da cron per sempre: senza
# rotazione il log cresce all'infinito. Sopra ~1MB lo ruotiamo in .old
# (sovrascrivendo il .old precedente): al massimo ~2MB totali su disco.
if [ -f "$LOG_MANUTENZIONE" ] && [ "$(stat -c %s "$LOG_MANUTENZIONE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv -f "$LOG_MANUTENZIONE" "${LOG_MANUTENZIONE}.old"
fi

# FIX: LOG_MANUTENZIONE era definito ma mai usato: gli echo andavano su
# stdout e da cron finivano nella mail locale o nel nulla. "exec" senza
# comando redirige stdout/stderr dell'INTERO script da qui in poi.
exec >> "$LOG_MANUTENZIONE" 2>&1

echo "=== INIZIO MANUTENZIONE AUTOMATICA: $(date) ==="

# --- 1. PULIZIA DOWNLOADS (elementi più vecchi di 7 giorni) ---
# FIX: aggiunto -maxdepth 1. Senza, find scendeva DENTRO le sottocartelle:
# cestinava prima la cartella intera, poi provava a cestinare i file al suo
# interno (già spostati) generando errori nascosti dal 2>/dev/null.
# FIX CRITICO: qui c'era $DIR_DOWNLOAD (mai definita, la variabile è
# DIR_DOWN): test sempre falso -> l'intera sezione non girava MAI.
if [ -d "$DIR_DOWN" ]; then
    if command -v trash-put &> /dev/null; then
        echo "Filtro elementi vecchi in Downloads..."
        find "$DIR_DOWN" -mindepth 1 -maxdepth 1 -mtime +7 -exec trash-put {} +
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
        # Il vecchio fallback "|| trash-empty" rilanciava proprio la versione
        # interattiva che volevamo evitare: via. < /dev/null garantisce che
        # anche un eventuale prompt imprevisto fallisca subito invece di
        # restare appeso; in caso di errore lo logghiamo e basta.
        trash-empty -f < /dev/null || echo "ERRORE: trash-empty -f fallito (versione senza -f?)" >&2
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
