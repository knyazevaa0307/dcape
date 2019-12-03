# dcape Makefile
SHELL             = /bin/bash
CFG               = .env
CFG_BAK          ?= $(CFG).bak
DCAPE_USED        = 1

TZ               ?= $(shell cat /etc/timezone)
DCINC             = docker-compose.inc.yml

# check this files for update docker-compose.yml
DCFILES           = $(shell find apps/ -name $(DCINC) -print | sort)

PROJECT_NAME     ?= dcape
DOMAIN           ?= dev.lan
APPS_SYS         ?= db
APPS             ?= traefik portainer enfist cis

# Postgresql Database image
PG_IMAGE         ?= postgres:12.1-alpine
# Postgresql Database superuser password
PG_DB_PASS       ?= $(shell < /dev/urandom tr -dc A-Za-z0-9 2>/dev/null | head -c14; echo)
# Postgresql Database encoding
PG_ENCODING      ?= en_US.UTF-8
# port on localhost postgresql listen on
PG_PORT_LOCAL    ?= 5433
# Dump name suffix to load on db-create
PG_SOURCE_SUFFIX ?=

# Docker-compose image tag
DC_VER           ?= 1.23.2

# Config store url
ENFIST_URL       ?= http://enfist:8080/rpc

# ------------------------------------------------------------------------------

define CONFIG_DEF
# dcape config file, generated by make $(CFG)

# General settings

# containers name prefix
PROJECT_NAME=$(PROJECT_NAME)

# Default domain
DOMAIN=$(DOMAIN)

# App list, for use in make only
APPS="$(shell echo $(APPS))"

# create db cluster with this timezone
# (also used by gitea container)
TZ=$(TZ)

# Postgresql Database image
PG_IMAGE=$(PG_IMAGE)
# Postgresql Database superuser password
PG_DB_PASS=$(PG_DB_PASS)
# Postgresql Database encoding
PG_ENCODING=$(PG_ENCODING)
# port on localhost postgresql listen on
PG_PORT_LOCAL=$(PG_PORT_LOCAL)

endef
export CONFIG_DEF

# ------------------------------------------------------------------------------

# if exists - load old values
-include $(CFG_BAK)
export

-include $(CFG)
export

.PHONY: deps init-master init-slave init-local init apply up reup down dc db-create db-drop env-get env-set help

# ------------------------------------------------------------------------------

all: help

include apps/*/Makefile

## установка зависимостей
deps:
	@echo "*** $@ ***"
	@sudo apt-get update && sudo apt-get install -y \
	  gawk wget curl apache2-utils openssh-client docker-engine

## Init internet server with gitea and personal letsencrypt cert for all apps (redirect http to https)
init-master-prod: APPS = traefik-acme gitea portainer enfist cis
init-master-prod: init

## Init internet server without gitea and personal letsencrypt cert for all apps (redirect http to https)
init-slave-prod: APPS = traefik-acme portainer enfist cis
init-slave-prod: init

## Init internet server with gitea and ssl for build-in apps (redirect http to https)
init-master-dev: APPS = traefik-acme-dev gitea portainer enfist cis
init-master-dev: init

## Init internet server without gitea and ssl for built-in apps (redirect http to https)
init-slave-dev: APPS = traefik-acme-dev portainer enfist cis
init-slave-dev: init

## Init internet server with gitea and one woldcards cert for all apps (redirect http to https)
init-master-wild: APPS = traefik-acme-wild gitea portainer enfist cis
init-master-wild: init

## Init internet server without gitea and one wildcards cert for all apps (redirect http to https)
init-slave-wild: APPS = traefik-acme-wild portainer enfist cis
init-slave-wild: init

## Init local server
init-local: APPS = traefik gitea portainer enfist cis
init-local: init


## Initially create .enc file with defaults
init:
	@echo "*** $@ $(APPS) ***"
	@[ -d var/data ] || mkdir -p var/data
	@[ -f .env ] && { echo ".env already exists. Skipping" ; exit 1 ; } || true
	@echo "$$CONFIG_DEF" > .env
	@for f in $(shell echo $(APPS)) ; do echo $$f ; $(MAKE) -s $${f}-init ; done

## Apply config to app files & db
apply:
	@echo "*** $@ $(APPS) ***"
	@$(MAKE) -s dc CMD="up -d $(APPS_SYS)" || echo ""
	@for f in $(shell echo $(APPS)) ; do $(MAKE) -s $${f}-apply ; done

# Upgrade postgres major version with pg_upgrade
pg_upgrade:
	@echo "*** $@ *** " ; \
	DCAPE_DB=$${PROJECT_NAME}_db_1 ; \
	PG_OLD=`cat ./var/data/db/PG_VERSION` ; \
	PG_NEW=`docker inspect --type=image $$PG_IMAGE | jq -r '.[0].ContainerConfig.Env[] | capture("PG_MAJOR=(?<a>.+)") | .a'`  ; \
	echo "*** $@ *** from $$PG_OLD to $$PG_NEW" ; \
	echo -n "Checking PG is down..." ; \
	if [[ `docker inspect -f "{{.State.Running}}" $$DCAPE_DB 2>/dev/null` == true ]] ; then \
		echo "Postgres container not stop. Exit" && exit 1 ; \
	else \
		echo "Postgres container not run. Continue" ; \
	fi ; \
	echo "Move current postgres data directory to ./var/data/db_$$PG_OLD" ; \
	mkdir ./var/data/db_$$PG_OLD ; \
	mv ./var/data/db/* ./var/data/db_$$PG_OLD/ ; \
	cp ./var/data/db_$$PG_OLD/postgresql.conf ./var/data/db_$$PG_OLD/postgresql_store.conf ; \
	sed -i "s%include_dir = '/opt/conf.d'%#include_dir = '/opt/conf.d'%" ./var/data/db_$$PG_OLD/postgresql.conf ; \
	docker pull tianon/postgres-upgrade:$$PG_OLD-to-$$PG_NEW ; \
	docker run --rm \
    	-v $$PWD/var/data/db_$$PG_OLD:/var/lib/postgresql/$$PG_OLD/data \
    	-v $$PWD/var/data/db:/var/lib/postgresql/$$PG_NEW/data \
    	tianon/postgres-upgrade:$$PG_OLD-to-$$PG_NEW ; \
	cp -f ./var/data/db_$$PG_OLD/pg_hba.conf ./var/data/db/pg_hba.conf ; \
	cp -f ./var/data/db_$$PG_OLD/postgresql_store.conf ./var/data/db/postgresql.conf ; \
	echo "If the process succeeds, edit pg_hba.conf, other conf and start postgres container or dcape. \
   		For more info see https://github.com/dopos/dcape/blob/master/POSTGRES.md"

# Upgrade postgres major version with pg_dumpall-psql
# Create dump for claster Postgres
pg_dumpall:
	@echo "Start $@ to pg_dumpall_$${PROJECT_NAME}_`date +"%d.%m.%Y"`.sql.gz" ;\
	DCAPE_DB=$${PROJECT_NAME}_db_1 ; \
	docker exec -u postgres $$DCAPE_DB pg_dumpall | gzip -7 -c > \
		./var/data/db-backup/pg_dumpall_$${PROJECT_NAME}_`date +"%d.%m.%Y"`.sql.gz

# Load dump for claster Postgres
pg_load_dumpall:
	@echo "Start $@ ..." ; \
	echo "Load dump file: pg_dumpall_$${PROJECT_NAME}_`date +"%d.%m.%Y"`.sql.gz" ;\
	docker exec -u postgres -e PROJECT_NAME=$${PROJECT_NAME} $${PROJECT_NAME}_db_1 \
		bash -c 'zcat /opt/backup/pg_dumpall_$${PROJECT_NAME}_`date +"$d.%m.%Y"`.sql.gz | psql' ; \
	echo "Load dump complete. Start databases ANALYZE." ; \
	docker exec -u postgres $${PROJECT_NAME}_db_1 psql -c "ANALYZE" && \
		echo "ANALYZE complete."

# build file from app templates
docker-compose.yml: $(DCINC) $(DCFILES)
	@echo "*** $@ ***"
	@echo "# WARNING! This file was generated by make. DO NOT EDIT" > $@
	@cat $(DCINC) >> $@
	@for f in $(shell echo $(APPS)) ; do cat apps/$$f/$(DCINC) >> $@ ; done

## старт контейнеров
up:
up: CMD=up -d $(APPS_SYS) $(shell echo $(APPS))
up: dc

## рестарт контейнеров
reup:
reup: CMD=up --force-recreate -d $(APPS_SYS) $(shell echo $(APPS))
reup: dc

## остановка и удаление всех контейнеров
down:
down: CMD=down
down: dc

## separate start of traefik in the interactive mode, is used for get wild cert
## for manual provider and DNS challenge (not use vars for manual provider)
wild: 
wild: CMD=run --rm traefik-acme-wild
wild: dc

# ------------------------------------------------------------------------------

# $$PWD используется для того, чтобы текущий каталог был доступен в контейнере по тому же пути
# и относительные тома новых контейнеров могли его использовать
## run docker-compose
dc: docker-compose.yml
	@docker run --rm -t -i \
	  -v /var/run/docker.sock:/var/run/docker.sock \
	  -v $$PWD:$$PWD \
	  -w $$PWD \
	  docker/compose:$(DC_VER) \
	  -p $$PROJECT_NAME \
	  $(CMD)

# ------------------------------------------------------------------------------

# Wait for postgresql container start
docker-wait:
	@echo -n "Checking PG is ready..." ; \
	DCAPE_DB=$${PROJECT_NAME}_db_1 ; \
	until [[ `docker inspect -f "{{.State.Health.Status}}" $$DCAPE_DB` == healthy ]] ; do sleep 1 ; echo -n "." ; done
	@echo "Ok"

# Database import script
# DCAPE_DB_DUMP_DEST must be set in pg container

define IMPORT_SCRIPT
[[ "$$DCAPE_DB_DUMP_DEST" ]] || { echo "DCAPE_DB_DUMP_DEST not set. Exiting" ; exit 1 ; } ; \
DB_NAME="$$1" ; DB_USER="$$2" ; DB_PASS="$$3" ; DB_SOURCE="$$4" ; \
dbsrc=$$DCAPE_DB_DUMP_DEST/$$DB_SOURCE.tgz ; \
if [ -f $$dbsrc ] ; then \
  echo "Dump file $$dbsrc found, restoring database..." ; \
  zcat $$dbsrc | PGPASSWORD=$$DB_PASS pg_restore -h localhost -U $$DB_USER -O -Ft -d $$DB_NAME || exit 1 ; \
else \
  echo "Dump file $$dbsrc not found" ; \
  exit 2 ; \
fi
endef
export IMPORT_SCRIPT

## create database and user
db-create: docker-wait
	@echo "*** $@ ***" \
	&& varname=$(NAME)_DB_PASS && pass=$${!varname} \
	&& varname=$(NAME)_DB_TAG && dbname=$${!varname} \
	&& DCAPE_DB=$${PROJECT_NAME}_db_1 \
	&& docker exec -i $$DCAPE_DB psql -U postgres -c "CREATE USER \"$$dbname\" WITH PASSWORD '$$pass';" \
	&& docker exec -i $$DCAPE_DB psql -U postgres -c "CREATE DATABASE \"$$dbname\" OWNER \"$$dbname\";" || db_exists=1 ; \
	if [[ ! "$$db_exists" ]] && [[ "$(PG_SOURCE_SUFFIX)" ]] ; then \
	    echo "$$IMPORT_SCRIPT" | docker exec -i $$DCAPE_DB bash -s - $$dbname $$dbname $$pass $$dbname$(PG_SOURCE_SUFFIX) \
	    && docker exec -i $$DCAPE_DB psql -U postgres -c "COMMENT ON DATABASE \"$$dbname\" IS 'SOURCE $$dbname$(PG_SOURCE_SUFFIX)';" \
	    || true ; \
	fi

## drop database and user
db-drop:
	@echo "*** $@ ***" \
	&& varname=$(NAME)_DB_TAG && dbname=$${!varname} \
	&& DCAPE_DB=$${PROJECT_NAME}_db_1 \
	&& docker exec -i $$DCAPE_DB psql -U postgres -c "DROP DATABASE \"$$dbname\";" \
	&& docker exec -i $$DCAPE_DB psql -U postgres -c "DROP USER \"$$dbname\";"

psql:
	@DCAPE_DB=$${PROJECT_NAME}_db_1 \
	&& docker exec -it $$DCAPE_DB psql -U postgres

# ------------------------------------------------------------------------------
# .env file store

## get env tag from store, `make env-get TAG=app--config--tag`
env-get:
	@[[ "$(TAG)" ]] || { echo "Error: Tag value required" ; exit 1 ;}
	@echo "Getting env into $(TAG)"
	@docker exec -ti $${PROJECT_NAME}_webhook_1 curl -gs $${ENFIST_URL}/tag_vars?a_code=$(TAG) \
	  | jq -r '.result[0].tag_vars' > $(TAG).env

## set env tag in store, `make env-set TAG=app--config--tag`
env-set:
	@[[ "$(TAG)" ]] || { echo "Error: Tag value required" ; exit 1 ;}
	@echo "Setting $(TAG) from file" \
	&& jq -R -sc ". | {\"a_code\":\"$(TAG)\",\"a_data\":.}" < $(TAG).env | \
	  docker exec -i $${PROJECT_NAME}_webhook_1 curl -gsd @- $${ENFIST_URL}/tag_set > /dev/null

# ------------------------------------------------------------------------------

## delete unused docker images w/o name
clean-noname:
	docker rmi $$(docker images | grep "<none>" | awk "{print \$$3}")
#docker images -q -f dangling=true

## delete docker dangling volumes
clean-volume:
	docker volume rm $$(docker volume ls -qf dangling=true)

# ------------------------------------------------------------------------------

help:
	@grep -A 1 "^##" Makefile | less

##
## Press 'q' for exit
##
