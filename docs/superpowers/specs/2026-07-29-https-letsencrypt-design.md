# Gateway Caddy con HTTPS automatico — design

Data: 2026-07-29
Stato: implementato e verificato in locale. Lo staging non è ancora stato provato: manca il
record DNS. Vedi *Esito dell'implementazione*.

## Obiettivo

Sostituire nginx con Caddy come gateway unico dell'ecosistema, per ottenere HTTPS su una macchina
pubblica **senza nessuna gestione manuale dei certificati**:

```
https://calabria.fipav.altrama.it/            -> fipav-comter-frontend
https://calabria.fipav.altrama.it/core/       -> fipav-core
https://calabria.fipav.altrama.it/backoffice/ -> fipav-backoffice
```

Requisito operativo che guida il design: **aggiungere un comitato costa una riga nel `.env` e un
riavvio.** Nessun record DNS da inserire, nessun rinnovo da ricordare, nessun comando da lanciare
ogni 60 giorni.

Un solo Caddyfile serve sia il locale sia lo staging: le due situazioni differiscono per il valore
di una variabile d'ambiente, non per il file di configurazione.

## Stato di partenza

- Il gateway è `nginx:alpine` con `docker/gateway/default.conf`, ascolta solo sulla `:80`,
  `server_name _` per restare host-agnostico e non rompere il routing per sottodominio di
  `src/proxy.ts` (fallback tenant `calabria`).
- `docker-compose.yml` è dichiarato ambiente di sviluppo e in
  [`2026-07-29-docker-unificato-design.md`](2026-07-29-docker-unificato-design.md) il TLS è
  esplicitamente fuori scope. Questo design estende quello scope.
- `fipav-core/src/bootstrap/app.php` **non configura `trustProxies`**.
- I tenant seeded sono quattro: `calabria`, `cosenza`, `lazio`, `roma`
  (`fipav-core/src/database/seeders/csv/TenantSeeder.csv`).
- Il DNS di `altrama.it` è su Tophost/Seeweb, gestito da pannello cPanel, **senza API pubblica**.
- Oggi nessuno degli hostname `*.fipav.altrama.it` risolve.

## Decisioni

| Tema | Scelta |
| --- | --- |
| Gateway | **Caddy** al posto di nginx, in locale e in staging |
| Certificati | HTTPS automatico nativo di Caddy: emissione e rinnovo senza intervento |
| Challenge ACME | gestita da Caddy (HTTP-01 / TLS-ALPN-01), nessuna configurazione |
| Hostname coperti | elenco dei tenant in `{$GATEWAY_SITES}` nel `.env` |
| Record DNS | un solo `A` wildcard `*.fipav.altrama.it`, creato una volta |
| Differenza locale/staging | solo il valore di `GATEWAY_SITES` |
| Hardening staging | overlay `docker-compose.staging.yml` (porte di servizio, Xdebug, password) |

### Perché Caddy e non nginx + certbot

L'alternativa valutata in dettaglio era nginx con certbot in HTTP-01 webroot. Funziona, ma
richiede: un servizio certbot con loop di rinnovo, due volumi condivisi (webroot e certificati), un
certificato self-signed di bootstrap perché nginx non parte con `ssl_certificate` mancante, un loop
di `nginx -s reload` per mettere in servizio i rinnovi, e il meccanismo `templates/` + envsubst con
`NGINX_ENVSUBST_FILTER` per iniettare il nome del dominio nel path del certificato.

Con Caddy **tutto questo non esiste**. L'HTTPS automatico è nativo: Caddy emette al primo avvio,
rinnova in background, ricarica da sé. Sparisce anche la `map $http_upgrade $connection_upgrade`,
perché `reverse_proxy` gestisce i WebSocket senza configurazione — e i WebSocket qui servono, sono
l'HMR di Vite e di Next.

In più: Caddy può validare via TLS-ALPN-01 sulla 443, quindi la porta 80 non è indispensabile
(con nginx+certbot in HTTP-01 chiudere la 80 mesi dopo farebbe scadere il certificato in silenzio,
ed è il modo più probabile di rompere quel setup).

### Il record A wildcard è la chiave del requisito operativo

Un hostname nuovo deve risolvere, altrimenti nessuna CA lo valida e nessun browser lo raggiunge:
vincolo incomprimibile. Ma un unico record

```
*.fipav.altrama.it    A    <IP della macchina>
```

lo soddisfa per ogni sottodominio futuro. Da quel momento il DNS non si apre più.

Da non confondere con il **certificato** wildcard: il **record A** wildcard è una funzionalità DNS
banale, presente nello Zone Editor cPanel come in qualunque pannello. Il certificato wildcard è
quello che richiederebbe DNS-01 e un'API DNS, che Tophost non ha. Condividono solo la parola.

### Perché un solo gateway per locale e staging

Tenere nginx in locale e Caddy in staging significherebbe due configurazioni in due linguaggi
diversi da mantenere allineate a ogni modifica del routing, con divergenze non diffabili. Con un
solo Caddyfile, quello che si verifica in locale è quello che gira in staging.

Costo accettato: la configurazione nginx attuale viene ritirata. È una perdita reale — contiene
commenti che spiegano scelte non ovvie — ed è per questo che la sezione *Guardie da trasferire* è
la parte più importante di questo documento.

## Verifica preliminare già eseguita

Prima di scrivere questo design è stato fatto uno spike con un container Caddy usa-e-getta sulla
rete `fipav-network`, confrontando le risposte con quelle del gateway nginx in funzione. Risultati:

| Verifica | Esito |
| --- | --- |
| `/core` via FastCGI con `SCRIPT_NAME` sovrascritto | **funziona**: `/core/api/documentation` risponde con HTML reale e URL prefissati `/core/docs/asset/...`, identici a nginx |
| `.php` caricato in `storage/app/public` | **eseguito**: Caddy ha restituito l'output del file, nginx risponde 404 |
| File statici di `public/` senza `file_server` | **non serviti**: `robots.txt` 0 byte contro 24 su nginx, media di storage 0 byte contro 133 KB |

Il primo risultato è quello che rendeva Caddy praticabile: bastano due righe di `env`. Il secondo e
il terzo sono i motivi per cui una porta ingenua del Caddyfile non è accettabile.

Nota metodologica: Caddy risponde **200 con corpo vuoto** quando nessun handler gestisce la
richiesta. Confrontare i soli status code fa passare per funzionanti dei path che non servono
nulla; le verifiche vanno fatte sul corpo.

## Guardie da trasferire

La configurazione nginx attuale non è verbosa per abitudine: ogni guardia c'è per un motivo. Vanno
riprodotte una per una, e ognuna ha il suo test di non regressione.

| Guardia | nginx oggi | Perché | Rischio se persa |
| --- | --- | --- | --- |
| `.php` sotto `/core/storage/` | `return 404` | `storage/` contiene file caricati dagli utenti | **RCE**: un upload malevolo diventa esecuzione di codice. Dimostrato nello spike |
| `.php` sotto `/core/` | `return 404` | l'unico entrypoint PHP legittimo è `index.php` via FastCGI | entrypoint duplicati, sorgente PHP servito come statico se il file esiste su disco |
| Dotfile, eccetto `.well-known` | `deny all` | `.env`, `.git` non devono essere raggiungibili | esposizione di credenziali |
| `Access-Control-Allow-Origin: *` su `/core/storage/` | `add_header` | il backoffice legge i pixel dei media via canvas per l'editor di crop | l'editor di crop si rompe |
| `client_max_body_size 25M` | direttiva | upload di media | upload grossi rifiutati |
| `fastcgi_read_timeout 300` | direttiva | import massivi e generazione della spec OpenAPI superano i 60s | timeout su operazioni lunghe |

## Caddyfile

```caddyfile
{
	acme_ca {$ACME_CA:https://acme-v02.api.letsencrypt.org/directory}
	# Nessuna direttiva `email`: vedi "Perche' l'account ACME non ha indirizzo".
}

# In locale GATEWAY_SITES vale `http://`: Caddy serve qualunque Host sulla 80 in
# chiaro, esattamente come `server_name _` oggi, e non emette certificati. In
# staging contiene l'elenco degli hostname: da quel solo fatto Caddy attiva
# l'HTTPS automatico e il redirect da http.
{$GATEWAY_SITES:http://} {
	request_body {
		max_size 25MB
	}

	# ─── /backoffice -> Vite dev server ──────────────────────────────
	redir /backoffice /backoffice/ 301

	# Vite e' configurato con base '/backoffice/', quindi il path va inoltrato
	# invariato: nessuno strip del prefisso, o gli asset si rompono.
	# reverse_proxy gestisce l'upgrade a WebSocket (HMR) da se'.
	handle /backoffice/* {
		reverse_proxy backoffice:3000
	}

	# ─── /core -> Laravel via FastCGI ────────────────────────────────
	redir /core /core/ 301

	handle_path /core/* {
		root * /var/www/html/public

		# `route` forza l'ordine di valutazione a quello scritto. Senza, Caddy
		# applica il proprio ordine di direttive e le guardie potrebbero essere
		# valutate DOPO php_fastcgi: sarebbero inefficaci.
		route {
			# GUARDIA (critica). Un solo matcher copre due esigenze:
			# storage/ contiene file caricati dagli utenti, e senza questa
			# riga php_fastcgi eseguirebbe un .php arrivato per upload
			# (verificato); e l'unico entrypoint PHP legittimo e' l'index.php
			# implicito, raggiunto per rewrite interno e non per URL.
			# Il rewrite interno avviene DOPO questo matcher, quindi
			# l'applicazione continua a funzionare.
			@php path *.php
			respond @php 404

			# GUARDIA: dotfile non raggiungibili, eccetto .well-known.
			# RE2 non ha i lookahead negativi: l'eccezione va espressa con
			# `not`, non con (?!...). Un path_regexp con lookahead non
			# compila.
			@dotfiles {
				path /.* /*/.*
				not path /.well-known/*
			}
			respond @dotfiles 403

			# I media di storage/public sono pubblici per design: l'header CORS
			# consente al backoffice di leggerne i pixel via canvas.
			@storage path /storage/*
			header @storage Access-Control-Allow-Origin *

			# SCRIPT_NAME e' il punto chiave: da /core/index.php Symfony ricava
			# baseUrl=/core, quindi url(), route(), asset() e Storage::url()
			# generano URL col prefisso e le route continuano a fare match sui
			# path senza prefisso.
			#
			# REQUEST_URI va rimesso all'originale perche' handle_path spoglia
			# il prefisso: senza, Symfony calcolerebbe pathInfo su un URI privo
			# di /core e la deduzione di baseUrl fallirebbe.
			php_fastcgi php:9000 {
				env SCRIPT_NAME /core/index.php
				env REQUEST_URI {http.request.orig_uri}
			}

			# Obbligatorio: php_fastcgi NON serve i file statici. Senza questa
			# riga favicon, robots.txt, images/ e i media di storage/ tornano
			# 200 con corpo vuoto. Verificato nello spike.
			file_server
		}
	}

	# ─── / -> Next.js dev server ─────────────────────────────────────
	# Host propagato inalterato all'upstream, cosi' il routing multi-tenant per
	# sottodominio di src/proxy.ts continua a funzionare.
	handle {
		reverse_proxy comter:3000
	}
}
```

### Dettaglio aperto: `fastcgi_read_timeout`

`php_fastcgi` non espone `read_timeout`. Per i 300s necessari a import massivi e generazione della
spec OpenAPI serve la forma espansa (`reverse_proxy` con `transport fastcgi { read_timeout 300s }`)
al posto della scorciatoia. Da risolvere in implementazione: si sceglie la forma espansa solo per
questo, oppure si verifica che il limite effettivo sia già il `max_execution_time` di PHP e la
scorciatoia basti. Va deciso con una misura, non a priori.

## Compose

### Servizio `gateway`

```yaml
gateway:
  image: caddy:alpine
  container_name: fipav-gateway
  ports:
    - "${GATEWAY_PORT:-80}:80"
    - "${HTTPS_PORT:-443}:443"
  volumes:
    - ../fipav-core/src:/var/www/html:ro
    - ./docker/gateway/Caddyfile:/etc/caddy/Caddyfile:ro
    - caddy-data:/data      # certificati e chiavi ACME
    - caddy-config:/config
  environment:
    TZ: Europe/Rome
    GATEWAY_SITES: "${GATEWAY_SITES:-http://}"
    ACME_CA: "${ACME_CA:-https://acme-v02.api.letsencrypt.org/directory}"
```

`caddy-data` è un volume **obbligatorio**, non un'ottimizzazione: contiene i certificati e le
chiavi dell'account ACME. Senza, ogni ricreazione del container riemette da zero e brucia i rate
limit di Let's Encrypt (5 certificati a settimana per set di nomi).

La `443` viene pubblicata anche in locale, dove resta semplicemente inutilizzata: con
`GATEWAY_SITES=http://` Caddy non ascolta in TLS. Pubblicarla sempre evita un overlay solo per
questo.

### `.env`

```sh
# Locale: `http://` = qualunque Host sulla 80 in chiaro, nessun certificato.
# Staging: l'elenco degli hostname, separati da spazio. La sola presenza di
# nomi pubblici attiva l'HTTPS automatico e il redirect da http.
GATEWAY_SITES=http://

# Staging:
# GATEWAY_SITES=calabria.fipav.altrama.it cosenza.fipav.altrama.it lazio.fipav.altrama.it roma.fipav.altrama.it

# Directory ACME. Il default e' la produzione; quella di staging serve a provare
# con hostname veri senza consumare i rate limit.
ACME_CA=https://acme-v02.api.letsencrypt.org/directory

HTTPS_PORT=443

# In locale il default va bene. Su una macchina pubblica va cambiata.
MARIADB_ROOT_PASSWORD=root
```

Le variabili `LETSENCRYPT_PRIMARY_DOMAIN` e `LETSENCRYPT_EXTRA_DOMAINS` **sono state rimosse**:
erano necessarie al design nginx+certbot, dove un nome era il path del certificato e gli altri
erano SAN. Caddy non ha questa distinzione: un elenco piatto in `GATEWAY_SITES` basta.

### Perché l'account ACME non ha indirizzo

Non c'è nessuna variabile per l'email dell'account ACME, ed è una scelta forzata: la direttiva
`email` di Caddy non ammette un valore vuoto. `email {$LETSENCRYPT_EMAIL}` con la variabile non
impostata è un **errore di parsing** — verificato — quindi renderla configurabile romperebbe il
gateway in locale, dove quella variabile non serve a nulla. L'alternativa, un default hardcoded,
significherebbe registrare l'account ACME con un indirizzo scelto a caso.

Conseguenza: Let's Encrypt non manda avvisi di scadenza. Con il rinnovo automatico di Caddy quegli
avvisi non sono la rete di sicurezza che erano nel design a rinnovo manuale. Per attivarli si
aggiunge `email indirizzo@dominio` nel blocco globale del Caddyfile, con un valore reale.

### Overlay `docker-compose.staging.yml`

Con Caddy l'overlay non ha più nulla a che vedere con il TLS: serve solo a restringere la macchina
pubblica.

- `mariadb`, `redis`, `mailpit`, `meilisearch`: `ports: !reset []` — raggiungibili solo dalla rete
  Docker. Serve `!reset` perché il merge di Compose sulle liste è per concatenazione: `ports: []`
  da solo non rimuoverebbe nulla. Compose in uso è v5.1.4, il tag è supportato da v2.24.
- `php`: `XDEBUG_MODE: "off"`
- `MARIADB_ROOT_PASSWORD` da `.env`, non più il letterale `root` del compose base

### Laravel dietro TLS

In `../fipav-core/src/bootstrap/app.php`, dentro `withMiddleware`:

```php
$middleware->trustProxies(at: '*');
```

Senza questo Laravel ignora `X-Forwarded-Proto` e genera URL `http://` su pagine servite in
`https://`: Swagger UI, i redirect e `Storage::url()` produrrebbero mixed content, bloccato dal
browser. `at: '*'` è accettabile perché php-fpm non è raggiungibile dall'esterno: l'unico ingresso
è il gateway, sulla rete Docker interna.

## Aggiungere un comitato

```sh
# .env
GATEWAY_SITES=calabria… cosenza… lazio… roma… sicilia.fipav.altrama.it
```
```sh
docker compose up -d gateway
```

Caddy vede l'hostname nuovo, ottiene il certificato, inizia a servirlo. Il DNS non si tocca: il
record `A` wildcard copre già `sicilia.fipav.altrama.it`.

## Prerequisiti fuori dal repo

1. **Record `A` wildcard** `*.fipav.altrama.it` → IP della macchina, dallo Zone Editor cPanel.
   Una volta sola, copre tutti i comitati futuri.
2. **Porta 443 aperta.**
3. **Porta 80 aperta**, o almeno raggiungibile alla prima emissione. Caddy può poi validare via
   TLS-ALPN-01 sulla 443, ma la 80 serve anche per il redirect a https degli utenti che digitano
   l'URL senza schema.
4. **Nessun record `AAAA`** per questi nomi, o se c'è deve puntare alla stessa macchina: le CA
   preferiscono IPv6 quando esiste, e un AAAA orfano fa fallire la validazione in modo poco
   diagnosticabile.

## Verifica

### Non regressione del routing (in locale, prima di toccare lo staging)

Da eseguire con `GATEWAY_SITES=http://`, confrontando **i corpi** e non solo gli status code.

1. `curl -s http://localhost/core/api/documentation | grep -c '/core/docs/asset'` → > 0. Prova che
   `baseUrl=/core` è preservato.
2. `curl -s http://localhost/core/robots.txt | wc -c` → 24, non 0. Prova che `file_server` c'è.
3. `curl -s http://localhost/core/storage/<un-media-esistente> | wc -c` → la dimensione reale del
   file, non 0.
4. `curl -sI http://localhost/core/storage/<media> | grep -i access-control-allow-origin` → presente.
5. Un `.php` messo temporaneamente in `storage/app/public` → **404**, e il corpo non contiene il suo
   output. **È la verifica di sicurezza più importante di tutto il lavoro.** Da rimuovere subito
   dopo il test.
6. `curl -s -o /dev/null -w '%{http_code}' http://localhost/core/index.php` → 404.
7. `curl -s -o /dev/null -w '%{http_code}' http://localhost/core/.env` → 403 o 404, e mai il
   contenuto del file.
8. `curl -sI http://localhost/core` → 301 verso `/core/`.
9. `curl -s http://localhost/backoffice/ | grep -c 'src="/backoffice/'` → > 0: gli asset di Vite
   escono col prefisso.
10. `curl -s -H 'Host: calabria.localhost' http://localhost/ | head -c 200` → risposta del tenant
    `calabria`. Il routing multi-tenant sopravvive.
11. Modifica di un file in `fipav-backoffice/src` e in `fipav-comter-frontend/src` → HMR aggiorna
    il browser senza reload manuale. Verifica dei WebSocket attraverso Caddy.
12. `docker exec fipav-php php artisan migrate:status` → funziona: il gateway non è coinvolto, ma
    conferma che la sostituzione non ha toccato il resto dello stack.

### HTTPS (in staging)

13. `dig +short A calabria.fipav.altrama.it` e `dig +short A nome-inventato.fipav.altrama.it` → IP
    della macchina in entrambi i casi. Prova del wildcard.
14. `dig +short AAAA calabria.fipav.altrama.it` → vuoto.
15. Primo avvio con `GATEWAY_SITES` popolato → nei log di Caddy `certificate obtained successfully`
    per ogni hostname.
16. `curl -sI http://calabria.fipav.altrama.it/` → 301 verso `https://`.
17. `curl -sI https://calabria.fipav.altrama.it/core/api/documentation` → 200.
18. Lo stesso su un secondo nome (`cosenza…`) → 200, senza avvisi di certificato.
19. `openssl s_client -connect calabria.fipav.altrama.it:443 -servername cosenza.fipav.altrama.it`
    → catena valida.
20. Swagger UI in browser su https: asset caricati, "Try it out" funzionante, **nessun avviso di
    mixed content in console**. Verifica di `trustProxies`.
21. Aggiunto un hostname a `GATEWAY_SITES` e riavviato il gateway → certificato ottenuto senza
    altri interventi. Verifica del requisito operativo.
22. `docker compose down && docker compose up -d` → **nessuna riemissione** nei log: i certificati
    vengono riletti da `caddy-data`. Verifica che il volume sia montato bene, cioè che i rate limit
    non vengano bruciati a ogni deploy.
23. Da un'altra macchina, `nc -zv <ip> 3307` → connessione rifiutata (MariaDB non esposto).

## Esito dell'implementazione

I controlli di non regressione sono stati automatizzati in `make verify`, che ora ha 12 controlli
eseguibili (i 7 preesistenti più le 5 guardie del gateway) e il tredicesimo, l'HMR, che resta
manuale perché richiede un browser. **Tutti e 12 passano** con il gateway Caddy.

Le due verifiche che contano più delle altre:

- controllo 10, `.php` in `storage/` → `404`, codice non eseguito. È la guardia anti-RCE, l'unica
  che senza un test non darebbe nessun sintomo se si rompesse;
- controllo 9, media di storage serviti con l'header CORS → 1,5 MB e header presente.

Il Caddyfile è validato con `caddy validate` in entrambe le modalità. In modalità staging Caddy
conferma da sé `enabling automatic HTTP->HTTPS redirects`.

Lo staging non è verificabile finché non esiste il record `A` wildcard: senza DNS nessuna CA può
validare. I controlli 13-23 restano da eseguire sulla macchina.

### Bug preesistente trovato: il dev server Vite non era raggiungibile

Durante la verifica il controllo 4 (`/backoffice/`) rispondeva 502. **Non era causato dalla
migrazione**: da dentro la rete Docker `backoffice:3000` rifiutava la connessione mentre
`comter:3000` rispondeva 200, quindi nginx avrebbe fallito identicamente.

Causa: in `fipav-backoffice/vite.config.ts` il commit `f3594fc` ("fix vite docker") aveva
introdotto `inDocker` e `hmrClientPort` con i commenti che ne spiegano l'intento, ma non le aveva
mai collegate al blocco `server`. Entrambe erano dichiarate e mai usate, quindi Vite restava sul
default `localhost`: in ascolto solo dentro il container.

Correzione applicata, che completa quell'intento:

```js
server: {
  port: 3000,
  host: inDocker ? '0.0.0.0' : 'localhost',
  open: !inDocker,
  hmr: inDocker ? { clientPort: hmrClientPort } : true,
},
```

`open: !inDocker` risolve anche il `spawn xdg-open ENOENT` che Vite logga a ogni avvio in
container. Fuori da Docker il comportamento resta identico a prima.

## Insidie note

- **Le guardie non hanno un fallimento visibile.** Se il matcher `@uploaded_php` è scritto male, o
  finisce fuori dal blocco `route`, tutto continua a funzionare: l'unico sintomo è che diventa
  possibile eseguire codice caricato. Il test 5 non è opzionale.
- **L'ordine delle direttive in Caddy non è quello scritto** ma un ordine predefinito, a meno di
  racchiuderle in `route`. È il modo più facile di rendere inefficaci le guardie senza accorgersene.
- **200 con corpo vuoto** è la risposta di Caddy alle richieste non gestite: le verifiche sugli
  status code da sole danno falsi positivi.
- **Rate limit ACME**: 5 certificati a settimana per set di nomi. Il volume `caddy-data` e le prove
  con hostname veri vanno trattati con questo in mente.

## Fuori scope

- Certificato wildcard `*.fipav.altrama.it`: non serve più. Caddy emette per gli hostname elencati
  e aggiungerne uno è una riga nel `.env`. Resterebbe utile solo per non elencarli affatto, e
  richiederebbe DNS-01 con un'API DNS che Tophost non ha.
- `on_demand_tls` di Caddy, che emetterebbe alla prima richiesta senza elenco: richiede un endpoint
  di autorizzazione (`ask`), altrimenti è un vettore di abuso. Un componente in più per risparmiare
  una riga di `.env`.
- Configurazione di produzione (build ottimizzate, `next start`, Vite `build`). L'overlay aggiunge
  TLS a dei dev server, non li trasforma in un deploy di produzione.
- OCSP stapling, HSTS (Caddy non lo invia di default; da valutare a staging consolidato), HTTP/3
  (Caddy lo abilita da sé, ma non è un obiettivo di questo lavoro).
- Il servizio `nginx` legacy su `:8080`, che resta com'è: è un accesso di compatibilità a
  `fipav-core` con l'API su root, indipendente dal gateway.