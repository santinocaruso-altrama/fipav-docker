# Ambiente della macchina, incluso (`source`) dagli script dopo il `cd` nella
# root del repo. Stessa regola del Makefile: con .env.production presente lo
# stack e' docker-compose.production.yml, altrimenti base + overlay di stage.
#
# Il compose va sempre passato per intero: il solo docker-compose.yml base non
# e' valido da solo (php/horizon/backoffice/comter non hanno ne' `image` ne'
# `build`), e OGNI sottocomando fallirebbe, anche uno che tocca solo mariadb.
if [ -f .env.production ]; then
    ENV_FILE=.env.production
    COMPOSE=(docker compose --env-file .env.production -f docker-compose.production.yml)
    GATEWAY_DIR=docker/gateway/production
else
    ENV_FILE=.env.stage
    COMPOSE=(docker compose --env-file .env.stage -f docker-compose.yml -f docker-compose.stage.yml)
    GATEWAY_DIR=docker/gateway/stage
fi
