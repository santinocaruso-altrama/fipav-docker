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

.PHONY: help \
       up down up-staging down-staging build rebuild restart ps logs \
       logs-gateway logs-php logs-backoffice logs-comter logs-fe \
       install verify update pull \
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
	docker compose exec php php artisan migrate
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
	docker compose exec php php artisan migrate; \
	echo "$(CYAN)Cache di Laravel...$(RESET)"; \
	docker compose exec php php artisan config:clear; \
	docker compose exec php php artisan route:clear; \
	echo "$(CYAN)Riavvio dei frontend...$(RESET)"; \
	docker compose restart backoffice comter; \
	echo ""; \
	echo "$(GREEN)Aggiornato.$(RESET) Gli entrypoint reinstallano le dipendenze solo se il"; \
	echo "  lockfile e' cambiato; in quel caso l'install e' in corso adesso:"; \
	echo "  $(CYAN)make logs-fe$(RESET), poi $(CYAN)make verify$(RESET)."

# I criteri di accettazione della spec (docs/superpowers/specs/
# 2026-07-29-docker-unificato-design.md), eseguibili. L'ottavo criterio (HMR)
# richiede un browser e resta manuale: qui viene solo ricordato.
verify: ## Esegue i criteri di accettazione della spec
	@echo ""
	@echo "$(CYAN)Verifica dello stack$(RESET)  ($(BASE))"
	@echo ""
	@printf "  %-56s" "1. comter risponde sulla root"
	@code=$$(curl -s -o /dev/null -w '%{http_code}' $(BASE)/); \
	 if [ "$$code" = "200" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	 else printf "$(RED)FALLITO$(RESET) (HTTP $$code)\n"; fi
	@printf "  %-56s" "2. Swagger risponde sotto /core/"
	@code=$$(curl -s -o /dev/null -w '%{http_code}' $(BASE)/core/api/documentation); \
	 if [ "$$code" = "200" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	 else printf "$(RED)FALLITO$(RESET) (HTTP $$code)\n"; fi
	@printf "  %-56s" "3. gli asset di Swagger hanno il prefisso /core/"
	@if curl -s $(BASE)/core/api/documentation | grep -qE '(src|href)="[^"]*/core/'; then \
	   printf "$(GREEN)OK$(RESET)  (SCRIPT_NAME attivo)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (URL generati verso /, SCRIPT_NAME non applicato)\n"; fi
	@printf "  %-56s" "4. il backoffice risponde sotto /backoffice/"
	@code=$$(curl -s -o /dev/null -w '%{http_code}' $(BASE)/backoffice/); \
	 if [ "$$code" = "200" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	 else printf "$(RED)FALLITO$(RESET) (HTTP $$code)\n"; fi
	@printf "  %-56s" "5. compatibilita' legacy su :$(CORE_LEGACY_PORT)"
	@code=$$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$(CORE_LEGACY_PORT)/api/documentation); \
	 if [ "$$code" = "200" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	 else printf "$(RED)FALLITO$(RESET) (HTTP $$code)\n"; fi
	@printf "  %-56s" "6. multi-tenant per sottodominio (calabria)"
	@code=$$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: calabria.localhost' $(BASE)/); \
	 if [ "$$code" = "200" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	 else printf "$(RED)FALLITO$(RESET) (HTTP $$code)\n"; fi
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
	@n=$$(curl -s $(BASE)/core/robots.txt | wc -c | tr -d ' '); \
	 if [ "$$n" -gt 0 ]; then printf "$(GREEN)OK$(RESET)  (robots.txt, $$n byte)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (corpo vuoto: manca file_server nel Caddyfile?)\n"; fi
	@printf "  %-56s" "9. i media di storage/ sono serviti, con CORS"
	@f=$$(find ../fipav-core/src/storage/app/public -type f \( -name '*.jpg' -o -name '*.png' -o -name '*.webp' \) 2>/dev/null | head -1); \
	 if [ -z "$$f" ]; then printf "$(YELLOW)SALTATO$(RESET)  (nessun media in storage/app/public)\n"; \
	 else rel=$${f#*/storage/app/public/}; \
	   n=$$(curl -s "$(BASE)/core/storage/$$rel" | wc -c | tr -d ' '); \
	   cors=$$(curl -sI "$(BASE)/core/storage/$$rel" | grep -ci access-control-allow-origin); \
	   if [ "$$n" -gt 100 ] && [ "$$cors" -ge 1 ]; then printf "$(GREEN)OK$(RESET)  ($$n byte, CORS presente)\n"; \
	   else printf "$(RED)FALLITO$(RESET)  ($$n byte, header CORS trovati: $$cors)\n"; fi; fi
	@# La verifica di sicurezza piu' importante di tutto lo stack. storage/ e' la
	@# directory dei file caricati dagli utenti: se un .php finito qui viene
	@# eseguito, un upload diventa esecuzione di codice sul server.
	@printf "  %-56s" "10. un .php in storage/ NON viene eseguito"
	@probe=../fipav-core/src/storage/app/public/__verify-probe.php; \
	 printf '<?php echo "PROBE-ESEGUITO";' > $$probe; \
	 body=$$(curl -s $(BASE)/core/storage/__verify-probe.php); \
	 code=$$(curl -s -o /dev/null -w '%{http_code}' $(BASE)/core/storage/__verify-probe.php); \
	 rm -f $$probe; \
	 if [ "$$code" = "404" ] && ! echo "$$body" | grep -q PROBE-ESEGUITO; then \
	   printf "$(GREEN)OK$(RESET)  (404, codice non eseguito)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (HTTP $$code) $(RED)RISCHIO RCE$(RESET): un upload .php viene eseguito\n"; fi
	@printf "  %-56s" "11. /core/index.php non e' un entrypoint"
	@code=$$(curl -s -o /dev/null -w '%{http_code}' $(BASE)/core/index.php); \
	 if [ "$$code" = "404" ]; then printf "$(GREEN)OK$(RESET)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (HTTP $$code)\n"; fi
	@printf "  %-56s" "12. i dotfile non sono raggiungibili"
	@body=$$(curl -s $(BASE)/core/.env); \
	 code=$$(curl -s -o /dev/null -w '%{http_code}' $(BASE)/core/.env); \
	 if [ "$$code" != "200" ] && ! echo "$$body" | grep -q 'APP_KEY'; then \
	   printf "$(GREEN)OK$(RESET)  (HTTP $$code)\n"; \
	 else printf "$(RED)FALLITO$(RESET)  (HTTP $$code, contenuto raggiungibile)\n"; fi
	@echo ""
	@echo "  $(YELLOW)13. HMR$(RESET) - da verificare a mano: modifica un file in"
	@echo "     ../fipav-backoffice/src (e in ../fipav-comter-frontend/src) e"
	@echo "     controlla che il browser si aggiorni senza reload."
	@echo ""

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
	docker compose rm -sf backoffice comter
	@echo "$(CYAN)Rimozione dei volumi node_modules...$(RESET)"
	-docker volume rm $(PROJECT)_backoffice-node-modules
	-docker volume rm $(PROJECT)_comter-node-modules
	@echo "$(CYAN)Riavvio: gli entrypoint reinstallano le dipendenze...$(RESET)"
	docker compose up -d backoffice comter
	@echo ""
	@echo "$(GREEN)Fatto.$(RESET) L'install richiede qualche minuto: $(CYAN)make logs-fe$(RESET)"