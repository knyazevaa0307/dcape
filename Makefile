# dcape Makefile
SHELL             = /bin/bash
CFG               = .env
CFG_BAK          ?= $(CFG).bak
DCINC             = docker-compose.inc.yml
# Config vars are described below in section `define CONFIG_DEF`
GITEA            ?= yes
DNS              ?= no
ACME             ?= no
DCAPE_TAG        ?= dcape
DCAPE_NET        ?= $(DCAPE_TAG)
DCAPE_NET_INTRA  ?= $(DCAPE_TAG)_intra
DCAPE_DOMAIN     ?= dev.lan
APPS_ALWAYS      ?= traefik narra enfist drone portainer
TZ               ?= $(shell cat /etc/timezone)
PG_IMAGE         ?= postgres:13.1-alpine
PG_DB_PASS       ?= $(shell < /dev/urandom tr -dc A-Za-z0-9 2>/dev/null | head -c14; echo)
PG_ENCODING      ?= en_US.UTF-8
PG_PORT_LOCAL    ?= 5433
PG_SOURCE_SUFFIX ?=
PG_SHM_SIZE      ?= 64mb
DCAPE_SUBNET     ?= 100.127.0.0/24
DCAPE_SUBNET_INTRA ?= 100.127.255.0/24
DCAPE_VAR        ?= var
DC_VER           ?= 1.27.4
ENFIST_URL       ?= http://enfist:8080/rpc
APPS_SYS         ?= db
PG_CONTAINER     ?= $(DCAPE_TAG)_db_1

# ------------------------------------------------------------------------------

define CONFIG_DEF
# dcape config file, generated by make init

# ==============================================================================
# DCAPE: general config

# Enable local gitea on this host: [yes]|<URL>
# <URL> - external gitea URL
GITEA=$(GITEA)

# Enable powerdns on this host: [no]|yes|wild
# yes - just setup and start
# wild - use as wildcard domain nameserver
DNS=$(DNS)

# Enable Let's Encrypt certificates: [no]|http|wild
# http - use individual host cert
# wild - use wildcard domain for DCAPE_DOMAIN
ACME=$(ACME)

# container name prefix
DCAPE_TAG=$(DCAPE_TAG)

# dcape containers hostname domain
DCAPE_DOMAIN=$(DCAPE_DOMAIN)

# Gitea host for auth
AUTH_SERVER=$(AUTH_SERVER)

# ------------------------------------------------------------------------------
# DCAPE: internal config

# docker network name
DCAPE_NET=$(DCAPE_NET)

# docker internal network name
DCAPE_NET_INTRA=$(DCAPE_NET_INTRA)

# container(s) required for up in any case
# used in make only
APPS=$(APPS)

# create db cluster with this timezone
# (also used by containers)
TZ=$(TZ)

# Postgresql Database image
PG_IMAGE=$(PG_IMAGE)
# Postgresql Database superuser password
PG_DB_PASS=$(PG_DB_PASS)
# Postgresql Database encoding
PG_ENCODING=$(PG_ENCODING)
# port on localhost postgresql listen on
PG_PORT_LOCAL=$(PG_PORT_LOCAL)
# Dump name suffix to load on db-create
PG_SOURCE_SUFFIX=$(PG_SOURCE_SUFFIX)
# shared memory
PG_SHM_SIZE=$(PG_SHM_SIZE)

# docker network subnet
DCAPE_SUBNET=$(DCAPE_SUBNET)

# docker intra network subnet
DCAPE_SUBNET_INTRA=$(DCAPE_SUBNET_INTRA)

# Deployment persistent storage, relative
DCAPE_VAR=$(DCAPE_VAR)

# http if ACME=no, https otherwise
DCAPE_SCHEME=$(DCAPE_SCHEME)

# Docker-compose image tag
DC_VER=$(DC_VER)

endef
export CONFIG_DEF

# ------------------------------------------------------------------------------

# if exists - load old values
-include $(CFG_BAK)
export

-include $(CFG)
export

.PHONY: init apply up reup down install dc docker-wait db-create db-drop psql psql-local gitea-setup env-ls env-get env-set help

all: help

# ------------------------------------------------------------------------------

include apps/*/Makefile

ifndef APPS
  ifneq ($(DNS),no)
    APPS += powerdns
  endif

  ifeq ($(ACME),no)
    DCAPE_SCHEME ?= http
  else
    DCAPE_SCHEME ?= https
  endif

  ifeq ($(GITEA),yes)
    APPS += gitea
    AUTH_SERVER ?= $(DCAPE_SCHEME)://$(GITEA_HOST)
  else
    AUTH_SERVER ?= $(GITEA)
  endif
  APPS += $(APPS_ALWAYS)
endif

space :=
space +=
DCFILES = apps/$(subst $(space),/$(DCINC) apps/,$(APPS))/$(DCINC)

# ------------------------------------------------------------------------------
## dcape Setup
#:

## Initially create $(CFG) file with defaults
init: $(DCAPE_VAR)
	@echo "*** $@ $(APPS) ***"
	@[ -f $(CFG) ] && { echo "$(CFG) already exists. Skipping" ; exit 1 ; } || true
	@echo "$$CONFIG_DEF" > $(CFG)
	@for f in $(shell echo $(APPS)) ; do echo $$f ; $(MAKE) -s $${f}-init ; done

$(DCAPE_VAR):
	@mkdir -p $(DCAPE_VAR)

## Apply config to app files & db
apply:
	@echo "*** $@ $(APPS) ***"
	@$(MAKE) -s dc CMD="up -d $(APPS_SYS)" || echo ""
	@for f in $(shell echo $(APPS)) ; do $(MAKE) -s $${f}-apply ; done
	docker tag docker/compose:$(DC_VER) docker/compose:latest

# build file from app templates
docker-compose.yml: $(DCINC) $(DCFILES)
	@echo "*** $@ ***"
	@echo "# WARNING! This file was generated by make. DO NOT EDIT" > $@
	@cat $(DCINC) >> $@
	@for f in $(shell echo $(DCFILES)) ; do cat $$f >> $@ ; done

## do init..up steps via single command
install: init apply gitea-setup up

# ------------------------------------------------------------------------------
## Docker-compose commands
#:

## (re)start container(s)
up:
up: CMD=up -d $(APPS_SYS) $(shell echo $(APPS))
up: dc

## stop (and remove) container(s)
down:
down: CMD=down
down: dc

## restart container(s)
reup:
reup: CMD=up --force-recreate -d $(APPS_SYS) $(shell echo $(APPS))
reup: dc

# $$PWD usage allows host directory mounts in child containers
# Thish works if path is the same for host, docker, docker-compose and child container
## run $(CMD) via docker-compose
dc: docker-compose.yml
	@echo "Running dc command: $(CMD)"
	@echo "Dcape URL: $(DCAPE_SCHEME)://$(DCAPE_HOST)"
	@echo "------------------------------------------"
	@docker run --rm -t -i \
	  -v /var/run/docker.sock:/var/run/docker.sock \
	  -v $$PWD:$$PWD -w $$PWD \
	  docker/compose:$(DC_VER) \
	  -p $$DCAPE_TAG --env-file $(CFG) \
	  $(CMD)

# ------------------------------------------------------------------------------
## Database commands
#:

# Wait for postgresql container start
docker-wait:
	@echo -n "Checking PG is ready..." ; \
	until [[ `docker inspect -f "{{.State.Health.Status}}" $$PG_CONTAINER` == healthy ]] ; do sleep 1 ; echo -n "." ; done
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
	&& docker exec -i $$PG_CONTAINER psql -U postgres -c "CREATE USER \"$$dbname\" WITH PASSWORD '$$pass';" 2> >(grep -v "already exists" >&2) || true \
	&& docker exec -i $$PG_CONTAINER psql -U postgres -c "CREATE DATABASE \"$$dbname\" OWNER \"$$dbname\";" 2> >(grep -v "already exists" >&2) || db_exists=1 ; \
	if [[ ! "$$db_exists" ]] && [[ "$(PG_SOURCE_SUFFIX)" ]] ; then \
	    echo "$$IMPORT_SCRIPT" | docker exec -i $$PG_CONTAINER bash -s - $$dbname $$dbname $$pass $$dbname$(PG_SOURCE_SUFFIX) \
	    && docker exec -i $$PG_CONTAINER psql -U postgres -c "COMMENT ON DATABASE \"$$dbname\" IS 'SOURCE $$dbname$(PG_SOURCE_SUFFIX)';" \
	    || true ; \
	fi

## drop database and user
db-drop:
	@echo "*** $@ ***" \
	&& varname=$(NAME)_DB_TAG && dbname=$${!varname} \
	&& docker exec -i $$PG_CONTAINER psql -U postgres -c "DROP DATABASE \"$$dbname\";" \
	&& docker exec -i $$PG_CONTAINER psql -U postgres -c "DROP USER \"$$dbname\";"

## exec psql inside db container
psql:
	@docker exec -it $$PG_CONTAINER psql -U postgres

## run local psql
## (requires pg client installed)
psql-local:
	@psql -h localhost -p $(PG_PORT_LOCAL)

# ------------------------------------------------------------------------------
# setup gitea objects

GITEA_ORG_CREATE_URL = $(AUTH_SERVER)/api/v1/admin/users/$(DRONE_ADMIN)/orgs
APP_CREATE_URL       = $(AUTH_SERVER)/api/v1/user/applications/oauth2

define GITEA_ORG_CREATE
{
  "username": "$(NARRA_GITEA_ORG)",
  "visibility": "limited",
  "repo_admin_change_team_access": true
}
endef

define NARRA_APP_CREATE
{
  "name": "$(DCAPE_HOST)",
  "redirect_uris": [ "$(DCAPE_SCHEME)://$(DCAPE_HOST)/login" ]
}
endef

define DRONE_APP_CREATE
{
  "name": "$(DRONE_HOST)",
  "redirect_uris": [ "$(DCAPE_SCHEME)://$(DRONE_HOST)/login" ]
}
endef

define POST_CMD
 -H "Accept: application/json" \
 -H "Content-Type: application/json" \
 -H "Authorization: token $(TOKEN)"
endef

## create gitea org and oauth2 applications
gitea-setup:
	@echo "*** $@ ***"
	@if [[ -z "$(TOKEN)" ]] ; then echo >&2 "TOKEN arg must be defined" ; false ; fi
	@echo "Auth server: $(AUTH_SERVER)"
	@echo "Drone admin: $(DRONE_ADMIN)"
	@echo "Gitea org:   $(NARRA_GITEA_ORG)"
	@echo "Token:       $(TOKEN)"
	@echo -n "create org... " ; \
if resp=$$(echo $$GITEA_ORG_CREATE | curl -gsS -X POST $(GITEA_ORG_CREATE_URL) $(POST_CMD) -d @-) ; then \
  if echo $$resp | jq -re '.id' > /dev/null ; then \
    echo "Done" ; \
  else \
    echo -n "Server response: " ; \
    echo $$resp | jq -re '.message' ; \
  fi ; \
else false ; fi
	@echo -n "create narra app..." ; \
if resp=$$(echo $$NARRA_APP_CREATE | curl -gsS -X POST $(APP_CREATE_URL) $(POST_CMD) -d @-) ; then \
  client_id=$$(echo $$resp | jq -r '.client_id') ; \
  client_secret=$$(echo $$resp | jq -r '.client_secret') ; \
  sed -i "s/=NARRA_CLIENT_ID=/$$client_id/ ; s/=NARRA_CLIENT_KEY=/$$client_secret/ " $(CFG) ; \
  echo "Done" ; \
else false ; fi
	@echo -n "create drone app..." ; \
if resp=$$(echo $$DRONE_APP_CREATE | curl -gsS -X POST $(APP_CREATE_URL) $(POST_CMD) -d @-) ; then \
  client_id=$$(echo $$resp | jq -r '.client_id') ; \
  client_secret=$$(echo $$resp | jq -r '.client_secret') ; \
  sed -i "s/=DRONE_CLIENT_ID=/$$client_id/ ; s/=DRONE_CLIENT_KEY=/$$client_secret/ " $(CFG) ; \
  echo "Done" ; \
else false ; fi
	@echo "Gitea setup complete, do reup"

# ------------------------------------------------------------------------------
## App config storage commands
#:

## get env tag from store, `make env-get TAG=app--config--tag`
env-get:
	@[[ "$(TAG)" ]] || { echo "Error: Tag value required" ; exit 1 ;}
	@echo "Getting env into $(TAG)"
	@docker run --rm -i --network $${DCAPE_NET} $${DCAPE_TAG}_drone-compose curl -gs $${ENFIST_URL}/tag_vars?code=$(TAG) \
	  | jq -r '.' > $(TAG).env

## list env tags in store
env-ls:
	@docker run --rm -i --network $${DCAPE_NET} $${DCAPE_TAG}_drone-compose curl -gs $${ENFIST_URL}/tag \
	  | jq -r '.[] | .updated_at +"  "+.code'

## set env tag in store, `make env-set TAG=app--config--tag`
env-set:
	@[[ "$(TAG)" ]] || { echo "Error: Tag value required" ; exit 1 ;}
	@echo "Setting $(TAG) from file" \
	&& jq -R -sc ". | {\"code\":\"$(TAG)\",\"data\":.}" < $(TAG).env | \
	  docker run --rm -i --network $${DCAPE_NET} $${DCAPE_TAG}_drone-compose curl -gsd @- $${ENFIST_URL}/tag_set > /dev/null

# ------------------------------------------------------------------------------
## Other
#:

## delete unused docker images w/o name
## (you should use portainer for this)
clean-noname:
	docker rmi $$(docker images | grep "<none>" | awk "{print \$$3}")

## delete docker dangling volumes
## (you should use portainer for this)
clean-volume:
	docker volume rm $$(docker volume ls -qf dangling=true)

# This code handles group header and target comment with one or two lines only
## list Makefile targets
## (this is default target)
help:
	@grep -A 1 -h "^## " $(MAKEFILE_LIST) \
  | sed -E 's/^--$$// ; /./{H;$$!d} ; x ; s/^\n## ([^\n]+)\n(## (.+)\n)*(.+):(.*)$$/"    " "\4" "\1" "\3"/' \
  | sed -E 's/^"    " "#" "(.+)" "(.*)"$$/"" "" "" ""\n"\1 \2" "" "" ""/' \
  | xargs printf "%s\033[36m%-15s\033[0m %s %s\n"
