#!/bin/bash
# set -u: variabile non definita = errore fatale, non stringa vuota silenziosa.
set -u

DIR_PRE="${HOME}/PreDownload"
DIR_DOWN="${HOME}/Downloads"

# ---> MODIFICA QUESTI DUE PERCORSI <---
SCRIPT_AV="${HOME}/MusiGuard/AntiVirusDIY.sh"
LOG_ESTRAZIONI="${HOME}/MusiGuard/estrazioni.log"

# Moduli e parametri da ~/.config/musiguard.conf (generato da configura.sh).
# Il conf viene LETTO, mai eseguito: si accettano solo righe CHIAVE=numero.
# Il file viene letto una volta all'avvio: dopo una riconfigurazione il
# servizio va riavviato (configura.sh lo fa da solo).
CONF="${HOME}/.config/musiguard.conf"
leggi_conf() {
    local V=""
    [ -f "$CONF" ] && V=$(grep -E "^$1=[0-9]+$" "$CONF" | tail -n1 | cut -d= -f2)
    echo "${V:-$2}"
}
# ESTRAI_ARCHIVI=0 lascia gli archivi compressi dove vengono smistati;
# SMISTA_CATEGORIE=0 manda tutto in ~/Downloads senza dividere per tipo.
ESTRAI_ARCHIVI=$(leggi_conf ESTRAI_ARCHIVI 1)
SMISTA_CATEGORIE=$(leggi_conf SMISTA_CATEGORIE 1)
# Anti zip-bomb / disco pieno: tetto (in MB) alla dimensione DECOMPRESSA
# di un archivio estratto in automatico. Oltre questa soglia l'estrazione
# viene rifiutata (zip/7z, che dichiarano il totale) o uccisa da ulimit
# (formati che non lo dichiarano). L'archivio resta comunque sul disco.
MAX_ESTRAZIONE_MB=$(leggi_conf MAX_ESTRAZIONE_MB 10240)

# FIX: lock anti-doppia-istanza. Col servizio systemd attivo, un guardiano
# lanciato a mano (o un secondo avvio da cron/autostart dimenticato)
# processerebbe gli stessi file in gara con quello del servizio. flock -n
# non aspetta: la seconda istanza esce subito. Il fd 9 resta aperto per
# tutta la vita dello script e il lock si rilascia da solo all'uscita.
LOCKFILE="${HOME}/MusiGuard/.guardiano.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "Guardiano già in esecuzione (lock: $LOCKFILE), esco." >&2
    exit 0
fi

# FIX: se lo script antivirus manca, prima ogni file veniva marcato "sospetto"
# con un messaggio incomprensibile. Meglio fallire subito e chiaramente.
if [ ! -x "$SCRIPT_AV" ]; then
    zenity --error --text="Script antivirus non trovato o non eseguibile:\n$SCRIPT_AV" 2>/dev/null
    echo "Errore: $SCRIPT_AV non trovato o non eseguibile (chmod +x?)" >&2
    exit 1
fi

# Smistamento: ogni tipo di file va in una sottocartella "Downloads" DENTRO
# la cartella utente corrispondente (Documents/Downloads, Pictures/Downloads,
# ecc.), così i file scaricati restano separati dai tuoi file personali.
# I percorsi base vengono da xdg-user-dir (percorso reale del sistema).
DIR_DOCS="$(xdg-user-dir DOCUMENTS 2>/dev/null || echo "${HOME}/Documents")/Downloads"
DIR_IMG="$(xdg-user-dir PICTURES 2>/dev/null || echo "${HOME}/Pictures")/Downloads"
DIR_VID="$(xdg-user-dir VIDEOS 2>/dev/null || echo "${HOME}/Videos")/Downloads"
DIR_MUS="$(xdg-user-dir MUSIC 2>/dev/null || echo "${HOME}/Music")/Downloads"
DIR_ARCH="${HOME}/Documents/Archivi"
DIR_3D="$(xdg-user-dir DOCUMENTS 2>/dev/null || echo "${HOME}/Documents")/3d Print/Downloaded"

# FIX: aggiunta DIR_PRE — se non esiste, inotifywait termina subito con errore.
mkdir -p "$DIR_PRE" "$DIR_DOWN" "$DIR_DOCS" "$DIR_IMG" "$DIR_VID" "$DIR_MUS" "$DIR_ARCH" "$DIR_3D"

# FIX: --text dei dialog zenity è markup Pango: & < > nudi (nell'output
# dell'antivirus o in un nome file) fanno fallire il dialog in silenzio.
# Da usare su OGNI stringa non nostra che finisce in un --text.
escape_markup() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<< "$1"
}

# Notifica "file a posto": cliccando sul corpo della notifica apre la
# cartella di destinazione col file manager. Usa notify-send (libnotify)
# perché zenity --notification non gestisce i click. La chiave azione
# "default" è la convenzione libnotify per l'attivazione con UN click sul
# corpo (niente pulsante da espandere). L'hint transient (-h int:transient:1)
# impedisce a GNOME di lasciare una copia nel centro notifiche: resta solo il
# banner, così non compaiono due notifiche. -t 5000 = durata banner 5s.
# notify-send resta in attesa e stampa la chiave premuta; per questo va
# chiamata in background (vedi "&" sotto), così non blocca i file successivi.
notifica_ok() {
    local NOME="$1" CARTELLA="$2"
    if command -v notify-send &>/dev/null; then
        local AZIONE
        AZIONE=$(notify-send --app-name="MusiGuard" --icon=folder-download \
            -h int:transient:1 -t 5000 \
            -A "default=Apri cartella" \
            "✅ $NOME è sicuro" \
            "Ordinato in: ${CARTELLA#"$HOME"/}" 2>/dev/null)
        [ "$AZIONE" = "default" ] && xdg-open "$CARTELLA" &>/dev/null
    else
        # Fallback se libnotify manca: notifica passiva, senza click.
        zenity --notification --text="✅ $NOME è sicuro.\n📂 ${CARTELLA#"$HOME"/}" 2>/dev/null
    fi
}

# --- NUOVO: FUNZIONE DI ESTRAZIONE IN BACKGROUND ---
estrai_archivio() {
    local FILE_PATH="$1"
    local DIR_DEST NOME
    DIR_DEST="$(dirname "$FILE_PATH")"
    NOME="$(basename "$FILE_PATH")"

    (
        # Chiude il fd del lock ereditato: un'estrazione lunga non deve
        # trattenere il lock (bloccherebbe il riavvio del servizio se il
        # processo principale muore mentre questa subshell lavora).
        exec 9>&-
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🟢 Inizio estrazione: $NOME" >> "$LOG_ESTRAZIONI"
        
        # Genera il nome della cartella di destinazione rimuovendo le estensioni note
        local NOME_CART="$NOME"
        NOME_CART="${NOME_CART%.tar.gz}"
        NOME_CART="${NOME_CART%.tar.bz2}"
        NOME_CART="${NOME_CART%.tar.xz}"
        NOME_CART="${NOME_CART%.tar.zst}"
        NOME_CART="${NOME_CART%.tgz}"
        NOME_CART="${NOME_CART%.gz}"
        NOME_CART="${NOME_CART%.bz2}"
        NOME_CART="${NOME_CART%.xz}"
        NOME_CART="${NOME_CART%.zst}"
        NOME_CART="${NOME_CART%.tar}"
        NOME_CART="${NOME_CART%.zip}"
        NOME_CART="${NOME_CART%.rar}"
        NOME_CART="${NOME_CART%.7z}"

        # FIX anti zip-bomb: zip e 7z dichiarano nell'indice il totale
        # decompresso: se supera MAX_ESTRAZIONE_MB rifiutiamo PRIMA di
        # toccare il disco (l'archivio resta dov'è). NB: il totale dichiarato
        # può mentire (bombe annidate): per questo sotto c'è anche ulimit.
        local MAX_BYTE=$((MAX_ESTRAZIONE_MB * 1024 * 1024))
        local DIM_DICHIARATA=""
        case "$NOME" in
            *.tar.*|*.tar|*.tgz) : ;;  # il totale non è nell'indice: copre ulimit
            *.zip) DIM_DICHIARATA=$(unzip -l "$FILE_PATH" 2>/dev/null | tail -n1 | awk '{print $1}') ;;
            *.7z)  DIM_DICHIARATA=$(7z l "$FILE_PATH" 2>/dev/null | tail -n1 | awk '{print $3}') ;;
        esac
        if [[ "$DIM_DICHIARATA" =~ ^[0-9]+$ ]] && [ "$DIM_DICHIARATA" -gt "$MAX_BYTE" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⛔ RIFIUTATO: $NOME dichiara $DIM_DICHIARATA byte decompressi (limite ${MAX_ESTRAZIONE_MB}MB). Archivio conservato, non estratto." >> "$LOG_ESTRAZIONI"
            if command -v notify-send &>/dev/null; then
                notify-send --app-name="MusiGuard" --icon=dialog-error --urgency=critical "⛔ Estrazione rifiutata" "$NOME supera il limite di ${MAX_ESTRAZIONE_MB}MB decompressi. Estrailo a mano se ti fidi." 2>/dev/null
            fi
            exit 0
        fi

        # FIX: stessa logica anti-collisione dello smistamento, ma sulla
        # CARTELLA di estrazione. Prima era gestita solo la collisione sul
        # file archivio: scaricando files.zip due volte, il primo zip veniva
        # cancellato dopo l'estrazione, quindi il secondo non collideva come
        # file — ma "unzip -o" nella cartella files/ già esistente ne
        # sovrascriveva il contenuto senza avvisare. Ora finisce in "files (1)/".
        # FIX: mkdir SENZA -p come test-and-create atomico: il vecchio
        # "[ -e ] poi mkdir -p" aveva una finestra (TOCTOU) in cui due
        # estrazioni omonime in parallelo sceglievano la stessa cartella.
        # Se mkdir fallisce il nome è occupato: si incrementa e si riprova.
        # La cartella creata qui è quindi GARANTITA fresca e nostra: sotto
        # possiamo farci rm -rf senza rischiare roba dell'utente.
        local PATH_DEST_ESTRAZIONE="$DIR_DEST/$NOME_CART"
        if ! mkdir "$PATH_DEST_ESTRAZIONE" 2>/dev/null; then
            local N=1
            # Cap a 999: se mkdir fallisce per un motivo diverso dalla
            # collisione (permessi, disco) non vogliamo un loop infinito.
            while [ "$N" -le 999 ] && ! mkdir "$DIR_DEST/$NOME_CART ($N)" 2>/dev/null; do N=$((N+1)); done
            if [ "$N" -gt 999 ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERRORE: impossibile creare la cartella di estrazione per $NOME in $DIR_DEST" >> "$LOG_ESTRAZIONI"
                if command -v notify-send &>/dev/null; then
                    notify-send --app-name="MusiGuard" --icon=dialog-error --urgency=critical "❌ Errore Estrazione" "Impossibile creare la cartella per $NOME. Leggi estrazioni.log." 2>/dev/null
                fi
                exit 0
            fi
            NOME_CART="$NOME_CART ($N)"
            PATH_DEST_ESTRAZIONE="$DIR_DEST/$NOME_CART"
        fi
        local SUCCESSO=1

        # FIX anti zip-bomb, seconda linea: ulimit -f limita la dimensione di
        # OGNI file scritto da questa subshell e dai suoi figli (per bash il
        # valore è in blocchi da 1KiB). Copre i formati che non dichiarano il
        # totale (tar.*, rar, compressi singoli) e le bombe che mentono
        # sull'indice: l'estrattore muore (SIGXFSZ) invece di riempire il
        # disco, e finisce nel normale ramo d'errore qui sotto.
        ulimit -f $((MAX_ESTRAZIONE_MB * 1024)) 2>/dev/null

        # Esegue le estrazioni puntando esplicitamente ai percorsi assoluti.
        # FIX: aggiunti i compressi SINGOLI non-tar (gz/bz2/xz/zst): prima lo
        # smistamento li mandava in Archivi ma qui cadevano in "Formato
        # ignorato" e restavano compressi. Il file decompresso va dentro la
        # cartella anti-collisione come per gli altri formati. ATTENZIONE
        # all'ordine dei pattern: *.tar.* e *.tgz DEVONO stare prima di *.gz
        # e simili, o foo.tar.gz verrebbe trattato da gunzip semplice.
        case "$NOME" in
            *.tar.*|*.tar|*.tgz) tar xf "$FILE_PATH" -C "$PATH_DEST_ESTRAZIONE" >> "$LOG_ESTRAZIONI" 2>&1 && SUCCESSO=0 ;;
            *.zip) unzip -q -o "$FILE_PATH" -d "$PATH_DEST_ESTRAZIONE" >> "$LOG_ESTRAZIONI" 2>&1 && SUCCESSO=0 ;;
            *.rar) unrar x -y -inul "$FILE_PATH" "$PATH_DEST_ESTRAZIONE/" >> "$LOG_ESTRAZIONI" 2>&1 && SUCCESSO=0 ;;
            *.7z) 7z x -y -bd -o"$PATH_DEST_ESTRAZIONE" "$FILE_PATH" >> "$LOG_ESTRAZIONI" 2>&1 && SUCCESSO=0 ;;
            *.gz)  gunzip -c "$FILE_PATH" > "$PATH_DEST_ESTRAZIONE/$NOME_CART" 2>> "$LOG_ESTRAZIONI" && SUCCESSO=0 ;;
            *.bz2) bunzip2 -c "$FILE_PATH" > "$PATH_DEST_ESTRAZIONE/$NOME_CART" 2>> "$LOG_ESTRAZIONI" && SUCCESSO=0 ;;
            *.xz)  xz -dc "$FILE_PATH" > "$PATH_DEST_ESTRAZIONE/$NOME_CART" 2>> "$LOG_ESTRAZIONI" && SUCCESSO=0 ;;
            *.zst)
                # zstd può mancare (non è nelle installazioni minime).
                if command -v zstd &>/dev/null; then
                    zstd -dc "$FILE_PATH" > "$PATH_DEST_ESTRAZIONE/$NOME_CART" 2>> "$LOG_ESTRAZIONI" && SUCCESSO=0
                else
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Formato ignorato o non supportato (zstd non installato): $NOME" >> "$LOG_ESTRAZIONI"
                    rm -rf "$PATH_DEST_ESTRAZIONE"
                    exit 0
                fi
                ;;
            *)
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Formato ignorato o non supportato: $NOME" >> "$LOG_ESTRAZIONI"
                rm -rf "$PATH_DEST_ESTRAZIONE"
                exit 0
                ;;
        esac

        # Se l'estrazione ha avuto successo, elimina il file compresso d'origine
        if [ $SUCCESSO -eq 0 ]; then
            rm -f "$FILE_PATH"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ OK: $NOME estratto in '$NOME_CART/' e rimosso." >> "$LOG_ESTRAZIONI"
            if command -v notify-send &>/dev/null; then
                notify-send --app-name="MusiGuard" --icon=folder "📦 Estrazione completata" "$NOME estratto ed eliminato." 2>/dev/null
            fi
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERRORE: Fallita estrazione di $NOME" >> "$LOG_ESTRAZIONI"
            # FIX: rm -rf al posto di rmdir. Su estrazione fallita a metà
            # rmdir (solo cartelle vuote) lasciava i file parziali E l'archivio:
            # al retry scattava il suffisso (1) e restava una cartella
            # spazzatura accanto a quella buona. La cartella è fresca e creata
            # da noi (mkdir atomico sopra), quindi rm -rf è sicuro.
            rm -rf "$PATH_DEST_ESTRAZIONE"
            if command -v notify-send &>/dev/null; then
                notify-send --app-name="MusiGuard" --icon=dialog-error --urgency=critical "❌ Errore Estrazione" "Impossibile estrarre $NOME. Leggi estrazioni.log." 2>/dev/null
            fi
        fi
    ) &
}

smista_file() {
    local FILE_DA_SMISTARE="$1"
    local NOME_FILE
    NOME_FILE=$(basename "$FILE_DA_SMISTARE")
    local ESTENSIONE=""
    # FIX: se il file non ha estensione, "${NOME##*.}" restituisce l'intero
    # nome — innocuo qui, ma meglio essere espliciti.
    if [[ "$NOME_FILE" == *.* ]]; then
        ESTENSIONE=$(tr '[:upper:]' '[:lower:]' <<< "${NOME_FILE##*.}")
    fi

    # L'archivio va riconosciuto A PRESCINDERE dallo smistamento: anche con
    # SMISTA_CATEGORIE=0 (tutto in Downloads) l'estrazione automatica, se
    # attiva, deve funzionare lo stesso.
    local E_ARCHIVIO=0
    case "$ESTENSIONE" in
        zip|rar|7z|tar|gz|bz2|xz|zst|tgz) E_ARCHIVIO=1 ;;
    esac

    local DESTINAZIONE="$DIR_DOWN"
    if [ "$SMISTA_CATEGORIE" = 1 ]; then
        case "$ESTENSIONE" in
            pdf|doc|docx|txt|odt|rtf|xls|xlsx|csv) DESTINAZIONE="$DIR_DOCS" ;;
            jpg|jpeg|png|gif|webp|svg) DESTINAZIONE="$DIR_IMG" ;;
            mp4|mkv|avi|mov) DESTINAZIONE="$DIR_VID" ;;
            mp3|wav|flac|m4a) DESTINAZIONE="$DIR_MUS" ;;
            # FIX: aggiunti tgz e bz2 — prima foo.tgz e foo.tar.bz2 finivano in
            # Downloads e non venivano mai estratti, benché l'estrattore li
            # supportasse. Lista allineata ai formati gestiti da estrai_archivio.
            zip|rar|7z|tar|gz|bz2|xz|zst|tgz) DESTINAZIONE="$DIR_ARCH" ;;
            stl|obj|3mf) DESTINAZIONE="$DIR_3D" ;;
        esac
    fi

    # FIX: mv nudo sovrascriveva silenziosamente un file omonimo già presente
    # nella destinazione. Ora, in caso di collisione, aggiunge un suffisso.
    local DEST_PATH="$DESTINAZIONE/$NOME_FILE"
    if [ -e "$DEST_PATH" ]; then
        local BASE="${NOME_FILE%.*}" EXT=""
        [[ "$NOME_FILE" == *.* ]] && EXT=".${NOME_FILE##*.}"
        local N=1
        while [ -e "$DESTINAZIONE/${BASE} ($N)$EXT" ]; do N=$((N+1)); done
        DEST_PATH="$DESTINAZIONE/${BASE} ($N)$EXT"
    fi

    if mv "$FILE_DA_SMISTARE" "$DEST_PATH"; then
        # In background (&) per non fermare il ciclo mentre la notifica
        # aspetta l'eventuale click su "Apri cartella".
        notifica_ok "$NOME_FILE" "$DESTINAZIONE" &

        # --- SE È UN ARCHIVIO (e il modulo è attivo), LO ESTRAE ---
        # Si decide sull'estensione, non sulla destinazione: così funziona
        # anche con lo smistamento per categorie disattivato.
        if [ "$ESTRAI_ARCHIVI" = 1 ] && [ "$E_ARCHIVIO" = 1 ]; then
            estrai_archivio "$DEST_PATH"
        fi
    else
        # < /dev/null: chiamata dal loop while read, non deve toccare la pipe.
        zenity --error --text="Impossibile spostare $(escape_markup "$NOME_FILE") in $(escape_markup "$DESTINAZIONE")" < /dev/null 2>/dev/null
    fi
}

# FIX: "read -r" evita che i backslash nei nomi file vengano interpretati,
# e IFS= preserva eventuali spazi iniziali/finali nel nome.
inotifywait -m -e close_write,moved_to --format "%f" "$DIR_PRE" | while IFS= read -r FILENAME
do
    if [[ "$FILENAME" == *.part || "$FILENAME" == *.crdownload || "$FILENAME" == .com.google.Chrome* ]]; then continue; fi

    FILE_PATH="$DIR_PRE/$FILENAME"
    if [ ! -f "$FILE_PATH" ]; then continue; fi

    # ANTI-CORRUZIONE: alcuni downloader scrivono il file "in place" senza
    # nome temporaneo, chiudendolo e riaprendolo più volte: close_write
    # scatterebbe a metà download e scanneresti/sposteresti un file troncato.
    # Si procede SOLO quando la dimensione resta stabile per 2 letture
    # consecutive a 2s di distanza.
    # FIX: prima il ciclo faceva max 10 giri (~20s) e poi procedeva COMUNQUE,
    # anche con la dimensione ancora in crescita — cioè proprio nel caso
    # pericoloso (download lento -> file spostato troncato). Ora la logica è
    # rovesciata: finché cresce si aspetta (fino a ~30 min); se al limite
    # cresce ancora, il file NON viene smistato e resta in PreDownload
    # (verrà riprocessato al prossimo evento close_write del downloader).
    SIZE_PREC=-1
    STABILE=0
    for _ in $(seq 1 900); do
        SIZE_ATT=$(stat -c %s "$FILE_PATH" 2>/dev/null) || break
        if [ "$SIZE_ATT" = "$SIZE_PREC" ]; then STABILE=1; break; fi
        SIZE_PREC="$SIZE_ATT"
        sleep 2
    done
    if [ ! -f "$FILE_PATH" ]; then continue; fi
    if [ "$STABILE" -ne 1 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏳ $FILENAME: dimensione ancora instabile dopo 30 min, lasciato in PreDownload." >> "$LOG_ESTRAZIONI"
        if command -v notify-send &>/dev/null; then
            notify-send --app-name="MusiGuard" --icon=dialog-warning "⏳ Download ancora in corso" "$FILENAME cresce da 30 min: lasciato in PreDownload, verrà riprocessato a download finito." 2>/dev/null
        fi
        continue
    fi

    RISULTATO_AV=$("$SCRIPT_AV" "$FILE_PATH" 2>&1)
    IS_SAFE=$?

    if [ "$IS_SAFE" -eq 0 ]; then
        smista_file "$FILE_PATH"
    else
        # FIX: --text di zenity è markup Pango: se l'output di ClamAV o il
        # nome file contiene < > &, zenity fallisce -> SCELTA vuota -> caso *)
        # (file isolato in silenzio senza mostrare nulla). Escapiamo prima.
        RISULTATO_ESC=$(escape_markup "$RISULTATO_AV")
        # FIX: < /dev/null — siamo dentro un "while read" alimentato dalla
        # pipe di inotifywait: un comando che legge stdin ruberebbe eventi
        # alla pipe. Regola difensiva per ogni dialog dentro il loop.
        SCELTA=$(zenity --list --title="⚠️ Attenzione: File Sospetto" \
            --text="<b>Problemi rilevati:</b>\n\n$RISULTATO_ESC\n\n<b>Cosa facciamo?</b>" \
            --column="ID" --column="Azione" --hide-column=1 \
            1 "🗑️ 1. Elimina" \
            2 "🛡️ 2. Lascia isolato in Pre-Download" \
            3 "⚠️ 3. Ignora rischio e Smista" \
            --width=500 --height=350 < /dev/null 2>/dev/null)
        # FIX: quirk noto di zenity --list: col DOPPIO click sulla riga il
        # valore torna duplicato con separatore pipe ("1|1"). Prima nessun
        # caso matchava -> ramo *) -> file isolato ignorando la scelta
        # esplicita dell'utente. ${SCELTA%%|*} tiene solo il primo campo.
        case "${SCELTA%%|*}" in
            1) rm -f "$FILE_PATH"; zenity --notification --text="🗑️ File $FILENAME eliminato." 2>/dev/null ;;
            2) zenity --notification --text="🛡️ File $FILENAME isolato." 2>/dev/null ;;
            3) smista_file "$FILE_PATH"; zenity --warning --text="⚠️ $(escape_markup "$FILENAME") smistato (Rischio ignorato)." < /dev/null 2>/dev/null ;;
            *) zenity --notification --text="Azione annullata. File isolato in Pre-Download." 2>/dev/null ;;
        esac
    fi
done
