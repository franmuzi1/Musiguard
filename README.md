# MusiGuard 🛡️

**MusiGuard** è una pipeline di automazione per sistemi Linux (Debian/Ubuntu) scritta in Bash. Si comporta come un vero e proprio "guardiano" dei tuoi download: intercetta i file appena scaricati, li analizza alla ricerca di minacce, li smista nelle cartelle appropriate e decomprime automaticamente gli archivi.

Tutto avviene in modo asincrono in background, con notifiche desktop solo quando il lavoro è finito o se serve una tua decisione.

## 🚀 Caratteristiche Principali

*   🛡️ **Sicurezza Multi-Livello:**
    *   **Controllo MIME vs Estensione:** rileva eseguibili nascosti — sia Linux (ELF/script) sia **Windows (PE)** — camuffati da `.pdf`, `.jpg`, ecc.
    *   **Verifica SHA256 dagli appunti:** se hai copiato l'hash dal sito del download, viene confrontato in automatico. Niente popup: se negli appunti non c'è un hash, non succede (e non si calcola) nulla.
    *   **Scansione ClamAV:** usa `clamdscan` (istantaneo, firme in memoria) se il demone è installato, altrimenti `clamscan`. In caso di minaccia il file viene isolato e ti viene chiesto come procedere.
    *   **Seconda opinione VirusTotal (opzionale):** lookup del **solo hash SHA256** sull'API di VirusTotal — il file non lascia mai il PC. 70+ motori antivirus dove ClamAV da solo arriva corto. Serve una chiave API gratuita in `~/.config/musiguard-vt.key`; senza chiave (o senza rete) il modulo tace e non blocca nulla.
*   📂 **Smistamento per estensione:** riconosce il tipo di file e lo sposta nella cartella giusta (Documenti, Immagini, Video, Musica, Archivi, Stampa 3D), gestendo le collisioni di nomi con suffissi `(1)`, `(2)`, … Modulo opzionale: senza, l'antivirus controlla i file e li lascia in `~/Downloads`.
*   📦 **Estrazione Automatica & Sicura:** archivi (`zip`, `tar.*`, `tgz`, `rar`, `7z`) e compressi singoli (`gz`, `bz2`, `xz`, `zst`) estratti in background in sottocartelle dedicate, con protezione **anti zip-bomb** (limite sulla dimensione decompressa, `MAX_ESTRAZIONE_MB`). A estrazione riuscita l'archivio originale viene eliminato.
*   🕵️‍♂️ **Privacy (Anti-Tracking):** rimozione automatica dei metadati traccianti (GPS, autore, software) da foto e PDF smistati, con `exiftool`. Conserva orientamento e profilo colore delle immagini; modulo opzionale, si spegne da solo se `exiftool` manca.
*   ⏱️ **Anti-Corruzione File:** attende che la dimensione del file sia stabile prima di processarlo; un download ancora in corso non viene mai spostato troncato.
*   🔒 **Robustezza:** `set -u` + shellcheck su tutti gli script, lock `flock` contro le istanze doppie, log con rotazione integrata, riavvio automatico via systemd.
*   🧹 **Manutenzione "Zero-Touch":** timer systemd giornaliero per pulizia Downloads vecchi, cestino e cache.

## ⚙️ Il Flusso di Lavoro (Pipeline)

1. **PreDownload:** il browser salva i file in `~/PreDownload` (idealmente un volume separato montato `noexec`: niente può essere eseguito dalla quarantena). Un demone in ascolto (`inotifywait`) rileva l'arrivo.
2. **Attesa stabilità:** si procede solo quando il file ha smesso di crescere.
3. **Analisi:** `AntiVirusDIY.sh` controlla MIME, SHA256 (dagli appunti), ClamAV e — se configurato — VirusTotal (solo hash).
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

Alla **prima installazione** parte il wizard di configurazione: scegli quali moduli attivare (antivirus download, pulizia giornaliera, verifica SHA, estrazione automatica, smistamento per estensione, pulizia metadati privacy). Il modulo base è l'**antivirus**: da solo non smista, si assicura solo che i file scaricati non siano pericolosi e li passa in `~/Downloads`. Per riconfigurare in qualsiasi momento:

```bash
./configura.sh
```

Poi imposta il browser per scaricare in `~/PreDownload` anziché in `~/Downloads`.

Le scelte finiscono in `~/.config/musiguard.conf` (solo righe `CHIAVE=numero`, il file viene letto e mai eseguito): `ATTIVA_GUARDIANO`, `ATTIVA_PULIZIA`, `CHIEDI_SHA`, `CONTROLLO_VT`, `ESTRAI_ARCHIVI`, `SMISTA_ESTENSIONE`, `PULISCI_METADATI`, `MAX_ESTRAZIONE_MB`. Modificabile anche a mano (dopo, riavvia il guardiano: `systemctl --user restart musiguard-guardiano`).

### Attivare VirusTotal

1. Crea un account gratuito su [virustotal.com](https://www.virustotal.com), poi menu profilo → **API key**.
2. Salva la chiave (64 caratteri esadecimali) così:

```bash
echo LA_TUA_CHIAVE > ~/.config/musiguard-vt.key
chmod 600 ~/.config/musiguard-vt.key
```

Attivo da subito, nessun riavvio necessario. Privacy e limiti: viaggia solo l'hash del file, mai il contenuto; il piano gratuito consente 4 richieste al minuto — se si scarica a raffica le richieste in eccesso vengono semplicemente saltate (resta la copertura ClamAV).

Comandi utili:

```bash
journalctl --user -u musiguard-guardiano -f     # log del guardiano in diretta
systemctl --user list-timers musiguard-pulizia.timer
cat ~/MusiGuard/estrazioni.log                  # esiti delle estrazioni
```

