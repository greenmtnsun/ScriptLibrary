# =============================================================================
# SQL Server Fleet Monitoring — Splunk app build
#
# Targets:
#   make help        — show this help
#   make validate    — run tests/validate.sh (14 checks)
#   make build       — assemble the app under build/sql_fleet/
#   make package     — produce dist/sql_fleet-<version>.spl  (depends on validate, build)
#   make install     — copy build/sql_fleet to $SPLUNK_HOME/etc/apps/  (requires SPLUNK_HOME)
#   make clean       — remove build/ and dist/
#
# Variables (override on command line):
#   APP_ID=sql_fleet      VERSION=1.0.0      SPLUNK_HOME=/opt/splunk
# =============================================================================

APP_ID      ?= sql_fleet
VERSION     ?= 1.0.0
SPLUNK_HOME ?=

ROOT        := $(abspath $(CURDIR))
BUILD       := $(ROOT)/build
STAGE       := $(BUILD)/$(APP_ID)
DIST        := $(ROOT)/dist
PKG         := $(DIST)/$(APP_ID)-$(VERSION).spl

SIMPLE_XML  := sql_executive_dashboard.xml sql_operations_dashboard.xml sql_security_dashboard.xml
STUDIO_JSON := sql_executive_dashboard_studio.json sql_operations_dashboard_studio.json sql_security_dashboard_studio.json

PYTHON      ?= python3

.PHONY: help validate build package install clean reinstall

help:
	@awk 'BEGIN{FS=":.*##"; print "Available targets:"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

validate: ## Run pre-deploy validator (XML/JSON/CSV/conf + cross-refs)
	@bash $(ROOT)/tests/validate.sh

build: validate ## Assemble the app tree under build/sql_fleet/
	@echo "==> Assembling $(STAGE)"
	@rm -rf $(BUILD)
	@mkdir -p $(STAGE)/default/data/ui/views
	@mkdir -p $(STAGE)/default/data/ui/nav
	@mkdir -p $(STAGE)/lookups
	@mkdir -p $(STAGE)/metadata
	@mkdir -p $(STAGE)/README
	@echo "    -> default/app.conf"
	@cp $(ROOT)/app-skeleton/default/app.conf                    $(STAGE)/default/app.conf
	@echo "    -> default/transforms.conf, eventtypes.conf, savedsearches.conf"
	@cp $(ROOT)/transforms.conf                                  $(STAGE)/default/transforms.conf
	@cp $(ROOT)/eventtypes.conf                                  $(STAGE)/default/eventtypes.conf
	@cp $(ROOT)/savedsearches.conf                               $(STAGE)/default/savedsearches.conf
	@echo "    -> default/data/ui/nav/default.xml"
	@cp $(ROOT)/app-skeleton/default/data/ui/nav/default.xml     $(STAGE)/default/data/ui/nav/default.xml
	@echo "    -> metadata/default.meta"
	@cp $(ROOT)/app-skeleton/metadata/default.meta               $(STAGE)/metadata/default.meta
	@echo "    -> lookups/sql_inventory.csv"
	@cp $(ROOT)/sql_inventory.csv                                $(STAGE)/lookups/sql_inventory.csv
	@echo "    -> default/data/ui/views/ (SimpleXML)"
	@for f in $(SIMPLE_XML); do \
	    base=$$(basename $$f .xml); \
	    cp $(ROOT)/$$f $(STAGE)/default/data/ui/views/$$base.xml; \
	done
	@echo "    -> default/data/ui/views/ (Studio JSON wrapped as v2 dashboard XML)"
	@for f in $(STUDIO_JSON); do \
	    base=$$(basename $$f .json); \
	    $(PYTHON) $(ROOT)/tests/wrap_studio.py $(ROOT)/$$f $(STAGE)/default/data/ui/views/$$base.xml; \
	done
	@echo "    -> README"
	@cp $(ROOT)/DEPLOY.md $(STAGE)/README/DEPLOY.md
	@cp -r $(ROOT)/wiki   $(STAGE)/README/wiki
	@cp -r $(ROOT)/tests  $(STAGE)/README/tests
	@echo "==> Build complete at $(STAGE)"

package: build ## Produce dist/$(APP_ID)-$(VERSION).spl
	@mkdir -p $(DIST)
	@echo "==> Packaging $(PKG)"
	@tar -C $(BUILD) --owner=0 --group=0 -czf $(PKG) $(APP_ID)
	@ls -la $(PKG)
	@echo ""
	@echo "Install on a Splunk SH:"
	@echo "  splunk install app $(PKG) -auth admin:..."
	@echo "Or via Splunk Web: Apps -> Manage Apps -> Install app from file"

install: build ## Copy build/$(APP_ID) into \$$SPLUNK_HOME/etc/apps/  (set SPLUNK_HOME=)
	@if [ -z "$(SPLUNK_HOME)" ]; then \
	    echo "ERROR: SPLUNK_HOME not set. Example: make install SPLUNK_HOME=/opt/splunk"; exit 1; \
	fi
	@if [ ! -d "$(SPLUNK_HOME)/etc/apps" ]; then \
	    echo "ERROR: $(SPLUNK_HOME)/etc/apps does not exist"; exit 1; \
	fi
	@echo "==> Installing $(APP_ID) into $(SPLUNK_HOME)/etc/apps/"
	@rm -rf "$(SPLUNK_HOME)/etc/apps/$(APP_ID)"
	@cp -r $(STAGE) "$(SPLUNK_HOME)/etc/apps/$(APP_ID)"
	@echo "==> Done. Run: $(SPLUNK_HOME)/bin/splunk restart  (or hit the /reload endpoints)"

reinstall: clean install ## Wipe build/ and reinstall

clean: ## Remove build/ and dist/
	@rm -rf $(BUILD) $(DIST)
	@echo "==> Cleaned build/ and dist/"
