#!/bin/bash
DIR_PRE="${HOME}/PreDownload"
DIR_DOWN="${HOME}/Downloads"
SCRIPT_AV="${HOME}/MusiGuard/AntiVirusDIY.sh"

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
DIR_ARCH="${DIR_DOWN}/Archivi"
DIR_3D="$(xdg-user-dir DOCUMENTS 2>/dev/null || echo "${HOME}/Documents")/3d Print/Downloaded"

# FIX: aggiunta DIR_PRE — se non esiste, inotifywait termina subito con errore.
mkdir -p "$DIR_PRE" "$DIR_DOWN" "$DIR_DOCS" "$DIR_IMG" "$DIR_VID" "$DIR_MUS" "$DIR_ARCH" "$DIR_3D"

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

    local DESTINAZIONE="$DIR_DOWN"
    case "$ESTENSIONE" in
        pdf|doc|docx|txt|odt|rtf|xls|xlsx|csv) DESTINAZIONE="$DIR_DOCS" ;;
        jpg|jpeg|png|gif|webp|svg) DESTINAZIONE="$DIR_IMG" ;;
        mp4|mkv|avi|mov) DESTINAZIONE="$DIR_VID" ;;
        mp3|wav|flac|m4a) DESTINAZIONE="$DIR_MUS" ;;
        zip|rar|7z|tar|gz|xz|zst) DESTINAZIONE="$DIR_ARCH" ;;
        stl|obj|3mf) DESTINAZIONE="$DIR_3D" ;;
    esac

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
        # "${DESTINAZIONE#"$HOME"/}" toglie il prefisso $HOME/ dal path:
        # la notifica mostra "Pictures/Downloads" invece del path assoluto
        # (col solo basename direbbe sempre "Downloads", inutile).
        zenity --notification --text="✅ $NOME_FILE è sicuro. 📂 Ordinato in: ${DESTINAZIONE#"$HOME"/}" 2>/dev/null
    else
        zenity --error --text="Impossibile spostare $NOME_FILE in $DESTINAZIONE" 2>/dev/null
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
    # Aspettiamo che la dimensione resti stabile per 2 letture consecutive
    # (max ~20s), poi procediamo.
    SIZE_PREC=-1
    for _ in $(seq 1 10); do
        SIZE_ATT=$(stat -c %s "$FILE_PATH" 2>/dev/null) || break
        [ "$SIZE_ATT" = "$SIZE_PREC" ] && break
        SIZE_PREC="$SIZE_ATT"
        sleep 2
    done
    if [ ! -f "$FILE_PATH" ]; then continue; fi

    RISULTATO_AV=$("$SCRIPT_AV" "$FILE_PATH" 2>&1)
    IS_SAFE=$?

    if [ "$IS_SAFE" -eq 0 ]; then
        smista_file "$FILE_PATH"
    else
        SCELTA=$(zenity --list --title="⚠️ Attenzione: File Sospetto" \
            --text="<b>Problemi rilevati:</b>\n\n$RISULTATO_AV\n\n<b>Cosa facciamo?</b>" \
            --column="ID" --column="Azione" --hide-column=1 \
            1 "🗑️ 1. Elimina" \
            2 "🛡️ 2. Lascia isolato in Pre-Download" \
            3 "⚠️ 3. Ignora rischio e Smista" \
            --width=500 --height=350 2>/dev/null)
        case $SCELTA in
            1) rm -f "$FILE_PATH"; zenity --notification --text="🗑️ File $FILENAME eliminato." 2>/dev/null ;;
            2) zenity --notification --text="🛡️ File $FILENAME isolato." 2>/dev/null ;;
            3) smista_file "$FILE_PATH"; zenity --warning --text="⚠️ $FILENAME smistato (Rischio ignorato)." 2>/dev/null ;;
            *) zenity --notification --text="Azione annullata. File isolato in Pre-Download." 2>/dev/null ;;
        esac
    fi
done
