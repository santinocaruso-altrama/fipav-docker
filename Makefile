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
# lanciato a mano SENZA `-f docker-compose.staging.yml` ricrea il container
# con la definizione del file base: comter torna a girare `next dev` invece
# che la build di produzione, pubblicamente. Su una macchina di staging usa
# sempre `make` (i target qui sotto applicano l'overlay da soli tramite
# $(FE_COMPOSE)/$(STAGING)), oppure `docker compose $(STAGING) ...` a mano.

.PHONY: help \
       up down up-staging down-staging build rebuild restart ps logs \
       logs-gateway logs-php logs-horizon logs-backoffice logs-comter logs-fe \
       install verify diagnose update pull \
       shell sh-backoffice sh-comter \
       artisan composer tinker mariadb redis-cli \
       migrate migrate-status migrate-fresh seed fresh \
       test test-filter swagger routes cache-clear \
       db-dump db-restore \
       fe-reset

# Le porte reali arrivano dal .env del compose, se presente. I ?= qui sotto
# riempiono solo i buchi, quindi il .env vince sempre.
-include .env

GATEWAY_PORT     ?= 80
CORE_LEGACY_PORT ?= 8080
MAILPIT_UI_PORT  ?= 8025
MEILI_PORT       ?= 7700

# Deve combaciare con `name:` in docker-compose.yml: e' il prefisso dei volumi.
PROJECT := fipavonline

# L'overlay di staging va sempre applicato sopra il file base, mai da solo.
STAGING := -f docker-compose.yml -f docker-compose.staging.yml

# I tre progetti sono repo git distinti, su branch distinti. Percorsi relativi
# perche' il compose li referenzia allo stesso modo (sibling di questa cartella).
REPOS := ../fipav-core ../fipav-backoffice ../fipav-comter-frontend

# Con la 80 l'URL va senza porta, ed e' il caso normale.
ifeq ($(GATEWAY_PORT),80)
BASE := http://localhost
else
BASE := http://localhost:$(GATEWAY_PORT)
endif

# BASE va bene per `make up` (Caddy in chiaro), ma appena GATEWAY_SITES ha
# hostname pubblici Caddy attiva l'HTTPS automatico e reindirizza (308) ogni
# richiesta in chiaro: un curl su BASE non vedrebbe mai un 200. VERIFY_BASE e'
# quello che `verify` usa davvero: il primo hostname pubblico in HTTPS, quando
# GATEWAY_SITES e' configurato; altrimenti BASE, invariato.
ifeq ($(GATEWAY_SITES),)
VERIFY_BASE := $(BASE)
else ifeq ($(GATEWAY_SITES),http://)
VERIFY_BASE := $(BASE)
else
VERIFY_BASE := https://$(firstword $(GATEWAY_SITES))
endif

# Stessa euristica di sopra, per `fe-reset`: se GATEWAY_SITES ha hostname
# pubblici lo stack e' di staging, e backoffice/comter vanno rimessi su con
# l'overlay che monta la build di produzione, non con l'immagine base che
# lancerebbe i dev server su una macchina pubblica.
ifeq ($(GATEWAY_SITES),)
FE_COMPOSE :=
else ifeq ($(GATEWAY_SITES),http://)
FE_COMPOSE :=
else
FE_COMPOSE := $(STAGING)
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
	@# firstword e non MAKEFILE_LIST: l'`-include .env` sopra aggiunge .env alla
	@# lista, e grep su piu' file prefissa ogni riga col nome del file, che awk
	@# prenderebbe come nome del target.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ─── Ciclo di vita ───────────────────────────────────────

up: ## Avvia tutto lo stack in background
	docker compose up -d
	@echo ""
	@echo "$(GREEN)Stack avviato$(RESET)"
	@echo "  Comter (tenant):  $(BASE)/            (o calabria.localhost, *.localhost)"
	@echo "  Core (Laravel):   $(BASE)/core/"
	@echo "  Swagger:          $(BASE)/core/api/documentation"
	@echo "  Backoffice:       $(BASE)/backoffice/"
	@echo "  Core legacy:      http://localhost:$(CORE_LEGACY_PORT)/"
	@echo "  Mailpit:          http://localhost:$(MAILPIT_UI_PORT)"
	@echo "  Meilisearch:      http://localhost:$(MEILI_PORT)"
	@echo ""
	@echo "$(YELLOW)Al primo avvio$(RESET) i frontend installano le dipendenze nel volume:"
	@echo "  per qualche minuto rispondono 502. E' atteso. Segui l'avanzamento con:"
	@echo "  $(CYAN)make logs-fe$(RESET)"

down: ## Ferma e rimuove i container (i volumi restano, DB salvo)
	docker compose down

up-staging: ## Avvia lo stack sulla macchina pubblica (HTTPS + porte chiuse)
	@if [ "$(GATEWAY_SITES)" = "http://" ] || [ -z "$(GATEWAY_SITES)" ]; then \
	   echo ""; \
	   echo "$(RED)GATEWAY_SITES non e' impostato con hostname pubblici.$(RESET)"; \
	   echo "Con il valore attuale ($(GATEWAY_SITES)) Caddy servirebbe in chiaro"; \
	   echo "e non emetterebbe nessun certificato. Nel .env metti l'elenco:"; \
	   echo ""; \
	   echo "  GATEWAY_SITES=calabria.fipav.altrama.it cosenza.fipav.altrama.it"; \
	   echo ""; \
	   exit 1; \
	 fi
	@# COMTER_API_BASE_URL e' una chiamata server-side dentro la rete Docker,
	@# quindi vuole hostname del container E schema. Senza schema comter fallisce
	@# a runtime con "Failed to parse URL" e ogni pagina risponde 500: un errore
	@# che si manifesta lontano dalla sua causa, quindi si intercetta qui.
	@case "$(COMTER_API_BASE_URL)" in \
	   ""|http://*|https://*) ;; \
	   *) echo ""; \
	      echo "$(RED)COMTER_API_BASE_URL non ha lo schema.$(RESET)  (valore: $(COMTER_API_BASE_URL))"; \
	      echo "E' l'URL che comter chiama server-side, dentro la rete Docker:"; \
	      echo "vuole l'hostname del container, non il dominio pubblico."; \
	      echo ""; \
	      echo "  COMTER_API_BASE_URL=http://fipav-nginx/api/v1/public/cms"; \
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
	   echo ""; \
	   echo "  COMTER_ROOT_DOMAIN=fipav.altrama.it"; \
	   echo ""; \
	   exit 1; \
	 fi
	docker compose $(STAGING) up -d
	@echo ""
	@echo "$(GREEN)Stack di staging avviato$(RESET)"
	@echo "  Hostname serviti: $(GATEWAY_SITES)"
	@echo ""
	@echo "$(YELLOW)Al primo avvio$(RESET) Caddy emette i certificati: cerca"
	@echo "  'certificate obtained successfully' nei log con $(CYAN)make logs-gateway$(RESET)"
	@echo "  Se falliscono, i prerequisiti sono il record A wildcard e le porte 80/443."

down-staging: ## Ferma lo stack di staging
	docker compose $(STAGING) down

build: ## Build delle immagini (php, backoffice, comter)
	docker compose build

rebuild: ## Build senza cache e riavvio
	docker compose build --no-cache
	docker compose up -d

restart: ## Riavvia tutti i container
	docker compose restart

ps: ## Stato dei container
	docker compose ps

logs: ## Log di tutti i container (follow)
	docker compose logs -f

logs-gateway: ## Log del gateway Caddy (routing e certificati)
	docker compose logs -f gateway

logs-php: ## Log di php-fpm (fipav-core)
	docker compose logs -f php

logs-horizon: ## Log del worker delle code (Horizon)
	docker compose logs -f horizon

logs-backoffice: ## Log del dev server Vite
	docker compose logs -f backoffice

logs-comter: ## Log del dev server Next
	docker compose logs -f comter

logs-fe: ## Log dei due frontend insieme (utile al primo avvio)
	docker compose logs -f backoffice comter

# ─── Setup e verifica ────────────────────────────────────

install: ## Setup iniziale completo (build, up, composer install, migrate)
	@echo "$(CYAN)Build delle immagini...$(RESET)"
	docker compose build
	@echo "$(CYAN)Avvio dello stack...$(RESET)"
	docker compose up -d
	@echo "$(CYAN)Dipendenze PHP...$(RESET)"
	docker compose exec php composer install
	@echo "$(CYAN)Migrazioni...$(RESET)"
	docker compose exec php php artisan migrate --force
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
	@if [ -z "$$(docker compose ps -q php)" ]; then \
	  echo ""; \
	  echo "$(YELLOW)Lo stack non e' in esecuzione:$(RESET) codice aggiornato, resto saltato."; \
	  echo "  Lancia $(CYAN)make up$(RESET) e poi di nuovo $(CYAN)make update$(RESET)."; \
	  exit 0; \
	fi; \
	echo ""; \
	echo "$(CYAN)Dipendenze PHP...$(RESET)"; \
	docker compose exec php composer install; \
	echo "$(CYAN)Migrazioni...$(RESET)"; \
	# --force: con APP_ENV=production Laravel chiede conferma interattiva \
	# (Application In Production), che qui non puo' arrivare - gira senza \
	# terminale attaccato. Senza, il comando si annulla da solo con un WARN \
	# in mezzo all'output, non un errore: passava inosservato, le \
	# migrazioni non giravano piu' da quando questa macchina e' passata a \
	# APP_ENV=production. \
	docker compose exec php php artisan migrate --force; \
	echo "$(CYAN)Cache di Laravel...$(RESET)"; \
	docker compose exec php php artisan config:clear; \
	docker compose exec php php artisan route:clear; \
	echo "$(CYAN)Riavvio del worker delle code...$(RESET)"; \
	docker compose exec horizon php artisan horizon:terminate; \
	echo "$(CYAN)Riavvio dei frontend...$(RESET)"; \
	docker compose $(FE_COMPOSE) restart backoffice comter; \
	echo ""; \
	echo "$(GREEN)Aggiornato.$(RESET) Gli entrypoint reinstallano le dipendenze solo se il"; \
	echo "  lockfile e' cambiato; in quel caso l'install e' in corso adesso:"; \
	echo "  $(CYAN)make logs-fe$(RESET), poi $(CYAN)make verify$(RESET)."

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
	@printf "  %-56s" "5. compatibilita' legacy su :$(CORE_LEGACY_PORT)"
	@if [ -n "$(GATEWAY_SITES)" ] && [ "$(GATEWAY_SITES)" != "http://" ]; then \
	   printf "$(YELLOW)SALTATO$(RESET)  (porta non pubblicata in staging, per design)\n"; \
	 else \
	   code=$$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$(CORE_LEGACY_PORT)/api/documentation); \
	   if [ "$$code" = "200" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	   else printf "$(RED)FALLITO$(RESET) (HTTP $$code)\n"; fi; \
	 fi
	@printf "  %-56s" "6. multi-tenant per sottodominio (calabria)"
	@if [ -n "$(GATEWAY_SITES)" ] && [ "$(GATEWAY_SITES)" != "http://" ]; then \
	   second="$(word 2,$(GATEWAY_SITES))"; \
	   if [ -z "$$second" ]; then \
	     printf "$(YELLOW)SALTATO$(RESET)  (un solo hostname in GATEWAY_SITES)\n"; \
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
	@printf "  %-56s" "7. il volume del DB e' quello preesistente"
	@if docker compose exec -T php php artisan migrate:status 2>/dev/null | grep -q "Ran"; then \
	   printf "$(GREEN)OK$(RESET)  (camp2013 con le sue migrazioni)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (nessuna migrazione eseguita: volume ricreato vuoto?)\n"; fi
	@echo ""
	@echo "  $(CYAN)Guardie del gateway$(RESET)  (regressioni silenziose: nessuna si manifesta da sola)"
	@echo ""
	@# Caddy risponde 200 con corpo vuoto alle richieste che nessun handler
	@# gestisce, quindi questi controlli guardano i byte e non lo status code.
	@printf "  %-56s" "8. i file statici di public/ sono serviti"
	@n=$$(curl -s $(VERIFY_BASE)/core/robots.txt | wc -c | tr -d ' '); \
	 if [ "$$n" -gt 0 ]; then printf "$(GREEN)OK$(RESET)  (robots.txt, $$n byte)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (corpo vuoto: manca file_server nel Caddyfile?)\n"; fi
	@printf "  %-56s" "9. i media di storage/ sono serviti, con CORS"
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
	@printf "  %-56s" "10. un .php in storage/ NON viene eseguito"
	@docker compose exec -T php sh -c 'printf "<?php echo \"PROBE-ESEGUITO\";" > storage/app/public/__verify-probe.php'; \
	 body=$$(curl -s $(VERIFY_BASE)/core/storage/__verify-probe.php); \
	 code=$$(curl -s -o /dev/null -w '%{http_code}' $(VERIFY_BASE)/core/storage/__verify-probe.php); \
	 docker compose exec -T php rm -f storage/app/public/__verify-probe.php; \
	 if [ "$$code" = "404" ] && ! echo "$$body" | grep -q PROBE-ESEGUITO; then \
	   printf "$(GREEN)OK$(RESET)  (404, codice non eseguito)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (HTTP $$code) $(RED)RISCHIO RCE$(RESET): un upload .php viene eseguito\n"; fi
	@printf "  %-56s" "11. /core/index.php non e' un entrypoint"
	@code=$$(curl -s -o /dev/null -w '%{http_code}' $(VERIFY_BASE)/core/index.php); \
	 if [ "$$code" = "404" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (HTTP $$code)\n"; fi
	@printf "  %-56s" "12. i dotfile non sono raggiungibili"
	@body=$$(curl -s $(VERIFY_BASE)/core/.env); \
	 code=$$(curl -s -o /dev/null -w '%{http_code}' $(VERIFY_BASE)/core/.env); \
	 if [ "$$code" != "200" ] && ! echo "$$body" | grep -q 'APP_KEY'; then \
	   printf "$(GREEN)OK$(RESET)  (HTTP $$code)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (HTTP $$code, contenuto raggiungibile)\n"; fi
	@echo ""
	@echo "  $(YELLOW)13. HMR$(RESET) - da verificare a mano: modifica un file in"
	@echo "     ../fipav-backoffice/src (e in ../fipav-comter-frontend/src) e"
	@echo "     controlla che il browser si aggiorni senza reload."
	@echo ""

# Isola disco/rete/applicativo quando il sito e' lento: curl con e senza uscire
# dalla macchina, docker stats, disco, MariaDB, Redis, piu' un riepilogo.
# Uso: make diagnose [domain=https://calabria.fipav.altrama.it/]
diagnose: ## Diagnostica lentezza (rete/disco/app) con riepilogo
	./docker/diagnose.sh $(or $(domain),https://calabria.fipav.altrama.it/)

# ─── Shell ───────────────────────────────────────────────

shell: ## Shell bash nel container PHP
	docker compose exec php bash

sh-backoffice: ## Shell nel container del backoffice
	docker compose exec backoffice sh

sh-comter: ## Shell nel container di comter
	docker compose exec comter sh

# ─── fipav-core: CLI ─────────────────────────────────────
# Il Makefile di fipav-core non funziona mentre gira questo stack: i suoi
# `docker compose exec` puntano al project fipav-core, che non e' su. I comandi
# quotidiani sono replicati qui con gli stessi nomi.

artisan: ## Esegue artisan (uso: make artisan cmd="migrate:status")
	docker compose exec php php artisan $(cmd)

composer: ## Esegue composer (uso: make composer cmd="require pkg/name")
	docker compose exec php composer $(cmd)

tinker: ## Apre il REPL Tinker
	docker compose exec php php artisan tinker

mariadb: ## Apre il client MariaDB su camp2013
	docker compose exec mariadb mariadb -ufipav -pfipav camp2013

redis-cli: ## Apre il client Redis
	docker compose exec redis redis-cli

migrate: ## Esegue le migrations
	docker compose exec php php artisan migrate

migrate-status: ## Mostra lo stato delle migrations
	docker compose exec php php artisan migrate:status

migrate-fresh: ## Drop di tutte le tabelle e riesegue le migrations
	docker compose exec php php artisan migrate:fresh

seed: ## Esegue i seeder
	docker compose exec php php artisan db:seed

fresh: ## Reset completo del DB (migrate:fresh + seed + swagger)
	docker compose exec php php artisan migrate:fresh
	docker compose exec php php artisan db:seed
	docker compose exec php php artisan openapi:generate

test: ## Esegue i test di fipav-core
	docker compose exec php php artisan test

test-filter: ## Test filtrati (uso: make test-filter f="NomeTest")
	docker compose exec php php artisan test --filter=$(f)

swagger: ## Rigenera la spec OpenAPI
	docker compose exec php php artisan openapi:generate
	@echo ""
	@echo "$(GREEN)Swagger UI:$(RESET) $(BASE)/core/api/documentation"

routes: ## Mostra le route API registrate
	docker compose exec php php artisan route:list --path=api

cache-clear: ## Pulisce tutta la cache di Laravel
	docker compose exec php php artisan config:clear
	docker compose exec php php artisan route:clear
	docker compose exec php php artisan view:clear
	docker compose exec php php artisan cache:clear
	@echo "$(GREEN)Cache pulita$(RESET)"

db-dump: ## Dump di tutti i database (uso: make db-dump file=backup.sql)
	@echo "$(CYAN)Dump di tutti i database...$(RESET)"
	docker compose exec mariadb mariadb-dump -uroot -proot --databases camp2013 camp2003 corsi2016 live refertoelettronico vnl_ticketing > $(or $(file),dump_$$(date +%Y%m%d_%H%M%S).sql)
	@echo "$(GREEN)Dump salvato$(RESET)"

db-restore: ## Ripristina un dump SQL (uso: make db-restore file=backup.sql)
ifndef file
	$(error Specificare il file: make db-restore file=backup.sql)
endif
	@echo "$(CYAN)Ripristino da $(file)...$(RESET)"
	@# Identico a fipav-core/Makefile: i dump del DB legacy dichiarano le FK
	@# inline e in ordine arbitrario, quindi le righe CONSTRAINT vanno rimosse
	@# (col trailing comma della riga precedente) e i controlli disattivati,
	@# altrimenti il restore fallisce sulla prima tabella che referenzia una
	@# tabella non ancora creata.
	{ echo "SET FOREIGN_KEY_CHECKS=0;"; perl -ne 'if (/^\s*CONSTRAINT/) { $$prev =~ s/,\s*$$//; print $$prev; $$prev=""; } else { print $$prev if defined $$prev; $$prev=$$_; } END { print $$prev if defined $$prev }' $(file); echo "SET FOREIGN_KEY_CHECKS=1;"; } | docker compose exec -T mariadb mariadb -uroot -proot --force camp2013
	@echo "$(GREEN)Ripristino completato$(RESET)"

# ─── Dipendenze dei frontend ─────────────────────────────

# I node_modules vivono in volumi named che mascherano quelli dell'host
# (binari darwin-arm64). Quando si corrompono o il lockfile diverge, il modo
# pulito e' buttare i volumi e lasciare che gli entrypoint reinstallino.
# Tocca solo i due volumi dei frontend: mariadb-data non viene sfiorato.
fe-reset: ## Reinstalla da zero i node_modules dei due frontend
	@echo "$(CYAN)Rimozione dei container dei frontend...$(RESET)"
	docker compose $(FE_COMPOSE) rm -sf backoffice comter
	@echo "$(CYAN)Rimozione dei volumi node_modules...$(RESET)"
	-docker volume rm $(PROJECT)_backoffice-node-modules
	-docker volume rm $(PROJECT)_comter-node-modules
	@echo "$(CYAN)Riavvio: gli entrypoint reinstallano le dipendenze...$(RESET)"
	docker compose $(FE_COMPOSE) up -d backoffice comter
	@echo ""
ifeq ($(FE_COMPOSE),)
	@echo "$(GREEN)Fatto.$(RESET) L'install richiede qualche minuto: $(CYAN)make logs-fe$(RESET)"
else
	@echo "$(GREEN)Fatto$(RESET) (overlay di staging: comter rifa' la build di produzione)."
	@echo "Segui l'avanzamento con $(CYAN)make logs-comter$(RESET), poi verifica con $(CYAN)make verify$(RESET)."
endif