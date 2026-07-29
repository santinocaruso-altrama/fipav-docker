# FIPAV Online — stack di sviluppo unificato

Un solo `make up` avvia tutti i progetti dell'ecosistema, raggiungibili da un unico
entrypoint HTTP sulla porta 80.

| URL | Progetto | Cos'è |
| --- | --- | --- |
| `http://localhost/` | `fipav-comter-frontend` | sito pubblico dei comitati (Next.js) |
| `http://localhost/core/` | `fipav-core` | API e backend (Laravel) |
| `http://localhost/core/api/documentation` | `fipav-core` | Swagger UI |
| `http://localhost/backoffice/` | `fipav-backoffice` | backoffice (Vite + React) |
| `http://localhost:8080/` | `fipav-core` | accesso legacy, API sulla root |
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

## Avvio

```sh
cp .env.example .env     # solo la prima volta
make install             # build immagini, avvio, composer install, migrazioni
```

Poi, nell'uso quotidiano:

```sh
make up                  # avvia
make down                # ferma
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
che l'accesso legacy su `:8080` sia intatto, che il multi-tenant per sottodominio risponda
e che il database sia quello preesistente e non un volume ricreato vuoto.

L'HMR è l'unico criterio che resta manuale: modifica un file in
`../fipav-backoffice/src` e controlla che il browser si aggiorni senza reload.

## Comandi

`make` senza argomenti stampa l'elenco completo. I gruppi:

| | |
| --- | --- |
| **ciclo di vita** | `up` `down` `build` `rebuild` `restart` `ps` |
| **log** | `logs` `logs-gateway` `logs-php` `logs-backoffice` `logs-comter` `logs-fe` |
| **aggiornamento** | `pull` `update` |
| **verifica** | `verify` |
| **shell** | `shell` `sh-backoffice` `sh-comter` |
| **core / Laravel** | `artisan` `composer` `tinker` `migrate` `migrate-status` `seed` `fresh` `test` `swagger` `routes` `cache-clear` |
| **database** | `mariadb` `db-dump` `db-restore` |
| **dipendenze frontend** | `fe-reset` |

Con parametri:

```sh
make artisan cmd="route:list --path=cms"
make composer cmd="require league/csv"
make test-filter f="BreadcrumbTest"
make db-dump file=backup.sql
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

Nessuno dei due ricostruisce le immagini Docker: se `docker/php/Dockerfile` è cambiato serve
`make build`. Al momento serve a chi aggiorna da prima del supporto WebP/AVIF in GD — vedi
[Immagini: WebP e AVIF](#immagini-webp-e-avif).

## Come è fatto

```
host :80 / :443  (Host qualsiasi in locale; in staging gli hostname dei comitati)
    |
fipav-gateway (Caddy)
    |-- /            --> proxy   comter:3000        (Host inalterato, WebSocket per HMR)
    |-- /core/       --> fastcgi php:9000           (SCRIPT_NAME=/core/index.php)
    |-- /backoffice/ --> proxy   backoffice:3000    (path invariato, WebSocket per HMR)

host :8080
    |
fipav-nginx (legacy, core sulla root) --> fastcgi php:9000

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

`comter` chiama l'API **server-side**, da dentro la rete Docker
(`http://fipav-nginx/api/v1/public/cms`). Le risposte finiscono nell'HTML servito al browser,
quindi ogni URL costruito sul root della request sarebbe `http://fipav-nginx/...`: un hostname
che il browser non risolve.

`CORE_ASSET_URL=/core` risolve il problema alla radice — è un **percorso**, non un URL, quindi
le immagini escono come `/core/images/discipline/pallavolo.jpg`: relative alla root, senza
hostname, identiche in locale, staging e produzione.

Richiede la chiave `asset_url` in `fipav-core/src/config/app.php` e che i controller usino
`asset()` e non `url()`. Lasciata vuota, `asset()` ricade sul root della request, cioè il
comportamento storico di chi lancia `fipav-core` da solo.

## Cose da sapere

### Non far girare due stack insieme

I `container_name` sono volutamente identici a quelli del compose di `fipav-core`
(`fipav-php`, `fipav-mariadb`, …), così `docker exec fipav-php php artisan …` continua a
funzionare come sempre. La conseguenza è che **questo compose e quello di `fipav-core` sono
mutuamente esclusivi**: questo è l'entrypoint di riferimento, quello di `fipav-core` resta in
repo come riferimento storico.

Per lo stesso motivo il **`Makefile` di `fipav-core` non funziona** mentre gira questo stack:
i suoi `docker compose exec` puntano al project `fipav-core`, che è spento. I comandi
quotidiani sono replicati qui con gli stessi nomi.

### Mai `docker compose down -v`

I volumi `mariadb-data` e `meilisearch-data` sono dichiarati nel compose con `name:` pinnato
a quelli creati da `fipav-core` (`fipav-core_mariadb-data`), così il database `camp2013` di
lavoro viene **riusato** invece di essere ricreato vuoto.

Il rovescio della medaglia è che `down --volumes` lo cancellerebbe. Nessun target del
`Makefile` passa quel flag, ed è meglio non aggiungerlo. Per ripulire solo le dipendenze dei
frontend c'è `make fe-reset`.

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
nginx locale). Cambia porta nel `.env`:

```sh
GATEWAY_PORT=8000
```

Gli URL diventano `http://localhost:8000/…`. Il `Makefile` legge il `.env`, quindi `make up`
e `make verify` si adeguano da soli.

## Configurazione

Tutto in `.env` (copia di `.env.example`, non versionato). Le variabili passano ai container
come variabili d'ambiente reali, che **vincono sui file `.env` dei singoli progetti** — sia in
Laravel (Dotenv non sovrascrive quanto è già in ambiente) sia in Vite sia in Next. Per questo
i `.env` dei tre progetti non vanno modificati: il workflow locale fuori da Docker resta
identico a prima.

| Variabile | Default | A cosa serve |
| --- | --- | --- |
| `GATEWAY_PORT` | `80` | porta dell'unico entrypoint HTTP |
| `CORE_LEGACY_PORT` | `8080` | accesso legacy a core con l'API sulla root |
| `CORE_APP_URL` | `http://localhost/core` | URL generati da CLI (queue, mail, artisan) |
| `CORE_ASSET_URL` | `/core` | prefisso delle immagini emesse da `asset()` |
| `XDEBUG_MODE` | `debug` | `off` recupera parecchi ms per richiesta |
| `BACKOFFICE_API_BASE_URL` | `http://localhost/core` | letto dal browser: same-origin, nessun CORS |
| `COMTER_API_BASE_URL` | `http://fipav-nginx/api/v1/public/cms` | chiamate server-side, restano nella rete Docker |
| `COMTER_ROOT_DOMAIN` | `localhost` | root domain da cui si ricava il tenant dal sottodominio |
| `GATEWAY_SITES` | `http://` | indirizzi serviti dal gateway; un elenco di hostname attiva l'HTTPS |
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

Poi `cp .env.example .env` e, nel `.env` della macchina:

```sh
# Gli hostname serviti. Attiva l'HTTPS automatico.
GATEWAY_SITES=calabria.fipav.altrama.it cosenza.fipav.altrama.it lazio.fipav.altrama.it roma.fipav.altrama.it

# INDISPENSABILE: da qui comter ricava il tenant dal sottodominio. Lasciato a
# `localhost` il confronto in src/proxy.ts non matcha, si applica il fallback e
# OGNI hostname servirebbe il tenant `calabria`. Il sintomo e' subdolo: calabria
# funziona, gli altri comitati mostrano i contenuti sbagliati.
COMTER_ROOT_DOMAIN=fipav.altrama.it

# Un percorso, non un URL: axios lo usa come baseURL relativo, quindi le
# chiamate restano same-origin su QUALUNQUE hostname. Un URL assoluto ne
# fisserebbe uno solo e romperebbe il backoffice sugli altri comitati.
BACKOFFICE_API_BASE_URL=/core

# Solo per gli URL generati da CLI (queue, mail, artisan): nelle richieste HTTP
# Laravel deduce il base URL dalla request.
CORE_APP_URL=https://calabria.fipav.altrama.it/core

MARIADB_ROOT_PASSWORD=<qualcosa che non sia root>
```

```sh
make build && make up-staging
```

Caddy ottiene i certificati al primo avvio e reindirizza http a https. `make up-staging` si
rifiuta di partire se `GATEWAY_SITES` è ancora `http://`, per non ritrovarsi una macchina
pubblica che serve in chiaro senza accorgersene.

Al primo giro conviene mettere `ACME_CA` sulla directory di staging di Let's Encrypt (è
commentata in `.env.example`): i certificati non sono validi per i browser, ma se qualcosa non
va non si consumano i rate limit, che sono 5 certificati a settimana per set di nomi. Quando
funziona, si rimette la riga di produzione e si riavvia.

L'overlay `docker-compose.staging.yml` fa anche il resto del lavoro che una macchina pubblica
richiede: **chiude tutte le porte tranne 80 e 443** — MariaDB, Redis, Mailpit, Meilisearch e
l'accesso legacy `:8080`, che altrimenti sarebbe un secondo ingresso all'API in chiaro,
scavalcando il gateway — e spegne Xdebug. I servizi continuano a girare, raggiungibili solo
dalla rete Docker.

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
# .env
GATEWAY_SITES=… sicilia.fipav.altrama.it
```

```sh
make up-staging
```

Il DNS non si tocca: il wildcard copre già il nuovo hostname.

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