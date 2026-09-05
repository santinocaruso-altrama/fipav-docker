# Orchestratore unico dell'ecosistema FIPAV Online.
#
# Va eseguito da questa directory: il compose referenzia i tre progetti come
# sibling (../fipav-core, ../fipav-backoffice, ../fipav-comter-frontend).
#
# ATTENZIONE: non esiste (e non va aggiunto) nessun target che passi --volumes
# a `docker compose down`. I volumi mariadb-data e meilisearch-data sono
# dichiarati nel compose con `name:` pinnato al volume esistente, quindi
# `down -v` cancellerebbe il database camp2013 di lavoro. Per ripulire le
# dipendenze dei frontend c'e' `make fe-reset`, che tocca solo quei due volumi.
#
# ATTENZIONE: in staging, un `docker compose up -d comter` (o backoffice)
# lanciato a mano SENZA `-f docker-compose.stage.yml` ricrea il container
# con la definizione del file base: comter torna a girare `next dev` invece
# che la build di produzione, pubblicamente. Su una macchina di staging usa
# sempre `make` (i target qui sotto applicano l'overlay da soli tramite
# $(ACTIVE_COMPOSE)/$(STAGE)), oppure `docker compose $(STAGE) ...` a mano.

.PHONY: help \
       up up-dev down down-dev up-stage down-stage sync-sites build rebuild restart ps logs \
       logs-gateway logs-php logs-horizon logs-backoffice logs-comter logs-fe \
       install verify diagnose update pull \
       shell sh-backoffice sh-comter \
       artisan composer tinker mariadb redis-cli \
       migrate migrate-status migrate-fresh seed fresh \
       test test-filter swagger routes cache-clear \
       db-dump db-restore backup-db rotate-db-password \
       fe-reset

# Due file invece di un solo .env: un dev che lascia XDEBUG_MODE=debug e
# COMTER_ROOT_DOMAIN=localhost non deve toccare quei valori ogni volta che
# vuole provare lo stage, e viceversa. Entrambi vengono letti se presenti (una
# macchina reale ha solo uno dei due - dev sul Mac, stage sul server); se
# esistessero entrambi sulla stessa macchina, .env.stage vince sui valori in
# comune (ultimo -include letto). I ?= qui sotto riempiono solo i buchi.
#
# Il `touch` PRIMA degli -include (non dopo) crea i due file vuoti se mancano,
# cosi' `docker compose --env-file` piu' sotto non fallisce mai per file
# inesistente - a differenza del vecchio `.env` implicito, `--env-file`
# esplicito e' un errore fatale se il path non esiste, non un default silenzioso.
# Un file vuoto e' innocuo: i default restano quelli scritti in ${VAR:-...}
# nei compose. Al primo `make` di sempre non li -include ancora (appena
# creati, dopo questa riga): dalla seconda invocazione in poi si'.
$(shell touch .env.dev .env.stage)
-include .env.dev
-include .env.stage

# Quale file passare a `docker compose --env-file` dipende dal target: qui
# sotto solo le variabili Make (BASE, i controlli di up-stage, ...); i target
# che ricreano container (up-dev, up-stage, rebuild, install) passano il file
# giusto esplicitamente, perche' -include sopra non lo dice a `docker compose`.
ENV_FILE_DEV   := .env.dev
ENV_FILE_STAGE := .env.stage

GATEWAY_PORT          ?= 80
MAILPIT_UI_PORT       ?= 8025
MEILI_PORT            ?= 7700
MARIADB_USER          ?= fipav
MARIADB_PASSWORD      ?= fipav
MARIADB_ROOT_PASSWORD ?= root
# Default identico a quello del compose base: se non lo cambi in .env.stage
# resta "dev"/l'hash di "dev", pubblico in questo stesso repo - va bene solo
# in locale. up-stage lo rifiuta se e' rimasto questo, vedi piu' sotto.
HORIZON_BASIC_AUTH_USER ?= dev
HORIZON_BASIC_AUTH_HASH ?= $$2a$$14$$YEXcKLvdfMi/qhvCLpdECe2hvamqmVCBOi1gdIyfD7UHX4l2wzBFK

# Deve combaciare con `name:` in docker-compose.yml: e' il prefisso dei volumi.
PROJECT := fipavonline

# Gli overlay di ambiente vanno sempre applicati sopra il file base, mai da soli.
DEV   := -f docker-compose.yml -f docker-compose.dev.yml
STAGE := -f docker-compose.yml -f docker-compose.stage.yml

# I tre progetti sono repo git distinti, su branch distinti. Percorsi relativi
# perche' il compose li referenzia allo stesso modo (sibling di questa cartella).
REPOS := ../fipav-core ../fipav-backoffice ../fipav-comter-frontend

# Con la 80 l'URL va senza porta, ed e' il caso normale.
ifeq ($(GATEWAY_PORT),80)
BASE := http://localhost
else
BASE := http://localhost:$(GATEWAY_PORT)
endif

# Gli hostname serviti in staging non sono piu' in GATEWAY_SITES (rimossa):
# vivono in docker/gateway/stage/sites.conf, generato da scripts/sync-sites.sh
# da `tenants` (vedi quello script per i dettagli). Qui si legge lo stesso
# file, non il DB: sufficiente per BASE/verify/fe-reset, ed evita di
# duplicare la query per un semplice controllo locale a `make`.
STAGE_HOSTS := $(shell test -f docker/gateway/stage/sites.conf && grep -oE '^[a-zA-Z0-9.-]+ \{' docker/gateway/stage/sites.conf 2>/dev/null | sed 's/ {$$//')

# BASE va bene per `make up-dev` (Caddy in chiaro), ma appena sites.conf
# ha hostname Caddy attiva l'HTTPS automatico e reindirizza (308) ogni
# richiesta in chiaro: un curl su BASE non vedrebbe mai un 200. VERIFY_BASE e'
# quello che `verify` usa davvero: il primo hostname pubblico in HTTPS, quando
# ce n'e' uno; altrimenti BASE, invariato.
ifeq ($(STAGE_HOSTS),)
VERIFY_BASE := $(BASE)
else
VERIFY_BASE := https://$(firstword $(STAGE_HOSTS))
endif

# Quale ambiente e' "quello attivo" per i comandi che non ricreano container
# (exec, logs, ps, restart, ...): lo si deduce da COMTER_ROOT_DOMAIN, stesso
# segnale usato da sync-sites.sh. Da quando build:/Dockerfile sono per-ambiente
# (docker/php/dev vs stage, ...) la base docker-compose.yml da sola non basta
# piu' a validare - service "horizon"/"php"/"backoffice"/"comter" non hanno ne'
# image ne' build senza l'overlay - quindi ANCHE il caso dev deve passare
# esplicitamente $(DEV), non piu' lasciare i file impliciti.
ifeq ($(COMTER_ROOT_DOMAIN),)
ACTIVE_COMPOSE  := $(DEV)
ACTIVE_ENV_FILE := $(ENV_FILE_DEV)
ACTIVE_SUFFIX   := dev
else ifeq ($(COMTER_ROOT_DOMAIN),localhost)
ACTIVE_COMPOSE  := $(DEV)
ACTIVE_ENV_FILE := $(ENV_FILE_DEV)
ACTIVE_SUFFIX   := dev
else
ACTIVE_COMPOSE  := $(STAGE)
ACTIVE_ENV_FILE := $(ENV_FILE_STAGE)
ACTIVE_SUFFIX   := stage
endif

# `make` senza argomenti elenca i comandi. Esplicito e non posizionale: senza
# questo, il default sarebbe il primo target del file e basterebbe aggiungerne
# uno sopra per cambiare il comportamento senza accorgersene.
.DEFAULT_GOAL := help

# Colori
GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
CYAN   := \033[0;36m
RESET  := \033[0m

help: ## Mostra questo help
	@echo ""
	@echo "$(CYAN)FIPAV Online$(RESET) - stack unificato, comandi disponibili"
	@echo ""
	@# firstword e non MAKEFILE_LIST: gli `-include` sopra aggiungono .env.dev/
	@# .env.stage alla lista, e grep su piu' file prefissa ogni riga col nome
	@# del file, che awk prenderebbe come nome del target.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ─── Ciclo di vita ───────────────────────────────────────

up: up-dev ## Alias di `make up-dev`

up-dev: ## Avvia lo stack di sviluppo in background (docker-compose.yml + .dev.yml)
	docker compose --env-file $(ENV_FILE_DEV) $(DEV) up -d
	@echo ""
	@echo "$(GREEN)Stack avviato$(RESET)"
	@echo "  Comter (tenant):  $(BASE)/            (o calabria.localhost, *.localhost)"
	@echo "  Core (Laravel):   $(BASE)/core/"
	@echo "  Swagger:          $(BASE)/core/api/documentation"
	@echo "  Backoffice:       $(BASE)/backoffice/"
	@echo "  Mailpit:          http://localhost:$(MAILPIT_UI_PORT)"
	@echo "  Meilisearch:      http://localhost:$(MEILI_PORT)"
	@echo ""
	@echo "$(YELLOW)Al primo avvio$(RESET) i frontend installano le dipendenze nel volume:"
	@echo "  per qualche minuto rispondono 502. E' atteso. Segui l'avanzamento con:"
	@echo "  $(CYAN)make logs-fe$(RESET)"

down: down-dev ## Alias di `make down-dev`

down-dev: ## Ferma e rimuove i container (i volumi restano, DB salvo)
	docker compose --env-file $(ENV_FILE_DEV) $(DEV) down

up-stage: ## Avvia lo stack sulla macchina pubblica (HTTPS + porte chiuse)
	@# COMTER_API_BASE_URL e' una chiamata server-side dentro la rete Docker,
	@# quindi vuole hostname del container E schema. Senza schema comter fallisce
	@# a runtime con "Failed to parse URL" e ogni pagina risponde 500: un errore
	@# che si manifesta lontano dalla sua causa, quindi si intercetta qui.
	@case "$(COMTER_API_BASE_URL)" in \
	   ""|http://*|https://*) ;; \
	   *) echo ""; \
	      echo "$(RED)COMTER_API_BASE_URL non ha lo schema.$(RESET)  (valore: $(COMTER_API_BASE_URL))"; \
	      echo "E' l'URL che comter chiama server-side per l'API. Il default va bene"; \
	      echo "cosi' com'e' (usa COMTER_ROOT_DOMAIN da solo), sovrascrivilo solo se"; \
	      echo "serve un endpoint diverso, sempre con schema:"; \
	      echo ""; \
	      echo "  COMTER_API_BASE_URL=https://fipav.altrama.it/core/api/v1/public/cms"; \
	      echo ""; \
	      echo "Da non confondere con COMTER_ROOT_DOMAIN, che e' il dominio"; \
	      echo "pubblico senza schema (es. fipav.altrama.it)."; \
	      echo ""; \
	      exit 1;; \
	 esac
	@if [ "$(COMTER_ROOT_DOMAIN)" = "localhost" ]; then \
	   echo ""; \
	   echo "$(RED)COMTER_ROOT_DOMAIN e' ancora 'localhost'.$(RESET)"; \
	   echo "Da qui comter ricava il tenant dal sottodominio: lasciandolo cosi'"; \
	   echo "il confronto non matcha, scatta il fallback e OGNI hostname servirebbe"; \
	   echo "il tenant calabria. Il sintomo inganna, perche' calabria funziona."; \
	   echo "(e' anche il dominio con cui scripts/sync-sites.sh costruisce gli"; \
	   echo "hostname dei comitati: lasciato a 'localhost' il gateway non"; \
	   echo "servirebbe nessun sito in staging)"; \
	   echo ""; \
	   echo "  COMTER_ROOT_DOMAIN=fipav.altrama.it"; \
	   echo ""; \
	   exit 1; \
	 fi
	@# In produzione Meilisearch rifiuta di partire con una master key sotto i
	@# 16 byte: meglio bloccare qui, con le istruzioni, che ritrovarsi il
	@# container in crash loop. "masterKey" e' il default di sviluppo (vedi
	@# docker-compose.yml): se e' rimasto quello in staging non e' ne' segreto
	@# ne' abbastanza lungo.
	@key="$(MEILI_MASTER_KEY)"; \
	 if [ "$$key" = "masterKey" ] || [ $${#key} -lt 16 ]; then \
	   echo ""; \
	   echo "$(RED)MEILI_MASTER_KEY non e' impostata (o e' troppo corta/il default di sviluppo).$(RESET)"; \
	   echo "In produzione Meilisearch la richiede lunga almeno 16 byte, altrimenti"; \
	   echo "non parte. Nel .env.stage metti una chiave generata, ad esempio:"; \
	   echo ""; \
	   echo "  MEILI_MASTER_KEY=$$(openssl rand -base64 24)"; \
	   echo ""; \
	   exit 1; \
	 fi
	@# MARIADB_USER/PASSWORD qui e DB_USERNAME/DB_PASSWORD in fipav-core sono
	@# due copie indipendenti delle stesse credenziali (php si connette con
	@# quelle sue, non con queste): se divergono php perde silenziosamente la
	@# connessione al DB. Non controlla se fipav-core/.env non esiste ancora -
	@# e' un problema suo, non di questo stack.
	@core_env=../fipav-core/src/.env; \
	 if [ -f "$$core_env" ]; then \
	   core_user="$$(grep -E '^DB_USERNAME=' $$core_env | tail -n1 | cut -d= -f2-)"; \
	   core_pass="$$(grep -E '^DB_PASSWORD=' $$core_env | tail -n1 | cut -d= -f2-)"; \
	   if [ "$$core_user" != "$(MARIADB_USER)" ] || [ "$$core_pass" != "$(MARIADB_PASSWORD)" ]; then \
	     echo ""; \
	     echo "$(RED)Le credenziali DB non coincidono fra i due .env.$(RESET)"; \
	     echo "  fipav-docker/.env.stage MARIADB_USER=$(MARIADB_USER) MARIADB_PASSWORD=$(MARIADB_PASSWORD)"; \
	     echo "  fipav-core/src/.env     DB_USERNAME=$$core_user DB_PASSWORD=$$core_pass"; \
	     echo ""; \
	     echo "Sono due copie delle stesse credenziali: divergenti, php non"; \
	     echo "riesce a connettersi al DB. Allineale allo stesso valore in"; \
	     echo "entrambi i file."; \
	     echo ""; \
	     exit 1; \
	   fi; \
	 fi
	@# Stesso motivo di MEILI_MASTER_KEY: "dev"/l'hash di default sono pubblici
	@# in questo repo. Qui pesa doppio - vedi sotto, la stessa credenziale
	@# adesso protegge anche l'SMTP di Mailpit, non solo /core/horizon.
	@if [ "$(HORIZON_BASIC_AUTH_HASH)" = "$$2a$$14$$YEXcKLvdfMi/qhvCLpdECe2hvamqmVCBOi1gdIyfD7UHX4l2wzBFK" ]; then \
	   echo ""; \
	   echo "$(RED)HORIZON_BASIC_AUTH_HASH e' rimasto sul default di sviluppo.$(RESET)"; \
	   echo "E' l'hash di \"dev\", visibile a chiunque legga questo repo - protegge"; \
	   echo "sia /core/horizon sia l'SMTP di Mailpit (vedi sotto). Nel .env.stage:"; \
	   echo ""; \
	   echo "  HORIZON_BASIC_AUTH_USER=fipav"; \
	   echo "  HORIZON_BASIC_AUTH_HASH=\$$(docker run --rm caddy:alpine caddy hash-password --plaintext 'una-password')"; \
	   echo ""; \
	   exit 1; \
	 fi
	@# docker/mailpit/smtp-auth non si genera piu' a mano: stessa credenziale
	@# di Horizon (utente/hash sopra), riscritto solo se e' cambiato. Un file
	@# mancante qui monterebbe una DIRECTORY vuota al posto suo (bind mount di
	@# un path host inesistente) - per questo lo si scrive PRIMA di avviare
	@# mailpit, non dopo.
	@mkdir -p docker/mailpit
	@printf '%s:%s\n' "$(HORIZON_BASIC_AUTH_USER)" "$(HORIZON_BASIC_AUTH_HASH)" > docker/mailpit/smtp-auth.new
	@if ! cmp -s docker/mailpit/smtp-auth.new docker/mailpit/smtp-auth 2>/dev/null; then \
	   mv docker/mailpit/smtp-auth.new docker/mailpit/smtp-auth; \
	 else \
	   rm -f docker/mailpit/smtp-auth.new; \
	 fi
	@# mariadb prima di tutto il resto, e --wait fino a "healthy": sync-sites.sh
	@# subito dopo gli interroga `tenants`, e senza aspettare qui la prima
	@# esecuzione ci arriverebbe prima che il DB accetti connessioni.
	docker compose --env-file $(ENV_FILE_STAGE) $(STAGE) up -d --wait mariadb
	@# Scrive docker/gateway/stage/sites.conf PRIMA che il gateway esista: cosi'
	@# al suo primo avvio, qualche riga sotto, lo trova gia' pronto e non serve
	@# nessun reload. Se sono zero i comitati attivi lo script non fallisce (e'
	@# uno stato legittimo al primissimo giro, prima di importare i dati): il
	@# gateway parte comunque, semplicemente senza siti da servire finche' non
	@# lanci `make sync-sites` a dati importati.
	./scripts/sync-sites.sh
	docker compose --env-file $(ENV_FILE_STAGE) $(STAGE) up -d
	@echo ""
	@echo "$(GREEN)Stack di staging avviato$(RESET)"
	@# Rilegge il file ora, non $(STAGE_HOSTS): quella variabile e' valutata
	@# all'analisi del Makefile, PRIMA che sync-sites.sh lo riscrivesse sopra.
	@hosts="$$(grep -oE '^[a-zA-Z0-9.-]+ \{' docker/gateway/stage/sites.conf 2>/dev/null | sed 's/ {$$//' | tr '\n' ' ')"; \
	 if [ -n "$$hosts" ]; then \
	   echo "  Hostname serviti: $$hosts"; \
	 else \
	   echo "  $(YELLOW)Nessun hostname servito$(RESET): 0 comitati attivi in tenants."; \
	   echo "  Importa i dati poi rilancia $(CYAN)make sync-sites$(RESET)."; \
	 fi
	@echo ""
	@echo "$(YELLOW)Al primo avvio$(RESET) Caddy emette i certificati: cerca"
	@echo "  'certificate obtained successfully' nei log con $(CYAN)make logs-gateway$(RESET)"
	@echo "  Se falliscono, i prerequisiti sono il record A wildcard e le porte 80/443."

down-stage: ## Ferma lo stack di staging
	docker compose --env-file $(ENV_FILE_STAGE) $(STAGE) down

sync-sites: ## Riallinea gli hostname del gateway ai comitati attivi in DB (solo staging)
	./scripts/sync-sites.sh

build: ## Build delle immagini (php, backoffice, comter)
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) build

rebuild: ## Build senza cache e riavvio (stack di sviluppo)
	docker compose --env-file $(ENV_FILE_DEV) $(DEV) build --no-cache
	docker compose --env-file $(ENV_FILE_DEV) $(DEV) up -d

restart: ## Riavvia tutti i container
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) restart

ps: ## Stato dei container
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) ps

logs: ## Log di tutti i container (follow)
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) logs -f

logs-gateway: ## Log del gateway Caddy (routing e certificati)
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) logs -f gateway

logs-php: ## Log di php-fpm (fipav-core)
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) logs -f php

logs-horizon: ## Log del worker delle code (Horizon)
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) logs -f horizon

logs-backoffice: ## Log del dev server Vite
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) logs -f backoffice

logs-comter: ## Log del dev server Next
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) logs -f comter

logs-fe: ## Log dei due frontend insieme (utile al primo avvio)
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) logs -f backoffice comter

# ─── Setup e verifica ────────────────────────────────────

install: ## Setup iniziale completo (build, up, composer install, migrate)
	@echo "$(CYAN)Build delle immagini...$(RESET)"
	docker compose --env-file $(ENV_FILE_DEV) $(DEV) build
	@echo "$(CYAN)Avvio dello stack...$(RESET)"
	docker compose --env-file $(ENV_FILE_DEV) $(DEV) up -d
	@echo "$(CYAN)Dipendenze PHP...$(RESET)"
	docker compose --env-file $(ENV_FILE_DEV) $(DEV) exec php composer install
	@echo "$(CYAN)Migrazioni...$(RESET)"
	docker compose --env-file $(ENV_FILE_DEV) $(DEV) exec php php artisan migrate --force
	@echo "$(CYAN)Link dello storage pubblico...$(RESET)"
	docker compose --env-file $(ENV_FILE_DEV) $(DEV) exec php php artisan storage:link
	@echo ""
	@echo "$(GREEN)Setup completato.$(RESET) I frontend potrebbero essere ancora in install:"
	@echo "  $(CYAN)make logs-fe$(RESET) per seguirli, poi $(CYAN)make verify$(RESET)"

# `git pull` non basta a riallineare lo stack: il sorgente e' bind-mountato e
# quindi visibile subito, ma composer.json, le migrazioni e i lockfile dei
# frontend richiedono ciascuno un passo in piu'. `update` = pull + quei passi.
pull: ## Solo git pull sui tre progetti, senza toccare i container
	@for d in $(REPOS); do \
	  printf "  $(CYAN)%-24s$(RESET) " "$$(basename $$d)"; \
	  if [ ! -d "$$d/.git" ]; then \
	    printf "$(YELLOW)salto: non e' un repo git$(RESET)\n"; \
	  elif [ -n "$$(git -C $$d status --porcelain)" ]; then \
	    printf "$(YELLOW)salto: working tree sporco$(RESET)\n"; \
	  else \
	    printf "%-8s " "$$(git -C $$d branch --show-current)"; \
	    if git -C $$d pull --ff-only --quiet; then printf "$(GREEN)aggiornato$(RESET)\n"; \
	    else printf "$(RED)pull fallito$(RESET) (divergenza? serve un merge a mano)\n"; fi; \
	  fi; \
	done
	@# git-version.json per /core/version (VersionController): generato qui,
	@# non da un comando artisan, perche' .git sta nella root di fipav-core, un
	@# livello sopra src/ (l'unica parte bind-mountata nel container php) - da
	@# dentro il container .git e' irraggiungibile. deployed_at e' il momento di
	@# questo `make pull`/`make update`, non la data del commit: e' quello che
	@# risponde a "quando e' stato pubblicato", i due possono differire (un
	@# commit vecchio pullato solo ora).
	@if [ -d ../fipav-core/.git ]; then \
	  COMMIT=$$(git -C ../fipav-core rev-parse --short HEAD 2>/dev/null || echo unknown); \
	  COMMIT_FULL=$$(git -C ../fipav-core rev-parse HEAD 2>/dev/null || echo unknown); \
	  BRANCH=$$(git -C ../fipav-core rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown); \
	  TAG=$$(git -C ../fipav-core describe --tags --always 2>/dev/null || echo none); \
	  COMMIT_DATE=$$(git -C ../fipav-core log -1 --format=%cI 2>/dev/null || echo unknown); \
	  DEPLOYED_AT=$$(date +"%Y-%m-%dT%H:%M:%S%z"); \
	  printf '{\n  "commit": "%s",\n  "commit_full": "%s",\n  "branch": "%s",\n  "tag": "%s",\n  "commit_date": "%s",\n  "deployed_at": "%s"\n}\n' \
	    "$$COMMIT" "$$COMMIT_FULL" "$$BRANCH" "$$TAG" "$$COMMIT_DATE" "$$DEPLOYED_AT" \
	    > ../fipav-core/src/git-version.json; \
	fi

update: pull ## git pull sui tre progetti + composer, migrazioni e riavvio frontend
	@if [ -z "$$(docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) ps -q php)" ]; then \
	  echo ""; \
	  echo "$(YELLOW)Lo stack non e' in esecuzione:$(RESET) codice aggiornato, resto saltato."; \
	  echo "  Lancia $(CYAN)make up$(RESET) e poi di nuovo $(CYAN)make update$(RESET)."; \
	  exit 0; \
	fi; \
	echo ""; \
	echo "$(CYAN)Dipendenze PHP...$(RESET)"; \
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php composer install; \
	echo "$(CYAN)Migrazioni...$(RESET)"; \
	# --force: con APP_ENV=production Laravel chiede conferma interattiva \
	# (Application In Production), che qui non puo' arrivare - gira senza \
	# terminale attaccato. Senza, il comando si annulla da solo con un WARN \
	# in mezzo all'output, non un errore: passava inosservato, le \
	# migrazioni non giravano piu' da quando questa macchina e' passata a \
	# APP_ENV=production. \
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan migrate --force; \
	echo "$(CYAN)Cache di Laravel...$(RESET)"; \
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan config:clear; \
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan route:clear; \
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan cache:clear; \
	echo "$(CYAN)Riavvio del worker delle code...$(RESET)"; \
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec horizon php artisan horizon:terminate; \
	if [ "$(ACTIVE_SUFFIX)" = "stage" ]; then \
	  echo "$(CYAN)Ricostruzione dei frontend...$(RESET)"; \
	  echo "$(YELLOW)Attenzione:$(RESET) in staging l'immagine e' self-contained (build multi-"; \
	  echo "stage - vedi docker/backoffice/stage/Dockerfile e docker/comter/stage/"; \
	  echo "Dockerfile): un semplice restart girerebbe ancora il codice VECCHIO, quello"; \
	  echo "con cui l'immagine era stata costruita. Serve --build per rifarla dal"; \
	  echo "sorgente appena aggiornato da questo stesso 'pull'."; \
	  docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) up -d --build backoffice comter; \
	else \
	  echo "$(CYAN)Riavvio dei frontend...$(RESET)"; \
	  docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) restart backoffice comter; \
	fi; \
	echo ""; \
	if [ "$(ACTIVE_SUFFIX)" = "stage" ]; then \
	  echo "$(GREEN)Aggiornato.$(RESET) $(CYAN)make verify$(RESET) per controllare che sia andata."; \
	else \
	  echo "$(GREEN)Aggiornato.$(RESET) Gli entrypoint reinstallano le dipendenze solo se il"; \
	  echo "  lockfile e' cambiato; in quel caso l'install e' in corso adesso:"; \
	  echo "  $(CYAN)make logs-fe$(RESET), poi $(CYAN)make verify$(RESET)."; \
	fi

# I criteri di accettazione della spec (docs/superpowers/specs/
# 2026-07-29-docker-unificato-design.md), eseguibili. L'ottavo criterio (HMR)
# richiede un browser e resta manuale: qui viene solo ricordato.
verify: ## Esegue i criteri di accettazione della spec
	@echo ""
	@echo "$(CYAN)Verifica dello stack$(RESET)  ($(VERIFY_BASE))"
	@echo ""
	@printf "  %-56s" "1. comter risponde sulla root"
	@code=$$(curl -s -o /dev/null -w '%{http_code}' $(VERIFY_BASE)/); \
	 if [ "$$code" = "200" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	 else printf "$(RED)FALLITO$(RESET) (HTTP $$code)\n"; fi
	@printf "  %-56s" "2. Swagger risponde sotto /core/"
	@code=$$(curl -s -o /dev/null -w '%{http_code}' $(VERIFY_BASE)/core/api/documentation); \
	 if [ "$$code" = "200" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	 else printf "$(RED)FALLITO$(RESET) (HTTP $$code)\n"; fi
	@printf "  %-56s" "3. gli asset di Swagger hanno il prefisso /core/"
	@if curl -s $(VERIFY_BASE)/core/api/documentation | grep -qE '(src|href)="[^"]*/core/'; then \
	   printf "$(GREEN)OK$(RESET)  (SCRIPT_NAME attivo)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (URL generati verso /, SCRIPT_NAME non applicato)\n"; fi
	@printf "  %-56s" "4. il backoffice risponde sotto /backoffice/"
	@code=$$(curl -s -o /dev/null -w '%{http_code}' $(VERIFY_BASE)/backoffice/); \
	 if [ "$$code" = "200" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	 else printf "$(RED)FALLITO$(RESET) (HTTP $$code)\n"; fi
	@printf "  %-56s" "5. multi-tenant per sottodominio (calabria)"
	@if [ -n "$(STAGE_HOSTS)" ]; then \
	   second="$(word 2,$(STAGE_HOSTS))"; \
	   if [ -z "$$second" ]; then \
	     printf "$(YELLOW)SALTATO$(RESET)  (un solo hostname in docker/gateway/stage/sites.conf)\n"; \
	   else \
	     code=$$(curl -s -o /dev/null -w '%{http_code}' https://$$second/); \
	     if [ "$$code" = "200" ]; then printf "$(GREEN)OK$(RESET)  ($$second)\n"; \
	     else printf "$(RED)FALLITO$(RESET) (HTTP $$code su $$second)\n"; fi; \
	   fi; \
	 else \
	   code=$$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: calabria.localhost' $(VERIFY_BASE)/); \
	   if [ "$$code" = "200" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	   else printf "$(RED)FALLITO$(RESET) (HTTP $$code)\n"; fi; \
	 fi
	@printf "  %-56s" "6. il volume del DB e' quello preesistente"
	@if docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec -T php php artisan migrate:status 2>/dev/null | grep -q "Ran"; then \
	   printf "$(GREEN)OK$(RESET)  (camp2013 con le sue migrazioni)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (nessuna migrazione eseguita: volume ricreato vuoto?)\n"; fi
	@echo ""
	@echo "  $(CYAN)Guardie del gateway$(RESET)  (regressioni silenziose: nessuna si manifesta da sola)"
	@echo ""
	@# Caddy risponde 200 con corpo vuoto alle richieste che nessun handler
	@# gestisce, quindi questi controlli guardano i byte e non lo status code.
	@printf "  %-56s" "7. i file statici di public/ sono serviti"
	@n=$$(curl -s $(VERIFY_BASE)/core/robots.txt | wc -c | tr -d ' '); \
	 if [ "$$n" -gt 0 ]; then printf "$(GREEN)OK$(RESET)  (robots.txt, $$n byte)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (corpo vuoto: manca file_server nel Caddyfile?)\n"; fi
	@printf "  %-56s" "8. i media di storage/ sono serviti, con CORS"
	@f=$$(find ../fipav-core/src/storage/app/public -type f \( -name '*.jpg' -o -name '*.png' -o -name '*.webp' \) 2>/dev/null | head -1); \
	 if [ -z "$$f" ]; then printf "$(YELLOW)SALTATO$(RESET)  (nessun media in storage/app/public)\n"; \
	 else rel=$${f#*/storage/app/public/}; \
	   n=$$(curl -s "$(VERIFY_BASE)/core/storage/$$rel" | wc -c | tr -d ' '); \
	   cors=$$(curl -sI "$(VERIFY_BASE)/core/storage/$$rel" | grep -ci access-control-allow-origin); \
	   if [ "$$n" -gt 100 ] && [ "$$cors" -ge 1 ]; then printf "$(GREEN)OK$(RESET)  ($$n byte, CORS presente)\n"; \
	   else printf "$(RED)FALLITO$(RESET)  ($$n byte, header CORS trovati: $$cors)\n"; fi; fi
	@# La verifica di sicurezza piu' importante di tutto lo stack. storage/ e' la
	@# directory dei file caricati dagli utenti: se un .php finito qui viene
	@# eseguito, un upload diventa esecuzione di codice sul server.
	@# Il probe passa dal container (non dall'host): storage/app/public puo'
	@# non essere scrivibile dall'utente host che lancia `make verify` (UID
	@# diverso da quello con cui php-fpm scrive gli upload reali), e un
	@# "Permission denied" qui non deve leggersi come "il .php viene eseguito".
	@printf "  %-56s" "9. un .php in storage/ NON viene eseguito"
	@docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec -T php sh -c 'printf "<?php echo \"PROBE-ESEGUITO\";" > storage/app/public/__verify-probe.php'; \
	 body=$$(curl -s $(VERIFY_BASE)/core/storage/__verify-probe.php); \
	 code=$$(curl -s -o /dev/null -w '%{http_code}' $(VERIFY_BASE)/core/storage/__verify-probe.php); \
	 docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec -T php rm -f storage/app/public/__verify-probe.php; \
	 if [ "$$code" = "404" ] && ! echo "$$body" | grep -q PROBE-ESEGUITO; then \
	   printf "$(GREEN)OK$(RESET)  (404, codice non eseguito)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (HTTP $$code) $(RED)RISCHIO RCE$(RESET): un upload .php viene eseguito\n"; fi
	@printf "  %-56s" "10. /core/index.php non e' un entrypoint"
	@code=$$(curl -s -o /dev/null -w '%{http_code}' $(VERIFY_BASE)/core/index.php); \
	 if [ "$$code" = "404" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (HTTP $$code)\n"; fi
	@printf "  %-56s" "11. i dotfile non sono raggiungibili"
	@body=$$(curl -s $(VERIFY_BASE)/core/.env); \
	 code=$$(curl -s -o /dev/null -w '%{http_code}' $(VERIFY_BASE)/core/.env); \
	 if [ "$$code" != "200" ] && ! echo "$$body" | grep -q 'APP_KEY'; then \
	   printf "$(GREEN)OK$(RESET)  (HTTP $$code)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (HTTP $$code, contenuto raggiungibile)\n"; fi
	@echo ""
	@echo "  $(YELLOW)12. HMR$(RESET) - da verificare a mano: modifica un file in"
	@echo "     ../fipav-backoffice/src (e in ../fipav-comter-frontend/src) e"
	@echo "     controlla che il browser si aggiorni senza reload."
	@echo ""

# Isola disco/rete/applicativo quando il sito e' lento: curl con e senza uscire
# dalla macchina, docker stats, disco, MariaDB, Redis, piu' un riepilogo.
# Uso: make diagnose [domain=https://calabria.fipav.altrama.it/]
diagnose: ## Diagnostica lentezza (rete/disco/app) con riepilogo
	./scripts/diagnose.sh $(or $(domain),https://calabria.fipav.altrama.it/)

# ─── Shell ───────────────────────────────────────────────

shell: ## Shell bash nel container PHP
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php bash

sh-backoffice: ## Shell nel container del backoffice
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec backoffice sh

sh-comter: ## Shell nel container di comter
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec comter sh

# ─── fipav-core: CLI ─────────────────────────────────────
# Il Makefile di fipav-core non funziona mentre gira questo stack: i suoi
# `docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec` puntano al project fipav-core, che non e' su. I comandi
# quotidiani sono replicati qui con gli stessi nomi.

artisan: ## Esegue artisan (uso: make artisan cmd="migrate:status")
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan $(cmd)

composer: ## Esegue composer (uso: make composer cmd="require pkg/name")
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php composer $(cmd)

tinker: ## Apre il REPL Tinker
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan tinker

mariadb: ## Apre il client MariaDB su camp2013
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec mariadb mariadb -u$(MARIADB_USER) -p$(MARIADB_PASSWORD) camp2013

redis-cli: ## Apre il client Redis
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec redis redis-cli

migrate: ## Esegue le migrations
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan migrate

migrate-status: ## Mostra lo stato delle migrations
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan migrate:status

migrate-fresh: ## Drop di tutte le tabelle e riesegue le migrations
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan migrate:fresh

seed: ## Esegue i seeder
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan db:seed

fresh: ## Reset completo del DB (migrate:fresh + seed + swagger)
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan migrate:fresh
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan db:seed
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan openapi:generate

test: ## Esegue i test di fipav-core
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan test

test-filter: ## Test filtrati (uso: make test-filter f="NomeTest")
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan test --filter=$(f)

swagger: ## Rigenera la spec OpenAPI
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan openapi:generate
	@echo ""
	@echo "$(GREEN)Swagger UI:$(RESET) $(BASE)/core/api/documentation"

routes: ## Mostra le route API registrate
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan route:list --path=api

cache-clear: ## Pulisce tutta la cache di Laravel
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan config:clear
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan route:clear
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan view:clear
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec php php artisan cache:clear
	@echo "$(GREEN)Cache pulita$(RESET)"

db-dump: ## Dump di tutti i database (uso: make db-backups file=backup.sql)
	@echo "$(CYAN)Dump di tutti i database...$(RESET)"
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec mariadb mariadb-dump -uroot -p$(MARIADB_ROOT_PASSWORD) --databases camp2013 camp2003 corsi2016 live refertoelettronico vnl_ticketing > $(or $(file),dump_$$(date +%Y%m%d_%H%M%S).sql)
	@echo "$(GREEN)Dump salvato$(RESET)"

db-restore: ## Ripristina un backups SQL (uso: make db-restore file=backup.sql)
ifndef file
	$(error Specificare il file: make db-restore file=backup.sql)
endif
	@echo "$(CYAN)Ripristino da $(file)...$(RESET)"
	@# Identico a fipav-core/Makefile: i backups del DB legacy dichiarano le FK
	@# inline e in ordine arbitrario, quindi le righe CONSTRAINT vanno rimosse
	@# (col trailing comma della riga precedente) e i controlli disattivati,
	@# altrimenti il restore fallisce sulla prima tabella che referenzia una
	@# tabella non ancora creata.
	@# L'avanzamento e' approssimato: byte del backups gia' letti su byte totali
	@# (LC_ALL=C forza awk a contare byte, non caratteri - altrimenti gli
	@# accenti nei dati falserebbero il conteggio), non righe SQL eseguite sul
	@# server - un backups grande quanto letto non e' ancora detto scritto. Il
	@# nome tabella viene dalla riga INSERT INTO corrente: con un backups a un
	@# INSERT per tabella (mysqldump/mariadb-backups di default) e' l'intera
	@# tabella, non un batch parziale.
	@total=$$(wc -c < "$(file)" | tr -d ' '); \
	{ echo "SET FOREIGN_KEY_CHECKS=0;"; perl -ne 'if (/^\s*CONSTRAINT/) { $$prev =~ s/,\s*$$//; print $$prev; $$prev=""; } else { print $$prev if defined $$prev; $$prev=$$_; } END { print $$prev if defined $$prev }' "$(file)"; echo "SET FOREIGN_KEY_CHECKS=1;"; } \
	| LC_ALL=C awk -v total="$$total" '{ \
	    bytes += length($$0) + 1; \
	    if ($$1 == "INSERT" && $$2 == "INTO") { t = $$3; gsub(/`/, "", t); table = t; } \
	    pct = (total > 0) ? int(bytes * 100 / total) : 0; \
	    if (pct > 100) pct = 100; \
	    if (pct != last || table != ltable) { \
	      printf "\r[db-restore] %3d%%  %-40s", pct, table > "/dev/stderr"; \
	      last = pct; ltable = table; \
	    } \
	    print; \
	  } END { print "" > "/dev/stderr" }' \
	| docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) exec -T mariadb mariadb -uroot -p$(MARIADB_ROOT_PASSWORD) --force camp2013
	@echo "$(GREEN)Ripristino completato$(RESET)"

backup-db: ## Backup compresso di tutti i database, con rotazione (solo staging)
	./scripts/backup-db.sh

rotate-db-password: ## Ruota la password DB su un volume esistente (uso: make rotate-db-password [password=...])
	./scripts/rotate-db-password.sh $(password)

# ─── Dipendenze dei frontend ─────────────────────────────

# I node_modules vivono in volumi named che mascherano quelli dell'host
# (binari darwin-arm64). Quando si corrompono o il lockfile diverge, il modo
# pulito e' buttare i volumi e lasciare che gli entrypoint reinstallino.
# Tocca solo i due volumi dei frontend: mariadb-data non viene sfiorato.
fe-reset: ## Reinstalla da zero i node_modules dei due frontend
	@echo "$(CYAN)Rimozione dei container dei frontend...$(RESET)"
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) rm -sf backoffice comter
	@echo "$(CYAN)Rimozione dei volumi node_modules...$(RESET)"
	-docker volume rm $(PROJECT)_backoffice-node-modules-$(ACTIVE_SUFFIX)
	-docker volume rm $(PROJECT)_comter-node-modules-$(ACTIVE_SUFFIX)
	@echo "$(CYAN)Riavvio: gli entrypoint reinstallano le dipendenze...$(RESET)"
	docker compose --env-file $(ACTIVE_ENV_FILE) $(ACTIVE_COMPOSE) up -d backoffice comter
	@echo ""
ifeq ($(ACTIVE_SUFFIX),dev)
	@echo "$(GREEN)Fatto.$(RESET) L'install richiede qualche minuto: $(CYAN)make logs-fe$(RESET)"
else
	@echo "$(GREEN)Fatto$(RESET) (overlay di staging: comter rifa' la build di produzione)."
	@echo "Segui l'avanzamento con $(CYAN)make logs-comter$(RESET), poi verifica con $(CYAN)make verify$(RESET)."
endif