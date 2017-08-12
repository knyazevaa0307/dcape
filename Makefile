SHELL        = /bin/bash
CFG          =.env
DIR          =? $$PWD
DCAPE_USED   = 1

PROJECT_NAME ?= dcape
DOMAIN       ?= dev.lan
APPS         ?= traefik portainer cis
APPS_SYS     ?= consul db
SERVER_TZ    ?= Europe/Moscow
# Postgresql superuser Database user password
PG_DB_PASS   ?= $(shell < /dev/urandom tr -dc A-Za-z0-9 | head -c14; echo)

DCINC         = docker-compose.inc.yml
DCFILES       = $(shell find apps/ -name $(DCINC) -print | sort)

-include $(CFG)
export

include apps/*/Makefile

.PHONY: init-master init-test init

init-master: APPS = traefik-acme gitea mmost drone portainer cis pdns
init-master: init

init-slave: APPS = traefik-acme drone portainer cis pdns
init-slave: init

init-local: APPS = traefik gitea mmost drone portainer cis pdns
init-local: init

define CONFIG_DEF
# dcape config file, generated by make init

# General settings

# containers name prefix
PROJECT_NAME=$(PROJECT_NAME)

# Default domain
DOMAIN=$(DOMAIN)

# App list, for use in make only
APPS="$(APPS)"

# containers timezone
TZ=$(SERVER_TZ)

# db (postgresql)
PG_PASSWORD=$(PG_DB_PASS)

endef
export CONFIG_DEF

## установка зависимостей
deps:
	@echo "*** $@ ***"
	which docker > /dev/null || wget -qO- https://get.docker.com/ | sh

## Initially create .enc file with defaults
init:
	@echo "*** $@ $(APPS) ***"
	@[ -d var/data ] || mkdir -p var/data
	@[ -f .env ] && { echo ".env already exists. Skipping" ; exit 1 ; } || true
	@echo "$$CONFIG_DEF" > .env
	@for f in $(APPS) ; do echo $$f ; $(MAKE) -s $${f}-init ; done

## Apply config to app files & db
apply:
	@echo "*** $@ $(APPS) ***"
	@$(MAKE) -s dcrun CMD="up -d db consul" || echo ""
	@for f in $(shell echo $(APPS)) ; do $(MAKE) -s $${f}-apply ; done


# build file from app templates
docker-compose.yml: $(DCINC) $(DCFILES)
	@echo "*** $@ ***"
	@echo "# WARNING! This file was generated by make. DO NOT EDIT" > $@
	@cat $(DCINC) >> $@
	@cat $(DCFILES) >> $@

## старт контейнеров
up:
up: CMD=up -d $(APPS_SYS) $(shell echo $(APPS))
up: dcrun

## рестарт контейнеров
reup:
reup: CMD=up --force-recreate -d $(APPS_SYS) $(shell echo $(APPS))
reup: dcrun

## остановка и удаление всех контейнеров
down:
down: CMD=down
down: dcrun

# ------------------------------------------------------------------------------

# $$PWD используется для того, чтобы текущий каталог был доступен в контейнере по тому же пути
# и относительные тома новых контейнеров могли его использовать
## run docker-compose
dcrun: docker-compose.yml
	@docker run --rm -t -i \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $$PWD:$$PWD \
  -w $$PWD \
  docker/compose:1.14.0 \
  -p $$PROJECT_NAME \
  $(CMD)


# ------------------------------------------------------------------------------

## create database and user
db-create:
	@echo "*** $@ ***"
	@nameuc=$(shell echo $(NAME) | tr a-z A-Z) \
  && varname=$${nameuc}_DB_PASS && pass=$${!varname} \
  && CONTAINER=$${PROJECT_NAME}_db_1 \
  && echo -n "Checking PG is ready..." \
  && until [[ `docker inspect -f "{{.State.Health.Status}}" $$CONTAINER` == healthy ]] ; do sleep 1 ; echo -n "." ; done \
  && echo "Ok" \
  && docker exec -it $$CONTAINER psql -U postgres -c "CREATE USER $(NAME) WITH PASSWORD '$$pass';" \
  && docker exec -it $$CONTAINER psql -U postgres -c "CREATE DATABASE $(NAME) OWNER $(NAME);"

## drop database and user
db-drop:
	@echo "*** $@ ***"
	@nameuc=$(shell echo $(NAME) | tr a-z A-Z) \
  && pass=$${$${nameuc}_DB_PASS} \
  && CONTAINER=$${PROJECT_NAME}_db_1 \
  && docker exec -it $$CONTAINER psql -U postgres -c "DROP DATABASE $(NAME);" \
  && docker exec -it $$CONTAINER psql -U postgres -c "DROP USER $(NAME);"

psql:
	@CONTAINER=$${PROJECT_NAME}_db_1 \
  && docker exec -it $$CONTAINER psql -U postgres

# ------------------------------------------------------------------------------

help:
	@grep -A 1 "^##" Makefile | less

##
## Press 'q' for exit
##
