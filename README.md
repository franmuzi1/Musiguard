# Musiguard
# MusiGuard 🛡️

**MusiGuard** è una pipeline di automazione avanzata per sistemi Linux (Debian/Ubuntu) scritta in Bash. Si comporta come un vero e proprio "guardiano" dei tuoi download: intercetta i file appena scaricati, li analizza alla ricerca di minacce, rimuove i metadati sensibili per proteggere la tua privacy, li smista nelle cartelle appropriate e decomprime automaticamente gli archivi.

Tutto questo avviene in modo completamente invisibile e asincrono in background, avvisandoti con comode notifiche desktop solo quando il lavoro è finito o se è richiesto un tuo intervento.

## 🚀 Caratteristiche Principali

*   🛡️ **Sicurezza Multi-Livello:**
    *   **Controllo MIME vs Estensione:** Rileva istantaneamente eseguibili nascosti (es. file malware rinominati in `.pdf` o `.jpg`).
    *   **Verifica SHA256:** Permette la validazione rapida dell'impronta del file tramite un popup interattivo con timeout (UX-friendly).
    *   **Scansione ClamAV:** Analisi anti-malware automatica. In caso di minaccia, isola il file e ti chiede come procedere.
*   🕵️‍♂️ **Privacy First (Anti-Tracking):** Utilizza `exiftool` per ripulire automaticamente i metadati (dati GPS, autore, software utilizzato) da immagini e PDF prima di archiviarli.
*   📂 **Smistamento Intelligente:** Riconosce il tipo di file e lo sposta automaticamente nella directory corretta (Documenti, Immagini, Video, Musica, Archivi, Stampa 3D), gestendo automaticamente le collisioni di nomi identici.
*   📦 **Estrazione Automatica & Sicura:** Gli archivi (`.zip`, `.tar.gz`, `.rar`, `.7z`) vengono estratti asincronamente in sottocartelle dedicate. Se l'estrazione va a buon fine, l'archivio originale viene eliminato per risparmiare spazio.
*   ⏱️ **Anti-Corruzione File:** Attende che la dimensione del file in fase di download sia stabile prima di processarlo, evitando di scansionare o spostare file parziali o troncati.
*   🧹 **Manutenzione "Zero-Touch":** 
    *   Timer `systemd` integrato per le pulizie di routine a mezzanotte.
    *   Rotazione automatica dei log tramite `logrotate` per non saturare il disco.

## ⚙️ Il Flusso di Lavoro (Pipeline)

1. **PreDownload:** Il browser salva i file in `~/PreDownload`. Un demone in ascolto (`inotifywait`) rileva l'arrivo.
2. **Analisi:** Il file viene passato allo script `AntiVirusDIY.sh` (MIME, SHA256, ClamAV).
3. **Bonifica:** Se il file è sicuro ed è un'immagine/PDF, vengono rimossi i metadati.
4. **Smistamento:** Il file viene spostato in `~/Downloads/...` nella categoria adeguata.
5. **Post-Elaborazione:** Se è un archivio, parte l'estrazione in background.
6. **Notifica:** Un popup di sistema ti avvisa del successo (con pulsante per aprire la cartella).

## 🛠️ Prerequisiti

MusiGuard richiede alcuni pacchetti standard presenti nei repository Debian/Ubuntu:

```bash
sudo apt update
sudo apt install inotify-tools clamav zenity libnotify-bin libimage-exiftool-perl tar unzip unrar p7zip-full -y
