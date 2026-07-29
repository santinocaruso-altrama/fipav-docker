# Docker unificato FIPAV Online — design

Data: 2026-07-29
Stato: approvato

## Obiettivo

Un unico `docker compose up` avvia tutti i progetti dell'ecosistema FIPAV Online, raggiungibili
da un solo entrypoint HTTP sulla porta 80:

| URL | Progetto |
| --- | --- |
| `http://localhost/` | `fipav-comter-frontend` (Next.js) |
| `http://localhost/core/` | `fipav-core` (Laravel) |
| `http://localhost/backoffice/` | `fipav-backoffice` (Vite/React) |

L'accesso legacy `http://localhost:8080/` a `fipav-core` resta attivo in parallelo per non
rompere le configurazioni esistenti durante la migrazione.

## Stato di partenza

- `fipav-core` ha un `docker-compose.yml` completo: php-fpm 8.4, nginx su `:8080`, mariadb,
  redis, mailpit, meilisearch. Il suo `docker/nginx/default.conf` prova già a fare proxy di
  `/backoffice/` verso `backoffice:3000`, ma quel servizio non esiste in nessun compose
  (rimanda a un `docker-compose-fe.yaml` mai creato): oggi quel path è rotto.
- `fipav-backoffice` è una SPA Vite con `base: '/backoffice/'` e dev server su `:3000`.
  Nessuna configurazione Docker, si avvia a mano con `npm run dev`.
- `fipav-comter-frontend` è un'app Next.js 16 su `:3000`, multi-tenant per sottodominio
  (`src/proxy.ts` estrae il sottodominio e imposta l'header `x-tenant`, con fallback `calabria`).
  Nessuna configurazione Docker.
- I volumi Docker esistenti sono `fipav-core_mariadb-data` e `fipav-core_meilisearch-data`.
  Il database `camp2013` che vive nel primo contiene dati di lavoro e non va perso.

## Decisioni

| Tema | Scelta |
| --- | --- |
| Porta del gateway | 80, così gli URL sono senza porta e i tenant diventano `calabria.localhost` |
| Modalità dei frontend | dev server con HMR, codice bind-mountato |
| Compatibilità `:8080` | mantenuta in parallelo |
| Multi-tenant | gateway host-agnostico: `*.localhost` oggi, `*.fipav.altrama.it` in futuro |
| Posizione dei file | `fipav-docker/`, cartella neutra fuori dai tre progetti |
| Montaggio di `/core` | fastcgi diretto con `SCRIPT_NAME` riscritto (approccio A) |

### Perché fastcgi diretto per `/core`

Montare Laravel sotto un prefisso di path non è un `proxy_pass`. Le alternative valutate:

- **A (scelta)** — il gateway monta `../fipav-core/src` e parla direttamente a `php:9000`,
  passando `SCRIPT_FILENAME=/var/www/html/public/index.php` e `SCRIPT_NAME=/core/index.php`.
  Symfony ricava `baseUrl=/core` e `pathInfo=/api/v1/...`: le route continuano a fare match e
  contemporaneamente `url()`, `route()`, `asset()`, Swagger e `Storage::url()` generano già
  URL con `/core`. Nessuna modifica al codice PHP, un solo hop di rete.
- **B (scartata)** — `proxy_pass` verso il nginx di core strippando il prefisso. Config
  banale, ma Laravel vede `/api/...` e genera URL senza `/core`: Swagger UI, redirect e URL
  dei media si rompono. Servirebbe abilitare `X-Forwarded-Prefix` (TrustProxies +
  `HEADER_X_FORWARDED_PREFIX`), quindi modificare `fipav-core`, e non tutti i punti di Laravel
  rispettano quell'header.
- **C (scartata)** — esporre sotto `/core` solo `/core/api/`. Funziona senza trucchi perché il
  JSON non contiene URL assoluti, ma Swagger e i media resterebbero solo su `:8080`, quindi
  non soddisfa il requisito.

Tenere anche il nginx legacy su `:8080` non crea conflitti: due nginx possono servire lo stesso
php-fpm con `SCRIPT_NAME` differenti.

## Architettura

```
host :80  (Host qualsiasi: localhost, *.localhost, *.fipav.altrama.it)
    |
    v
fipav-gateway (nginx:alpine, default_server)
    |-- /            --> proxy  fipav-comter:3000        (Host inalterato, WS per HMR)
    |-- /core/       --> fastcgi fipav-php:9000          (SCRIPT_NAME=/core/index.php)
    |-- /backoffice/ --> proxy  fipav-backoffice:3000    (path inalterato, WS per HMR)

host :8080
    |
    v
fipav-nginx (legacy, core su root) --> fastcgi fipav-php:9000

infra condivisa sulla rete fipav-network:
  fipav-mariadb (:3307)  fipav-redis (:6379)
  fipav-mailpit (:8025)  fipav-meilisearch (:7700)
```

### Tabella di routing del gateway

| Location | Destinazione | Note |
| --- | --- | --- |
| `^~ /backoffice/` | `proxy_pass http://backoffice:3000` | path invariato perché Vite ha `base: '/backoffice/'`; upgrade WebSocket per l'HMR |
| `= /backoffice` | 301 → `/backoffice/` | |
| `^~ /core/storage/` | come `/core/` + `Access-Control-Allow-Origin: *` | i media devono restare leggibili via canvas dal backoffice |
| `^~ /core/` | `alias` per gli static, fallback `@core` in fastcgi | |
| `= /core` | 301 → `/core/` | |
| `/` | `proxy_pass http://comter:3000` | catch-all; upgrade WebSocket per l'HMR di Next |

`^~` garantisce che i due prefissi vincano sul catch-all `/` senza dipendere dall'ordine dei
match delle regex.

Il gateway è `default_server` e propaga `Host` inalterato, quindi il multi-tenant di
`proxy.ts` funziona sia con `calabria.localhost` sia con `calabria.fipav.altrama.it` senza
modifiche al codice: basta allineare `NEXT_PUBLIC_ROOT_DOMAIN`.

## Componenti

### Servizi del compose

| Servizio | container_name | Immagine / build | Porte host |
| --- | --- | --- | --- |
| `gateway` | `fipav-gateway` | `nginx:alpine` | `80:80` |
| `php` | `fipav-php` | build `docker/php` | — |
| `nginx` | `fipav-nginx` | `nginx:alpine` | `8080:80` (legacy) |
| `backoffice` | `fipav-backoffice` | build `docker/backoffice` | — |
| `comter` | `fipav-comter` | build `docker/comter` | — |
| `mariadb` | `fipav-mariadb` | `mariadb:11.4` | `3307:3306` |
| `redis` | `fipav-redis` | `redis:alpine` | `6379:6379` |
| `mailpit` | `fipav-mailpit` | `axllent/mailpit` | `8025`, `1025` |
| `meilisearch` | `fipav-meilisearch` | `getmeili/meilisearch` | `7700:7700` |

I frontend non espongono porte sull'host: si raggiungono solo dal gateway. Questo evita di
avere due URL validi per la stessa app e libera la `:3000` per il `npm run dev` locale.

### Contratti fra i componenti

- **gateway → php**: protocollo FastCGI. Il contratto è la coppia
  `SCRIPT_FILENAME=/var/www/html/public/index.php` + `SCRIPT_NAME=/core/index.php`. Entrambi i
  container montano `../fipav-core/src` sullo stesso path `/var/www/html`, così i percorsi
  coincidono e non serve tradurli.
- **gateway → backoffice / comter**: HTTP con `Host` propagato e upgrade WebSocket.
- **comter → core**: HTTP interno `http://fipav-nginx/api/v1/public/cms`. Le chiamate sono
  server-side (Next.js `fetch` nei service), quindi passano dalla rete Docker senza uscire e
  senza attraversare il gateway.
- **backoffice → core**: HTTP dal browser verso `http://localhost/core`. Essendo same-origin
  non serve nessuna configurazione CORS.

### File da creare in `fipav-docker/`

```
docker-compose.yml
.env                          # ROOT_DOMAIN, tenant di default, porte
.env.example
.dockerignore
README.md
Makefile
docker/
  gateway/default.conf        # il routing dei tre path
  nginx/default.conf          # copia legacy :8080 da fipav-core
  php/Dockerfile              # copia da fipav-core
  mysql/init.sql              # copia da fipav-core
  backoffice/Dockerfile
  backoffice/entrypoint.sh
  comter/Dockerfile
  comter/entrypoint.sh
```

`docker-compose.yml` referenzia i progetti come sibling (`../fipav-core/src`,
`../fipav-comter-frontend`, `../fipav-backoffice`), quindi va eseguito da `fipav-docker/` e
assume che i tre progetti stiano nella stessa directory padre. Il `README.md` lo dichiara
esplicitamente.

### Gestione di node_modules

I `node_modules` presenti sul Mac contengono binari compilati per darwin-arm64 (`esbuild`,
`@vitejs/plugin-react-swc`, `@tailwindcss/oxide`, `next-swc`, `sharp`). Bind-mountarli in un
container linux li rende inutilizzabili.

Strategia: bind mount del solo sorgente, più un volume named montato su `node_modules` che
maschera la cartella dell'host. L'entrypoint installa le dipendenze al primo avvio se il
volume è vuoto:

- backoffice: `npm ci` (esiste `package-lock.json`)
- comter: `bun install --frozen-lockfile` (esiste solo `bun.lock`)

L'immagine di comter è `node:22-bookworm-slim` con `bun` installato: bun per l'install, node
disponibile per i tool di Next che lo richiedono.

Conseguenza voluta: `npm run dev` sul Mac e i container coesistono senza toccarsi.

### Volumi

```yaml
volumes:
  mariadb-data:
    name: fipav-core_mariadb-data
  meilisearch-data:
    name: fipav-core_meilisearch-data
  backoffice-node-modules:
  comter-node-modules:
```

I due primi sono pinnati al nome esistente: un compose con project name diverso creerebbe
volumi nuovi e vuoti, perdendo l'accesso al `camp2013` di lavoro. Con `name:` espresso, il
volume viene riusato se c'è e creato se manca.

### Container name e mutua esclusione

I nomi dei container esistenti restano identici (`fipav-php`, `fipav-mariadb`, `fipav-redis`,
`fipav-mailpit`, `fipav-meilisearch`, `fipav-nginx`), così `docker exec fipav-php php artisan …`
continua a funzionare come da abitudine consolidata.

La conseguenza è che il compose di `fipav-docker` e quello di `fipav-core` non possono girare
contemporaneamente. `fipav-docker/docker-compose.yml` diventa l'unico entrypoint;
`fipav-core/docker-compose.yml` resta in repo come riferimento storico, con una nota nel README.

## Modifiche ai progetti esistenti

Tutte condizionate da variabili d'ambiente, così il workflow locale non cambia comportamento.

| File | Modifica | Perché |
| --- | --- | --- |
| `fipav-backoffice/vite.config.ts` | `server.host: '0.0.0.0'`, `server.open: false`, `server.allowedHosts: true`, `server.hmr.clientPort` da env | in container il dev server deve ascoltare su tutte le interfacce, non aprire browser, accettare Host arbitrari e far puntare il client HMR alla porta del gateway |
| `fipav-core/src/.env` | `APP_URL=http://localhost/core` | gli URL generati da CLI (queue, mail, comandi) non hanno una request da cui dedurre il base path |
| `fipav-backoffice/.env` | `VITE_API_BASE_URL=http://localhost/core` | same-origin, elimina il CORS verso `:8080` |
| `fipav-comter-frontend/.env` | `API_BASE_URL=http://fipav-nginx/api/v1/public/cms`, `NEXT_PUBLIC_ROOT_DOMAIN=localhost` | chiamata server-side interna; root domain coerente con la porta 80 |

`src/proxy.ts` di comter non va toccato: gestisce già sia `*.localhost` sia un root domain
generico, quindi copre `*.fipav.altrama.it` cambiando solo l'env.

## Flusso di una richiesta

**`GET http://calabria.localhost/pallavolo`**
gateway (`default_server`, Host `calabria.localhost`) → `location /` → `proxy_pass comter:3000`
con Host inalterato → `proxy.ts` estrae `calabria` e imposta `x-tenant` → il service chiama
`http://fipav-nginx/api/v1/public/cms/...` sulla rete Docker → nginx legacy → `php:9000` →
Laravel → mariadb.

**`GET http://localhost/core/api/documentation`**
gateway → `location ^~ /core/` → il file non esiste su disco → `@core` → fastcgi a `php:9000`
con `SCRIPT_NAME=/core/index.php` → Symfony: `baseUrl=/core`, `pathInfo=/api/documentation` →
la route fa match → Swagger UI genera i suoi asset sotto `/core/...` e si carica correttamente.

**`GET http://localhost/backoffice/`**
gateway → `location ^~ /backoffice/` → `proxy_pass backoffice:3000` con path invariato → Vite
serve `index.html` con `base=/backoffice/` → il browser apre il WebSocket HMR su
`ws://localhost/backoffice/` → il gateway fa l'upgrade.

## Gestione degli errori

- **Porta 80 occupata**: `docker compose up` fallisce con `bind: address already in use`. La
  porta è parametrizzata in `.env` (`GATEWAY_PORT=80`) per poterla cambiare senza editare il
  compose. Il README documenta il caso.
- **Frontend non ancora pronto**: durante l'`install` iniziale dell'entrypoint il dev server
  non risponde e nginx restituisce 502. È atteso al primo avvio e va documentato, non mascherato.
  `depends_on` non aiuta perché il container è già "up" mentre installa.
- **Dipendenze corrotte nel volume**: target `make fe-reset` che rimuove i volumi
  `*-node-modules` e forza una reinstallazione pulita.
- **Healthcheck**: su mariadb (`healthcheck` con `mariadb-admin ping`) così php non parte prima
  che il DB accetti connessioni. Per i frontend un healthcheck HTTP sul dev server.
- **Volume del DB assente**: al primo avvio `init.sql` crea i database e i grant. Con il volume
  già popolato lo script non viene rieseguito (comportamento standard di
  `docker-entrypoint-initdb.d`), quindi non c'è rischio di sovrascrittura.

## Verifica

Nessuna suite di test automatici: è configurazione infrastrutturale, si verifica osservando il
comportamento reale. Criteri di accettazione, tutti da eseguire dopo `make up`:

1. `curl -s -o /dev/null -w '%{http_code}' http://localhost/` → `200`, e il body contiene
   markup generato da Next.
2. `curl -s -o /dev/null -w '%{http_code}' http://localhost/core/api/documentation` → `200`.
3. `curl -s http://localhost/core/api/documentation` → gli URL degli asset nel body contengono
   `/core/`, non `/`. È la prova che `SCRIPT_NAME` funziona.
4. `curl -s -o /dev/null -w '%{http_code}' http://localhost/backoffice/` → `200`, body con il
   tag script di Vite sotto `/backoffice/`.
5. `curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/api/documentation` → `200`
   (compatibilità legacy preservata).
6. `curl -s -H 'Host: calabria.localhost' http://localhost/` → risposta del tenant `calabria`.
7. `docker exec fipav-php php artisan migrate:status` → funziona e vede il `camp2013` esistente
   con le sue tabelle. È la prova che il volume è stato riusato e non ricreato vuoto.
8. Modifica di un file in `fipav-backoffice/src` → il browser aggiorna via HMR senza reload
   manuale. Idem per `fipav-comter-frontend/src`.

## Fuori scope

- Configurazione di produzione (build ottimizzate, TLS, `next start`). Il compose è dichiarato
  come ambiente di sviluppo.
- Esposizione di mailpit e meilisearch dietro il gateway: restano sulle loro porte dedicate.
- Migrazione di `federvolley-frontend`, `federvolley-cms`, `fipav-aruba`, `fipav-mock-backend`,
  `fipav-OLD`.
- Rimozione del compose di `fipav-core` e degli accessi legacy su `:8080`: rientrano in una
  pulizia successiva, quando i `.env` saranno tutti allineati.