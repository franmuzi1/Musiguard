#!/bin/bash
DIR_PRE="${HOME}/Pre-Download"
DIR_DOWN="${HOME}/Downloads"
SCRIPT_AV="${HOME}/MusiGuard/AntiVirusDIY.sh"

# Definisce le cartelle di destinazione
DIR_DOCS="${HOME}/Documenti/Scaricati"
DIR_IMG="${HOME}/Immagini"
DIR_VID="${HOME}/Video"
DIR_MUS="${HOME}/Musica"
DIR_ARCH="${HOME}/Downloads/Archivi"
DIR_3D="${HOME}/Documents/3d Print/Downloaded"

# Crea le cartelle se non esistono
mkdir -p "$DIR_DOWN" "$DIR_DOCS" "$DIR_IMG" "$DIR_VID" "$DIR_MUS" "$DIR_ARCH" "$DIR_3D"

# Funzione per lo smistamento intelligente
smista_file() {
    local FILE_DA_SMISTARE="$1"
    local NOME_FILE=$(basename "$FILE_DA_SMISTARE")
    local ESTENSIONE="${NOME_FILE##*.}"
    
    # Converte l'estensione in minuscolo per evitare errori (es. .STL -> .stl)
    ESTENSIONE=$(echo "$ESTENSIONE" | tr '[:upper:]' '[:lower:]')
    
    local DESTINAZIONE="$DIR_DOWN" # Destinazione di base se l'estensione non è in lista
    
    case "$ESTENSIONE" in
        pdf|doc|docx|txt|odt|rtf|xls|xlsx|csv) DESTINAZIONE="$DIR_DOCS" ;;
        jpg|jpeg|png|gif|webp|svg) DESTINAZIONE="$DIR_IMG" ;;
        mp4|mkv|avi|mov) DESTINAZIONE="$DIR_VID" ;;
        mp3|wav|flac|m4a) DESTINAZIONE="$DIR_MUS" ;;
        zip|rar|7z|tar|gz) DESTINAZIONE="$DIR_ARCH" ;;
        stl|obj|3mf) DESTINAZIONE="$DIR_3D" ;;
    esac
    
    mv "$FILE_DA_SMISTARE" "$DESTINAZIONE/"
    zenity --notification --text="✅ $NOME_FILE è sicuro.\n📂 Ordinato in: $(basename "$DESTINAZIONE")"
}

inotifywait -m -e close_write,moved_to --format "%f" "$DIR_PRE" | while read FILENAME
do
    # Ignora i file temporanei dei download in corso
    if [[ "$FILENAME" == *.part || "$FILENAME" == *.crdownload || "$FILENAME" == .com.google.Chrome* ]]; then continue; fi
    
    FILE_PATH="$DIR_PRE/$FILENAME"
    if [ ! -f "$FILE_PATH" ]; then continue; fi
    
    # Avvia la scansione Antivirus
    RISULTATO_AV=$("$SCRIPT_AV" "$FILE_PATH" 2>&1)
    IS_SAFE=$?
    
    if [ "$IS_SAFE" -eq 0 ]; then
        # Se sicuro, smista automaticamente
        smista_file "$FILE_PATH"
    else
        # Se sospetto, chiede cosa fare
        SCELTA=$(zenity --list --title="⚠️ Attenzione: File Sospetto" --text="<b>Problemi rilevati:</b>\n\n$RISULTATO_AV\n\n<b>Cosa facciamo?</b>" --column="ID" --column="Azione" --hide-column=1 1 "🗑️ 1. Elimina" 2 "🛡️ 2. Lascia isolato in Pre-Download" 3 "⚠️ 3. Ignora rischio e Smista" --width=500 --height=350)
        case $SCELTA in
            1) rm -f "$FILE_PATH"; zenity --notification --text="🗑️ File $FILENAME eliminato." ;;
            2) zenity --notification --text="🛡️ File $FILENAME isolato." ;;
            3) smista_file "$FILE_PATH"; zenity --warning --text="⚠️ $FILENAME smistato (Rischio ignorato)." ;;
            *) zenity --notification --text="Azione annullata. File isolato in Pre-Download." ;;
        esac
    fi
done
