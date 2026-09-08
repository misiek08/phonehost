# phonehost - monitoring stack for the note9pro postmarketOS host
#
# All privileged targets use `ssh -t` so sudo can prompt for the password
# interactively; nothing in this repo stores it.

SSH_HOST ?= phone
REMOTE   ?= /home/user/phonehost
HOST_IP  ?= 192.168.1.79
BACKUPS  ?= backups

SSH  := ssh $(SSH_HOST)
SSHT := ssh -t $(SSH_HOST)

.PHONY: help push apply apply-dev apply-podman apply-chargecap apply-all images build-chargecap verify status logs backup restore telegram rotate-grafana-password diff shell poweroff poweroff-check

help:
	@echo 'push                     copy this repo to $(SSH_HOST):$(REMOTE)'
	@echo 'apply                    push + run setup.sh (stack only)'
	@echo 'apply-dev                push + run setup.sh with go/.NET toolchains'
	@echo 'apply-podman             push + set up rootless podman'
	@echo 'apply-chargecap          push + install the battery charge cap'
	@echo 'build-chargecap          cross-build the chargecap daemon into ./'
	@echo 'apply-all                push + stack + toolchains + podman'
	@echo 'images                   build the sample Go and C# container images on the phone'
	@echo 'verify                   health-check every endpoint and scrape target'
	@echo 'status                   rc-status + listening sockets + memory'
	@echo 'logs                     tail the stack logs'
	@echo 'backup                   snapshot on the phone, pull archive into $(BACKUPS)/'
	@echo 'restore F=<archive>      push an archive and restore it (asks for confirmation)'
	@echo 'telegram C=<chat_id> [TOKENFILE=f|T=<token>]   enable Telegram alerting'
	@echo 'rotate-grafana-password  set a new random Grafana admin password'
	@echo 'diff                     show config drift between repo and phone'
	@echo 'poweroff-check           dry-run the safe shutdown checks'
	@echo 'poweroff                 restore charging, flush, power off (power button to return)'

# Binary data must not pass through a pty, so transfers use plain ssh into the
# user's home; only the privileged steps allocate a tty for the sudo prompt.
push:
	@echo "== pushing to $(SSH_HOST):$(REMOTE)"
	@tar --exclude=./backups --exclude=./.git -czf - . \
		| $(SSH) 'rm -rf $(REMOTE) && mkdir -p $(REMOTE) && tar -C $(REMOTE) -xzf -'

apply: push
	@$(SSHT) 'sudo sh $(REMOTE)/scripts/setup.sh'

apply-dev: push
	@$(SSHT) 'sudo env WITH_DEV=1 sh $(REMOTE)/scripts/setup.sh'

apply-podman: push
	@$(SSHT) 'sudo env WITH_PODMAN=1 SKIP_PKGS=$(SKIP_PKGS) sh $(REMOTE)/scripts/setup.sh'

build-chargecap:
	@sh scripts/build-chargecap.sh .

# Expects pm6150_chg.ko and chargecap in the repo root: build them with
# scripts/build-module.sh and make build-chargecap first.
apply-chargecap: push
	@test -f pm6150_chg.ko -a -f chargecap || { echo 'build pm6150_chg.ko and chargecap first (see kernel/pm6150-chg/README.md)'; exit 1; }
	@$(SSH) 'mkdir -p $(REMOTE)'
	@tar -czf - pm6150_chg.ko chargecap | $(SSH) 'tar -C $(REMOTE) -xzf -'
	@$(SSHT) 'sudo env WITH_CHARGECAP=1 SKIP_PKGS=1 sh $(REMOTE)/scripts/setup.sh'

apply-all: push
	@$(SSHT) 'sudo env WITH_DEV=1 WITH_PODMAN=1 sh $(REMOTE)/scripts/setup.sh'

images: push
	@$(SSH) 'cd $(REMOTE)/dev/hello-go && podman build -t hello-go .' >/dev/null
	@$(SSH) 'cd $(REMOTE)/dev/hello-cs && podman build -t hello-cs .' >/dev/null
	@$(SSH) 'podman images --format "  {{.Repository}}:{{.Tag}}  {{.Size}}" | head -5'
	@echo 'run them with the host battery visible:'
	@echo '  ssh $(SSH_HOST) "podman run --rm -v /sys/class/power_supply:/sys/class/power_supply:ro localhost/hello-go"'

verify:
	@HOST=$(HOST_IP) sh scripts/verify.sh

status:
	@$(SSH) 'rc-status default | grep -Ei "victoria|vmalert|grafana|node-exporter|alertmanager"; \
		echo; free -m | head -2; echo; df -h / | tail -1'
	@$(SSHT) 'sudo ss -tlnp | grep -E ":(3000|8428|8880|9093|9100)"'

logs:
	@$(SSHT) 'sudo tail -n 40 /var/log/victoriametrics.log /var/log/vmalert.log /var/log/alertmanager.log'

backup:
	@mkdir -p $(BACKUPS)
	@$(SSHT) 'sudo sh $(REMOTE)/scripts/backup.sh /var/tmp/phonehost-backups'
	@f=$$($(SSH) 'ls -1t /var/tmp/phonehost-backups/phonehost-*.tar.gz | head -1'); \
		echo "== pulling $$f"; \
		$(SSH) "cat $$f" > $(BACKUPS)/$$(basename $$f); \
		chmod 600 $(BACKUPS)/$$(basename $$f); \
		ls -lh $(BACKUPS)/$$(basename $$f)

restore:
	@test -n "$(F)" || { echo 'usage: make restore F=backups/phonehost-....tar.gz'; exit 1; }
	@cat $(F) | $(SSH) 'cat > /var/tmp/$(notdir $(F))'
	@$(SSHT) 'sudo sh $(REMOTE)/scripts/restore.sh /var/tmp/$(notdir $(F))'

# TOKENFILE keeps the token out of the process list on both ends; T= is the
# convenient but less private form.
telegram:
	@test -n "$(C)" || { echo 'usage: make telegram C=<chat_id> TOKENFILE=<file>  (or T=<token>)'; exit 1; }
	@if [ -n "$(TOKENFILE)" ]; then \
		cat "$(TOKENFILE)" | $(SSH) 'cat > /tmp/.tgtoken && chmod 600 /tmp/.tgtoken'; \
		$(SSHT) 'sudo sh -c "set-telegram-alerts - $(C) < /tmp/.tgtoken; rm -f /tmp/.tgtoken"'; \
	elif [ -n "$(T)" ]; then \
		$(SSHT) 'sudo set-telegram-alerts $(T) $(C)'; \
	else \
		echo 'need TOKENFILE=<file> or T=<token>'; exit 1; \
	fi

rotate-grafana-password: push
	@pw=$$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'); \
		$(SSHT) "sudo env GRAFANA_ADMIN_PASSWORD=$$pw SKIP_PKGS=1 sh $(REMOTE)/scripts/setup.sh" >/dev/null; \
		echo "new Grafana admin password: $$pw"

diff:
	@for f in etc/conf.d/victoria-metrics etc/conf.d/vmalert etc/conf.d/node-exporter \
		etc/conf.d/alertmanager etc/init.d/vmalert etc/victoria-metrics/scrape.yml \
		etc/victoria-metrics/alerts/host.yml etc/victoria-metrics/alerts/battery.yml \
		etc/victoria-metrics/alerts/monitoring-selfcheck.yml; do \
		printf '%-50s ' "$$f"; \
		if $(SSH) "cat /$$f" 2>/dev/null | diff -q - "$$f" >/dev/null 2>&1; then \
			echo 'in sync'; else echo 'DIFFERS'; fi; \
	done
	@echo '(grafana conf.d and nftables rule are rendered from templates, not compared)'

# Powering off leaves the charge cap's inhibit bit in the PMIC unless chargecap
# is stopped first, and there is no wake-on-LAN - see scripts/safe-poweroff.sh.
poweroff-check: push
	@$(SSHT) 'sudo sh $(REMOTE)/scripts/safe-poweroff.sh --dry-run'

poweroff: push
	@$(SSHT) 'sudo sh $(REMOTE)/scripts/safe-poweroff.sh'

shell:
	@$(SSHT) 'exec sh -l'
