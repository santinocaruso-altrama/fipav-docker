# FIPAV Online — stack di sviluppo unificato

Un solo `make up` avvia tutti i progetti dell'ecosistema, raggiungibili da un unico
entrypoint HTTP sulla porta 80.

| URL | Progetto | Cos'è |
| --- | --- | --- |
| `http://localhost/` | `fipav-comter-frontend` | sito pubblico dei comitati (Next.js) |
| `http://localhost/core/` | `fipav-core` | API e backend (Laravel) |
| `http://localhost/core/api/documentation` | `fipav-core` | Swagger UI |
| `http://localhost/backoffice/` | `fipav-backoffice` | backoffice (Vite + React) |
| `http://localhost:8025` | mailpit | mail catturate in sviluppo |
| `http://localhost:7700` | meilisearch | motore di ricerca |

Il sito è multi-tenant per sottodominio: `http://calabria.localhost/` serve il comitato
`calabria`. Funziona con qualsiasi `*.localhost` senza toccare `/etc/hosts`.

## Prerequisiti

Docker Desktop, e i tre progetti come *sibling* di questa cartella:

```
fipavonline/
  fipav-docker/            <- si lancia da qui
  fipav-core/
  fipav-backoffice/
  fipav-comter-frontend/
```

Il `docker-compose.yml` li referenzia con percorsi relativi (`../fipav-core/src`), quindi
i comandi vanno dati **da questa directory** e il layout non è negoziabile.

## Avvio (sviluppo locale)

**Solo la prima volta:**

```sh
cp .env.example .env.dev
```

Il default va bene così com'è: nessun dato da generare per lo sviluppo locale (a
differenza dello staging, vedi più sotto). Poi:

```sh
make install             # build immagini, avvio, composer install, migrazioni, storage:link
```

Nell'uso quotidiano, da quel momento in poi:

```sh
make up                  # avvia (alias di `make up-dev`)
make down                # ferma (alias di `make down-dev`)
make                     # elenca tutti i comandi
```

### Il primo avvio risponde 502, ed è normale

I `node_modules` dei due frontend non sono quelli del Mac (vedi
[Dipendenze dei frontend](#dipendenze-dei-frontend)): vengono installati **al primo avvio**
dentro il container. Per qualche minuto `http://localhost/` e `http://localhost/backoffice/`
rispondono 502, perché il dev server non è ancora in ascolto.

```sh
make logs-fe             # segue l'avanzamento dell'install dei due frontend
```

`depends_on` non aiuta in questo caso: il container risulta già "up" mentre installa.

## Verifica

```sh
make verify
```

Esegue i criteri di accettazione della spec: che i tre path rispondano, che gli asset di
Swagger escano col prefisso `/core/` (è la prova che l'override di `SCRIPT_NAME` funziona),
che il multi-tenant per sottodominio risponda e che il database sia quello preesistente e
non un volume ricreato vuoto.

L'HMR è l'unico criterio che resta manuale: modifica un file in
`../fipav-backoffice/src` e controlla che il browser si aggiorni senza reload.

## Comandi

`make` senza argomenti stampa l'elenco completo. I gruppi:

| | |
| --- | --- |
| **primo avvio** | `install` |
| **ciclo di vita (dev)** | `up`/`up-dev` `down`/`down-dev` `build` `rebuild` `restart` `ps` |
| **ciclo di vita (staging)** | `up-stage` `down-stage` `sync-sites` |
| **log** | `logs` `logs-gateway` `logs-php` `logs-horizon` `logs-backoffice` `logs-comter` `logs-fe` |
| **aggiornamento** | `pull` `update` |
| **verifica / diagnostica** | `verify` `diagnose` |
| **shell** | `shell` `sh-backoffice` `sh-comter` |
| **core / Laravel** | `artisan` `composer` `tinker` `migrate` `migrate-status` `migrate-fresh` `seed` `fresh` `test` `test-filter` `swagger` `routes` `cache-clear` |
| **database** | `mariadb` `redis-cli` `db-dump` `db-restore` `backup-db` `rotate-db-password` |
| **dipendenze frontend** | `fe-reset` |

Con parametri:

```sh
make artisan cmd="route:list --path=cms"
make composer cmd="require league/csv"
make test-filter f="BreadcrumbTest"
make db-backups file=backup.sql
```

### Aggiornare il codice

`git pull` da solo non basta: i tre progetti sono **repo git distinti, su branch distinti**,
e dopo il pull il sorgente è sì visibile subito (è bind-mountato) ma `composer.json`, le
migrazioni e i lockfile dei frontend richiedono ciascuno un passo in più.

```sh
make update    # pull sui tre repo + composer install + migrate + riavvio frontend
make pull      # solo i tre git pull, senza toccare i container
```

`pull` salta i repo con working tree sporco invece di tentare il merge, e usa `--ff-only`:
se un branch è divergente lo segnala e si fa da parte.

Nessuno dei due ricostruisce le immagini Docker: se `docker/php/dev/Dockerfile` (o l'equivalente
di staging) è cambiato serve `make build`. Al momento serve a chi aggiorna da prima del supporto
WebP/AVIF in GD — vedi [Immagini: WebP e AVIF](#immagini-webp-e-avif).

## Come è fatto

```
host :80 / :443  (Host qualsiasi in locale; in staging gli hostname dei comitati)
    |
gateway (Caddy)
    |-- /            --> proxy   comter:3000        (Host inalterato, WebSocket per HMR)
    |-- /core/live/  --> file    public/live/*.json (statico, PHP fuori dal percorso)
    |-- /core/       --> fastcgi php:9000           (SCRIPT_NAME=/core/index.php)
    |-- /backoffice/ --> proxy   backoffice:3000    (path invariato, WebSocket per HMR)

rete fipav-network:  mariadb :3307   redis :6379   mailpit :8025   meilisearch :7700
```

I due frontend **non espongono porte sull'host**: si raggiungono solo dal gateway. Così non
esistono due URL validi per la stessa app, e la `:3000` resta libera per un `npm run dev`
sul Mac in parallelo ai container.

### Perché `/core` non è un `proxy_pass`

Montare Laravel sotto un prefisso di path non si fa con un proxy. Il gateway monta
`../fipav-core/src` e parla direttamente a `php:9000`, sovrascrivendo due variabili FastCGI:
`SCRIPT_NAME=/core/index.php` e `REQUEST_URI` riportato all'URI originale (`handle_path` in
Caddy spoglia il prefisso, e senza ripristinarlo Symfony calcolerebbe `pathInfo` su un URI
privo di `/core`).

Da `SCRIPT_NAME` Symfony ricava `baseUrl=/core` e `pathInfo=/api/v1/...`: le route continuano
a fare match sui path senza prefisso, e contemporaneamente `url()`, `route()`, `asset()`,
Swagger e `Storage::url()` generano già URL con `/core` davanti. Nessuna modifica al codice PHP.

Un `proxy_pass` con strip del prefisso avrebbe richiesto `X-Forwarded-Prefix`, quindi
modifiche a `fipav-core`, e non tutti i punti di Laravel rispettano quell'header.

### Le immagini e `ASSET_URL`

`comter` chiama l'API **server-side** (`API_BASE_URL`, di default il servizio `gateway` in
locale, il dominio nudo in HTTPS in staging — vedi *Aggiungere un comitato* più sotto). Le
risposte finiscono nell'HTML servito al browser, quindi ogni URL costruito sul root della
request userebbe quello stesso hostname interno: uno che il browser non risolve.

`CORE_ASSET_URL=/core` risolve il problema alla radice — è un **percorso**, non un URL, quindi
le immagini escono come `/core/images/discipline/pallavolo.jpg`: relative alla root, senza
hostname, identiche in locale, staging e produzione.

Richiede la chiave `asset_url` in `fipav-core/src/config/app.php` e che i controller usino
`asset()` e non `url()`. Lasciata vuota, `asset()` ricade sul root della request, cioè il
comportamento storico di chi lancia `fipav-core` da solo.

### Live score: snapshot statici, non SSE né WebSocket

#### Il problema

Il live score pubblico di comter ha numeri che rendono sbagliata la soluzione istintiva:

- fino a **10.000 spettatori contemporanei su un singolo comitato**;
- **90 comitati**, non tutti in gioco insieme;
- il punteggio cambia **ogni 1-2 minuti**, non a ogni azione.

Il dato è **pubblico e identico per tutti** gli spettatori dello stesso comitato: nessuna
autenticazione, nessuna personalizzazione, nessuna bidirezionalità. È questa combinazione —
tanti lettori, stesso contenuto, bassa frequenza — a decidere l'architettura.

#### La soluzione adottata

Un file JSON per comitato, rigenerato **a evento** e servito dal `file_server` di Caddy. Il
frontend fa polling ogni 30 s.

```
evento (i risultati cambiano)
    |
    v
App\Services\LiveScoreSnapshot::write($slug)      <- PHP: 1 invocazione per aggiornamento
    |  scrittura atomica (temp + rename)
    v
fipav-core/src/public/live/<slug>.json
    |
    v
Caddy  handle /live/*  ->  file_server            <- PHP fuori dal percorso della richiesta
    |
    v
10.000 browser, polling 30s (src/hooks/useLiveScore.ts)
```

I 30 s di ritardo massimo sono irrilevanti su un ciclo di aggiornamento da 60-120 s. In cambio
spariscono le connessioni persistenti, il container di broadcast, e l'autorizzazione per tenant
dei canali — che qui non servirebbe comunque, perché il dato è pubblico.

#### Il vantaggio sui grandi numeri

La proprietà che conta è una sola: **il costo su PHP non dipende da quanti stanno guardando.**

> È `O(aggiornamenti)`, non `O(spettatori × aggiornamenti)`.

Un spettatore o diecimila, PHP viene invocato lo stesso numero di volte: una per evento. Tutto
il traffico dei lettori si ferma su `file_server`, che fa decine di migliaia di richieste al
secondo per core. Aggiungere un comitato che gioca costa **un file in più**, non capacità in più.

Confronto a 10.000 spettatori su un comitato:

| Approccio | Cosa resta aperto | Carico su php-fpm | Dove cede |
| --- | --- | --- | --- |
| Endpoint dinamico + polling | niente | ~330 req/s | php-fpm ne regge ~100 → **collassa tutto il backend** |
| SSE in php-fpm (*c'era*) | 1 connessione **e 1 worker** per spettatore | 10.000 worker | **a 5 spettatori** |
| WebSocket (Reverb) | 1 connessione per spettatore | ~0 | container nuovo, Redis pub/sub, ~5-10k conn per processo |
| **File statico + polling** *(adottato)* | niente | **1 invocazione per evento** | la banda, non la CPU |

Numeri misurati sullo snapshot reale (5.131 byte, **656 compressi** con `encode`):

| | a 10.000 spettatori |
| --- | --- |
| richieste/s verso il gateway | ~333 |
| di cui che toccano PHP | **0** |
| invocazioni PHP | 1 per comitato, per aggiornamento |
| traffico fra un aggiornamento e l'altro (solo 304) | ~66 KB/s |
| picco quando il file cambia | 6,5 MB su 30 s ≈ **1,7 Mbit/s** |

Su più comitati in contemporanea la differenza si allarga: tre comitati da 10.000 spettatori
sono ~1.000 req/s su un file server statico (nulla) e 3 invocazioni PHP per evento. Con i
WebSocket sarebbero **30.000 connessioni persistenti**, oltre la capacità di un singolo processo
Reverb, quindi scaling orizzontale e bilanciamento.

Il limite vero è la **banda al momento dell'aggiornamento**, non la CPU: quando il file cambia,
tutti gli spettatori ne scaricano il corpo intero entro la finestra di polling. Per questo la
direttiva `encode` nel Caddyfile e un payload piccolo contano più di qualunque altro tuning.

#### Cosa è stato rimosso

Qui prima c'era uno stream SSE — `while (true) { … sleep(5); }` dentro php-fpm, con un route
handler Next che lo riproxava verso il browser. Teneva occupato un worker per ogni spettatore
su un pool che ne ha 5 (`pm.max_children` di default nell'immagine ufficiale, che questo repo
non sovrascrive): **cinque visitatori sulla home bastavano a rendere irraggiungibile tutto il
backend**, backoffice e API comprese. E spingeva ogni 5 secondi un dato che cambia ogni 1-2
minuti, 24 volte il traffico necessario.

#### Il confine

Questo impianto regge finché il dato è **pubblico, uguale per tutti e a bassa frequenza**. Se
servisse il punto-a-punto in tempo reale, o contenuti diversi per utente autenticato, non si
estende e andrebbe rivalutato un broadcast vero (Laravel Reverb + Redis). Costruirlo oggi
significherebbe pagarne la complessità senza usarne nessuna proprietà.

#### Operatività

**Generare gli snapshot:**

```sh
docker compose exec php php artisan livescore:snapshot calabria   # un comitato
docker compose exec php php artisan livescore:snapshot --all      # tutti i tenant attivi
```

`public/live/` è nel `.gitignore` di `fipav-core`: sono artefatti rigenerabili, come
`public/build`. Su una macchina nuova la directory è vuota finché non parte il primo evento o
non si lancia il comando.

**Se lo snapshot non esiste**, il gateway risponde `[]` con 200 e il frontend mostra "nessuna
partita". Il blocco `handle /live/*` nel Caddyfile serve esattamente a questo: senza,
`php_fastcgi` ripiegherebbe su `index.php` e un comitato senza file manderebbe tutto il suo
polling dentro PHP — cioè il carico che questo impianto esiste per evitare.

Il punto da chiamare quando i risultati cambiano è uno solo:

```php
app(LiveScoreSnapshot::class)->write($tenantSlug);
```

## Cose da sapere

### Non far girare due stack insieme

I `container_name` di questo stack finiscono in `-dev` o `-stage` (`fipav-php-dev`,
`fipav-mariadb-stage`, …), diversi da quelli del compose standalone di `fipav-core`
(`fipav-php`, `fipav-mariadb`, senza suffisso), e anche i volumi dati sono ormai suffissati e
separati per ambiente (`fipav-core_mariadb-data-dev`, `-stage`, entrambi diversi dal volume
`fipav-core_mariadb-data` senza suffisso usato dal compose standalone di `fipav-core`). Non
condividono più dati: puoi avviare questo stack e quello standalone di `fipav-core` insieme
senza rischio di scritture concorrenti sullo stesso volume, e usano anche porte host diverse
(quello di `fipav-core` pubblica `3307`, `8080`, `6379`, `8025`/`1025`, `7700`).

Restano sulla stessa rete Docker (`fipav-network`, stesso nome in entrambi i compose — vedi il
warning più sotto): non è un problema di dati, solo un dettaglio da sapere se usi `docker
network inspect fipav-network` e trovi container di entrambi i progetti.

Per comandi `docker exec` diretti (non tramite `make`/`docker compose exec`) usa il nome
completo, con il suffisso dell'ambiente che hai avviato: `docker exec fipav-php-dev ...` o
`fipav-php-stage`.

Per lo stesso motivo il **`Makefile` di `fipav-core` non funziona** mentre gira questo stack:
i suoi `docker compose exec` puntano al project `fipav-core`, che è spento. I comandi
quotidiani sono replicati qui con gli stessi nomi.

### `docker compose down -v` cancella i dati di QUESTO ambiente

A differenza di prima, i volumi dati (`mariadb-data`, `meilisearch-data`, `redis-data`) non
sono più pinnati a quelli di `fipav-core`: ogni ambiente ha i propri, dichiarati con `name:`
suffissato (`fipav-core_mariadb-data-dev`/`-stage`, …). Non c'è più un DB `camp2013` reale
condiviso da riusare: **al primo avvio di ciascun ambiente il DB parte vuoto**, migrazioni
comprese (vedi `make install`). Per popolarlo con un dump reale c'è `make db-restore
file=...`; per gli upload reali (`storage/app/public`) c'è `scripts/sync-storage.sh` (vedi più
sotto).

`down --volumes` cancellerebbe questi volumi. Nessun target del `Makefile` passa quel flag,
ed è meglio non aggiungerlo. Per ripulire solo le dipendenze dei frontend c'è `make fe-reset`.

### Il warning sulla rete è atteso: non "sistemarlo"

A ogni avvio Docker Compose stampa:

```
WARN a network with name fipav-network exists but was not created for project "fipavonline".
     Set `external: true` to use an existing network
```

Perché: `fipav-network` è dichiarata con lo stesso nome sia qui (`name: fipav-network` in
`docker-compose.yml`) sia nel compose standalone di `fipav-core`, e quest'ultimo di solito la
crea per primo — Docker segnala che il nome non è stato creato per questo project, ma la
riusa comunque. **Il rimedio suggerito da Docker (`external: true`) romperebbe il deploy su
una macchina nuova**, dove la rete non esiste ancora: `external: true` fallisce con `network
"..." not found` se manca, mentre solo `name:` (com'è ora) la crea se manca e la riusa se
c'è. Verificato in entrambi i casi. Il warning è il prezzo di questa scelta, e va lasciato
stare.

### Dipendenze dei frontend

I `node_modules` sul Mac contengono binari compilati per darwin-arm64 (`esbuild`, `next-swc`,
`@tailwindcss/oxide`, `sharp`): in un container linux sono inutilizzabili. Quindi si
bind-mounta il solo sorgente, e un volume named montato su `node_modules` maschera la cartella
dell'host. L'entrypoint installa le dipendenze quando il volume è vuoto o il lockfile è
cambiato — `npm ci` per il backoffice, `bun install --frozen-lockfile` per comter.

Conseguenza voluta: `npm run dev` sul Mac e i container coesistono senza toccarsi.

Se le dipendenze nel volume si corrompono:

```sh
make fe-reset    # butta i due volumi node_modules e reinstalla da zero
```

### La porta 80 è occupata

`docker compose up` fallisce con `bind: address already in use` (tipicamente un Apache o un
nginx locale). Cambia porta nel `.env.dev`:

```sh
GATEWAY_PORT=8000
```

Gli URL diventano `http://localhost:8000/…`. Il `Makefile` legge il `.env.dev`, quindi `make up`
e `make verify` si adeguano da soli.

## Configurazione

Due file, non uno: `.env.dev` per `make up-dev`, `.env.stage` per `make up-stage` (entrambi
copia di `.env.example`, non versionati) — così i valori di un ambiente non sporcano l'altro.
Le variabili passano ai container come variabili d'ambiente reali, che **vincono sui file
`.env` dei singoli progetti** — sia in Laravel (Dotenv non sovrascrive quanto è già in
ambiente) sia in Vite sia in Next. Per questo i `.env` dei tre progetti non vanno modificati:
il workflow locale fuori da Docker resta identico a prima.

| Variabile | Default | A cosa serve |
| --- | --- | --- |
| `GATEWAY_PORT` | `80` | porta dell'unico entrypoint HTTP |
| `CORE_APP_URL` | `http://localhost/core` | URL generati da CLI (queue, mail, artisan) |
| `CORE_ASSET_URL` | `/core` | prefisso delle immagini emesse da `asset()` |
| `XDEBUG_MODE` | `debug` | `off` recupera parecchi ms per richiesta |
| `BACKOFFICE_API_BASE_URL` | `http://localhost/core` | letto dal browser: same-origin, nessun CORS |
| `COMTER_API_BASE_URL` | per ambiente (vedi sopra) | chiamate server-side di apiFetch(), tenant nell'header x-tenant |
| `COMTER_ROOT_DOMAIN` | `localhost` | root domain da cui si ricava il tenant dal sottodominio; anche il dominio con cui `sync-sites` costruisce gli hostname dei comitati in staging |
| `HTTPS_PORT` | `443` | porta TLS, inutilizzata in locale |
| `ACME_CA` | directory di produzione | metti quella di staging per provare senza consumare i rate limit |

Per puntare a un dominio reale basta `COMTER_ROOT_DOMAIN=fipav.altrama.it`: il gateway è
host-agnostico e propaga `Host` inalterato, quindi `src/proxy.ts` di comter funziona senza
modifiche al codice.

## Immagini: WebP e AVIF

GD nel container php è compilato con `--with-webp` e `--with-avif`, quindi `imagewebp()`,
`imageavif()` e le rispettive `imagecreatefrom*()` sono disponibili. Serve a generare derivate
leggere dei media, non a cambiare come vengono serviti.

Il motivo, misurato su un'immagine reale dello storage (`comitato/17081/images/900/news-2.jpg`):

| | dimensioni | peso | guadagno | tempo |
| --- | --- | --- | --- | --- |
| JPEG originale | 2740×1823 | 6,35 MB | — | — |
| → WebP, larghezza 1200, q82 | 1200×798 | 0,31 MB | **20×** | 111 ms |
| → AVIF, larghezza 1200, q50 | 1200×798 | 0,18 MB | **36×** | 140 ms |

Contesto: `storage/app/public` pesa **5,8 GB** con **1325 file oltre 500 KB**, e non esistono
derivate — l'editor di crop sostituisce il file originale allo stesso path
(`CmsMediaController.php`), quindi ogni asset ha una sola versione, a dimensione piena.

Attenzione: questo è solo il **prerequisito**. Finché `fipav-core` non genera le derivate
(nessuna libreria immagini in `composer.json`), il browser continua a scaricare i JPEG originali.
Il passo successivo è un endpoint di trasformazione con cache su disco, e a monte un limite di
dimensione all'upload — altrimenti i 5,8 GB continuano a crescere. Sono modifiche applicative,
fuori dallo scope di questo repo.

I 100-140 ms per conversione valgono solo alla prima generazione: con la cache su disco le
richieste successive servono il file già pronto, senza toccare PHP.

## Staging con HTTPS

Il gateway è Caddy, che gestisce i certificati da sé. Non c'è nessun certbot, nessun rinnovo da
ricordare, nessun record DNS da inserire a ogni scadenza.

**Una volta sola**, sulla macchina:

1. **DNS**: un record `A` wildcard `*.fipav.altrama.it` verso l'IP. È quello che rende superfluo
   tornare sul DNS per ogni comitato nuovo — ed è un record DNS banale, niente a che vedere con
   un *certificato* wildcard.
2. **Firewall**: porte 80 e 443 aperte. Servono entrambe: la 443 per il traffico, la 80 per la
   validazione ACME e per redirigere chi digita l'URL senza schema. Su GCP
   `gcloud compute instances add-tags <VM> --zone <ZONA> --tags http-server,https-server`,
   e controlla anche `ufw status` sulla macchina.
3. **I quattro repo come sibling**, perché il compose li referenzia con path relativi:

   ```
   fipavonline/
     fipav-docker/            <- qui
     fipav-core/
     fipav-backoffice/
     fipav-comter-frontend/
   ```

**Solo la prima volta**, sulla macchina di staging:

```sh
cp .env.example .env.stage
```

A differenza dello sviluppo locale, qui **tre valori vanno generati** — `make up-stage` si
rifiuta di partire se sono rimasti sui default di sviluppo, con istruzioni su come rimediare
se te ne dimentichi. Nel `.env.stage` della macchina:

```sh
# INDISPENSABILE, e non solo per comter: da qui comter ricava il tenant dal
# sottodominio (lasciato a `localhost` il confronto in src/proxy.ts non
# matcha, si applica il fallback e OGNI hostname servirebbe il tenant
# `calabria` - il sintomo e' subdolo, calabria funziona, gli altri comitati
# mostrano i contenuti sbagliati), ED e' il dominio con cui `make sync-sites`
# costruisce gli hostname dei comitati per il gateway.
COMTER_ROOT_DOMAIN=fipav.altrama.it

# Un percorso, non un URL: axios lo usa come baseURL relativo, quindi le
# chiamate restano same-origin su QUALUNQUE hostname. Un URL assoluto ne
# fisserebbe uno solo e romperebbe il backoffice sugli altri comitati.
BACKOFFICE_API_BASE_URL=/core

# Solo per gli URL generati da CLI (queue, mail, artisan): nelle richieste HTTP
# Laravel deduce il base URL dalla request.
CORE_APP_URL=https://calabria.fipav.altrama.it/core

# ─── I tre valori da GENERARE, non da scrivere a mano ────────────
MARIADB_ROOT_PASSWORD=<qualcosa che non sia "root">

# Almeno 16 byte, o Meilisearch si rifiuta di partire in MEILI_ENV=production:
MEILI_MASTER_KEY=<generata con: openssl rand -base64 24>

# Basic Auth di /core/horizon - la STESSA credenziale protegge anche l'SMTP
# di Mailpit (vedi più sotto), non è solo per Horizon:
HORIZON_BASIC_AUTH_USER=fipav
HORIZON_BASIC_AUTH_HASH=<generato con: docker run --rm caddy:alpine caddy hash-password --plaintext 'una-password'>
```

```sh
make build && make up-stage
```

`make up-stage` fa da solo il resto del lavoro che di solito richiederebbe passaggi manuali:

1. Controlla i tre valori generati sopra, e si ferma con istruzioni se sono rimasti sui default.
2. Porta su `mariadb`, legge i comitati con `attivo = 1` dalla tabella `tenants`
   (`scripts/sync-sites.sh`, vedi *Aggiungere un comitato* più sotto) e scrive
   `docker/gateway/stage/sites.conf` — un blocco per hostname, letto da Caddy al suo primo
   avvio.
3. Scrive `docker/mailpit/smtp-auth` dalla stessa coppia `HORIZON_BASIC_AUTH_USER`/`HASH` di
   sopra: non è un quarto valore da generare, è derivato da quello che hai già messo.
4. Costruisce (se serve) e avvia tutto il resto: `php`, `horizon`, `mariadb`, `redis`,
   `mailpit`, `meilisearch`, i frontend (build multi-stage dentro l'immagine — vedi più sotto),
   il gateway.

Se in quel momento non ci sono ancora comitati attivi (macchina nuova, dati non ancora
importati) lo stack parte comunque, semplicemente senza hostname da servire finché non lanci
`make sync-sites` a dati importati (`make db-restore` per importare un dump, o
`scripts/sync-storage.sh` per gli upload — vedi *Dipendenze dei frontend* e i comandi database più
sotto).

Al primo giro conviene mettere `ACME_CA` sulla directory di staging di Let's Encrypt (è
commentata in `.env.example`): i certificati non sono validi per i browser, ma se qualcosa non
va non si consumano i rate limit, che sono 5 certificati a settimana per set di nomi. Quando
funziona, si rimette la riga di produzione e si riavvia.

L'overlay `docker-compose.stage.yml` fa anche il resto del lavoro che una macchina pubblica
richiede: **chiude tutte le porte tranne 80 e 443** — MariaDB, Redis e Mailpit restano
raggiungibili solo dalla rete Docker — spegne Xdebug, mette Meilisearch in
`MEILI_ENV=production` (richiede `MEILI_MASTER_KEY` nel `.env.stage`, `make up-stage` blocca
l'avvio se manca) e Mailpit dietro credenziali SMTP vere invece di accettarne qualunque —
`docker/mailpit/smtp-auth` è generato da `make up-stage` da `HORIZON_BASIC_AUTH_USER`/`HASH`,
la stessa credenziale di `/core/horizon`, non una seconda da tenere allineata a mano.

### In staging i frontend sono immagini gia' pronte, non dev server

In locale girano i dev server (HMR, sorgenti bind-mountati). In staging no: `docker build`
compila DENTRO l'immagine (build multi-stage — `docker/backoffice/stage/Dockerfile`,
`docker/comter/stage/Dockerfile`, context sul repo sibling, non su questa cartella), non il
container a ogni avvio.

| | locale (`docker/*/dev/Dockerfile`) | staging (`docker/*/stage/Dockerfile`) |
| --- | --- | --- |
| comter | bind mount + `next dev` a ogni avvio | immagine self-contained, `next start` parte subito |
| backoffice | bind mount + `npm run dev` a ogni avvio | build fatta una volta in `docker build`; il container in staging copia gli asset già pronti in un volume condiviso col gateway e termina |

Non è una preferenza, è un requisito. Sia Vite (`server.allowedHosts`) sia Next
(`allowedDevOrigins`) **validano l'Host in sviluppo**: con i dev server, ogni comitato nuovo
andrebbe aggiunto anche a `vite.config.ts` e `next.config.ts`, e non sarebbe più vero che basta
un dato nel DB (vedi *Aggiungere un comitato*). Quei controlli sono funzioni dei soli dev server
e in produzione non esistono — la documentazione di Next dice esplicitamente *"during
development"*.

In più spariscono sorgenti e sourcemap esposti su una macchina pubblica, e le pagine non si
ricompilano a ogni richiesta.

Come è realizzato: due Caddyfile separati (`docker/gateway/dev/Caddyfile`,
`docker/gateway/stage/Caddyfile` — non più un solo file con una variabile che sceglie
`backoffice.conf`), ciascuno con il proprio `backoffice.conf` affiancato. Il container del
backoffice in staging copia gli asset (già pronti nell'immagine) in un volume e **termina**: non
c'è nessun processo Node in ascolto, e il gateway attende che la copia sia completata prima di
partire.

Conseguenza pratica: **il tempo di build si sposta da `make up-stage` a `make build`**. La prima
volta serve comunque `make build && make up-stage` (la build multi-stage impiega qualche minuto
la prima volta, poi Docker mette in cache i layer). Dopo un `git pull` che tocca i frontend, un
`make update` da solo **non basta più a farli ripartire con il codice nuovo**: senza `--build`
un `restart` farebbe ripartire la stessa immagine di prima — `make update` lo sa già e usa
`up -d --build` per backoffice/comter quando rileva l'ambiente di staging (vedi il Makefile),
ma è bene saperlo se lanci `docker compose` a mano.

### Aggiungere un comitato: cosa NON lo blocca

Verificato anello per anello, perché è il requisito centrale del progetto:

| Anello | Blocca un hostname nuovo? |
| --- | --- |
| DNS | no, il record `A` wildcard lo copre |
| **Caddy** | **sì, se il comitato non è `attivo` in `tenants`** — è l'unico dato da toccare |
| Next (`next start`) | no, il controllo sull'origin è solo in sviluppo |
| Vite (build) | no, non c'è nessun server |
| `proxy.ts` di comter | no, ricava il tenant da qualunque sottodominio |
| Laravel | no, il progetto non usa `TrustHosts` |

Se un comitato non è attivo in `tenants` (o `make sync-sites` non è ancora stato rilanciato dopo
averlo attivato), Caddy non ha un certificato per quel nome: il browser mostra un **errore TLS**,
non un 404. È un sintomo utile, perché indica subito dove guardare e non un problema applicativo.

### Verificare che sia andata

```sh
make logs-gateway          # cerca "certificate obtained successfully"
curl -sI http://calabria.fipav.altrama.it/          # atteso: 301 verso https
curl -sI https://calabria.fipav.altrama.it/core/api/documentation   # atteso: 200
curl -sI https://cosenza.fipav.altrama.it/          # 200, e nessun avviso di certificato
```

Poi apri Swagger in un browser su https e guarda la console: **nessun avviso di mixed content**.
È la verifica che `trustProxies` in `fipav-core` sta funzionando; senza, Laravel genera URL
`http://` dentro pagine `https://` e il browser li blocca.

Se i certificati non arrivano, nel 99% dei casi è uno dei tre prerequisiti: DNS che non risolve,
porte chiuse, o un record `AAAA` che punta altrove (le CA preferiscono IPv6 quando esiste).

### Aggiungere un comitato

```sh
make sync-sites
```

Legge i comitati con `attivo = 1` dalla tabella `tenants` (la stessa che `IdentifyTenant` usa per
risolvere il tenant a runtime — vedi
`fipav-core/src/app/Http/Middleware/IdentifyTenant.php`), rigenera
`docker/gateway/stage/sites.conf` (un blocco `hostname.dominio { import site }` per comitato
attivo) e, solo se il file è cambiato, ricarica la configurazione di Caddy — nessun container
ricreato, nessuna connessione esistente interrotta. Non parla ACME di persona: si limita a dire a
Caddy quali hostname servire, e lui ottiene da sé il certificato per quelli nuovi
(`make logs-gateway` per seguirlo).

Non c'è nessun `.env` da toccare: la lista non è più una variabile, vive nel file generato. Il DNS
non si tocca nemmeno lui: il wildcard copre già il nuovo hostname.

### Prima di ogni deploy: `make verify`

I controlli 8-12 verificano le **guardie** del gateway, e nessuna di esse si manifesta da sola se
si rompe. La più importante è la 10: prova che un `.php` finito in `storage/` — la directory dei
file caricati dagli utenti — non venga eseguito. Senza quella guardia un upload diventa
esecuzione di codice sul server.

Nota per chi ci mette mano: Caddy risponde **200 con corpo vuoto** alle richieste che nessun
handler gestisce. Verificare i soli status code fa passare per funzionanti dei path che non
servono nulla, quindi i controlli guardano i byte.

## Riferimenti

Il design e le alternative scartate sono in
[`docs/superpowers/specs/2026-07-29-docker-unificato-design.md`](docs/superpowers/specs/2026-07-29-docker-unificato-design.md)
e, per il gateway Caddy e l'HTTPS,
[`docs/superpowers/specs/2026-07-29-https-letsencrypt-design.md`](docs/superpowers/specs/2026-07-29-https-letsencrypt-design.md).

Fuori scope, per scelta: configurazione di produzione (build ottimizzate, `next start`),
`robots.txt`, e la migrazione di `federvolley-frontend`, `federvolley-cms`, `fipav-aruba`,
`fipav-mock-backend`.