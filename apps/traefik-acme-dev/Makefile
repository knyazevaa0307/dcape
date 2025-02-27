# Traefik-acme-dev init Makefile
# This file included by ../../Makefile

SHELL               	= /bin/bash

# DCAPE_USED==1 when called from upper Makefile
DCAPE_USED         		?= 0
# Traefik Docker image version by dcape
TRAEFIK_VER0       		?= 1.7.19
# Traefik Docker image version
TRAEFIK_VER        		?= $(TRAEFIK_VER0)

# Let's encrypt user email
TRAEFIK_ACME_EMAIL 		?= admin@$(DOMAIN)
# Traefik hosts default entrypoint (eg: http,https)
TRAEFIK_ENTRY_DEFAULT 	?= http
# Traefik port 80 serving rule (eg: 80 Redirect.EntryPoint:https)
TRAEFIK_ENTRY_HTTP 		?= 80
# Variable for set redirect on build-in apps to dcape
REDIR_ENTRY		   		?= https

define CONFIG_TRAEFIKA
# ------------------------------------------------------------------------------
# Traefik-acme settings

# Traefik Docker image version
TRAEFIK_VER=$(TRAEFIK_VER)

# Let's encrypt user email
TRAEFIK_ACME_EMAIL=$(TRAEFIK_ACME_EMAIL)
# Traefik hosts default entrypoint (eg: http,https)
TRAEFIK_ENTRY_DEFAULT=$(TRAEFIK_ENTRY_DEFAULT)
# Traefik port 80 serving rule (eg: 80 Redirect.EntryPoint:https)
TRAEFIK_ENTRY_HTTP=$(TRAEFIK_ENTRY_HTTP)
# Variable for set redirect on build-in apps to dcape
REDIR_ENTRY=$(REDIR_ENTRY)

endef
export CONFIG_TRAEFIKA

traefik-acme-dev-init:
	@grep Traefik-acme .env > /dev/null || echo "$$CONFIG_TRAEFIKA" >> .env
	@mkdir -p ./var/data/traefik/custom
	@if [[ "$$TRAEFIK_VER0" != "$$TRAEFIK_VER" ]] ; then \
	  echo "Warning: TRAEFIK_VER in dcape ($$TRAEFIK_VER0) differs from yours ($$TRAEFIK_VER)" ; \
	fi

traefik-acme-dev-apply:
