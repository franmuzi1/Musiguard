# MusiGuard 🛡️

**MusiGuard** è una pipeline di automazione per sistemi Linux (Debian/Ubuntu) scritta in Bash. Si comporta come un vero e proprio "guardiano" dei tuoi download: intercetta i file appena scaricati, li analizza alla ricerca di minacce, li smista nelle cartelle appropriate e decomprime automaticamente gli archivi.

Tutto avviene in modo asincrono in background, con notifiche desktop solo quando il lavoro è finito o se serve una tua decisione.

## 🚀 Caratteristiche Principali

*   🛡️ **Sicurezza Multi-Livello:**
    *   **Controllo MIME vs Estensione:** rileva eseguibili nascosti — sia Linux (ELF/script) sia **Windows (PE)** — camuffati da `.pdf`, `.jpg`, ecc.
    *   **Verifica SHA256 dagli appunti:** se hai copiato l'hash dal sito del download, viene confrontato in automatico. Niente popup: se negli appunti non c'è un hash, non succede (e non si calcola) nulla.
    *   **Scansione ClamAV:** usa `clamdscan` (istantaneo, firme in memoria) se il demone è installato, altrimenti `clamscan`. In caso di minaccia il file viene isolato e ti viene chiesto come procedere.
*   📂 **Smistamento per estensione:** riconosce il tipo di file e lo sposta nella cartella giusta (Documenti, Immagini, Video, Musica, Archivi, Stampa 3D), gestendo le collisioni di nomi con suffissi `(1)`, `(2)`, … Modulo opzionale: senza, l'antivirus controlla i file e li lascia in `~/Downloads`.
*   📦 **Estrazione Automatica & Sicura:** archivi (`zip`, `tar.*`, `tgz`, `rar`, `7z`) e compressi singoli (`gz`, `bz2`, `xz`, `zst`) estratti in background in sottocartelle dedicate, con protezione **anti zip-bomb** (limite sulla dimensione decompressa, `MAX_ESTRAZIONE_MB`). A estrazione riuscita l'archivio originale viene eliminato.
*   ⏱️ **Anti-Corruzione File:** attende che la dimensione del file sia stabile prima di processarlo; un download ancora in corso non viene mai spostato troncato.
*   🔒 **Robustezza:** `set -u` + shellcheck su tutti gli script, lock `flock` contro le istanze doppie, log con rotazione integrata, riavvio automatico via systemd.
*   🧹 **Manutenzione "Zero-Touch":** timer systemd giornaliero per pulizia Downloads vecchi, cestino e cache.

## ⚙️ Il Flusso di Lavoro (Pipeline)

1. **PreDownload:** il browser salva i file in `~/PreDownload` (idealmente un volume separato montato `noexec`: niente può essere eseguito dalla quarantena). Un demone in ascolto (`inotifywait`) rileva l'arrivo.
2. **Attesa stabilità:** si procede solo quando il file ha smesso di crescere.
3. **Analisi:** `AntiVirusDIY.sh` controlla MIME, SHA256 (dagli appunti) e ClamAV.
4. **Smistamento:** il file sicuro viene spostato nella categoria adeguata; quello sospetto resta in quarantena finché non decidi tu.
5. **Post-Elaborazione:** se è un archivio, parte l'estrazione in background (con limiti anti-bomba).
6. **Notifica:** UNA sola notifica per file, con click per aprire la cartella dove è finito (per gli archivi: direttamente la cartella estratta).

## 🛠️ Prerequisiti

```bash
sudo apt update
sudo apt install -y inotify-tools clamav zenity libnotify-bin \
    tar unzip unrar p7zip-full wl-clipboard
# Consigliati: clamav-daemon (scansioni istantanee), zstd (archivi .zst)
sudo apt install -y clamav-daemon zstd
```

Su X11 al posto di `wl-clipboard` serve `xclip`.

## 📂 Struttura del Progetto

```
MusiGuard/
├── guardiano-download.sh          # Il demone in ascolto su ~/PreDownload
├── AntiVirusDIY.sh                # Motore di scansione (MIME, SHA256, ClamAV)
├── pulizia-automatica.sh          # Manutenzione: Downloads vecchi, cestino, cache
├── configura.sh                   # Wizard di scelta dei moduli (primo avvio e on-demand)
├── installa-servizio.sh           # Installa/aggiorna le unit systemd utente
├── musiguard-guardiano.service    # Servizio del guardiano (Restart=on-failure)
├── musiguard-pulizia.service      # Servizio oneshot della pulizia
└── musiguard-pulizia.timer        # Timer giornaliero della pulizia
```

## 🔧 Installazione e Setup

```bash
git clone https://github.com/franmuzi1/Musiguard.git ~/MusiGuard
cd ~/MusiGuard
chmod +x *.sh
./installa-servizio.sh
```

Alla **prima installazione** parte il wizard di configurazione: scegli quali moduli attivare (antivirus download, pulizia giornaliera, verifica SHA, estrazione automatica, smistamento per estensione). Il modulo base è l'**antivirus**: da solo non smista, si assicura solo che i file scaricati non siano pericolosi e li passa in `~/Downloads`. Per riconfigurare in qualsiasi momento:

```bash
./configura.sh
```

Poi imposta il browser per scaricare in `~/PreDownload` anziché in `~/Downloads`.

Le scelte finiscono in `~/.config/musiguard.conf` (solo righe `CHIAVE=numero`, il file viene letto e mai eseguito): `ATTIVA_GUARDIANO`, `ATTIVA_PULIZIA`, `CHIEDI_SHA`, `ESTRAI_ARCHIVI`, `SMISTA_ESTENSIONE`, `MAX_ESTRAZIONE_MB`. Modificabile anche a mano (dopo, riavvia il guardiano: `systemctl --user restart musiguard-guardiano`).

Comandi utili:

```bash
journalctl --user -u musiguard-guardiano -f     # log del guardiano in diretta
systemctl --user list-timers musiguard-pulizia.timer
cat ~/MusiGuard/estrazioni.log                  # esiti delle estrazioni
```

## 🗺️ Roadmap

*   🕵️‍♂️ **Privacy (Anti-Tracking):** rimozione automatica dei metadati (GPS, autore, software) da immagini e PDF con `exiftool` prima dell'archiviazione.
