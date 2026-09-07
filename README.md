# phonehost

Monitoring stack and dev toolchains for `note9pro` — a Xiaomi Redmi Note 9 Pro
(sm7125/miatoll) running postmarketOS edge as a small always-on server.

Everything is native Alpine packages under OpenRC. No containers: see
[Why not Docker](#why-not-docker).

## What runs there

| Service | Port | Config |
|---|---|---|
| VictoriaMetrics | 8428 | `etc/conf.d/victoria-metrics`, scrape config `etc/victoria-metrics/scrape.yml` |
| vmalert | 8880 | `etc/conf.d/vmalert`, rules `etc/victoria-metrics/alerts/*.yml` |
| Alertmanager | 9093 | `etc/alertmanager/` |
| Grafana | 3000 | `etc/conf.d/grafana.tmpl`, provisioning under `grafana/` |
| node_exporter | 9100 | `etc/conf.d/node-exporter` |

VictoriaMetrics scrapes all five targets itself (`-promscrape.config`), so there
is no vmagent. Retention is 12 months, memory capped at 25% of RAM. All ports are
reachable only from `LAN_CIDR` via `etc/nftables.d/60_monitoring.nft.tmpl`.

Alert rules: `host.yml` (target down, CPU, load, RAM, disk incl. 24h
`predict_linear`, SoC temperature, zram), `battery.yml` (see
[Charging](#charging-there-is-no-80-limit)), `monitoring-selfcheck.yml` (scrape
failures, vmalert evaluation and delivery errors, free disk).

## Usage

Requires an ssh alias `phone` (or `make SSH_HOST=...`). Privileged targets use
`ssh -t` and prompt for the sudo password; no secret is stored in this repo.

    make apply        # push configs and (re)install the stack
    make apply-dev    # same, plus go / .NET SDK / gcc / git / tmux
    make verify       # health-check endpoints, scrape targets, battery
    make status       # runlevel, listening sockets, memory, disk
    make diff         # show drift between repo and phone
    make backup       # consistent snapshot, pulled into backups/
    make restore F=backups/phonehost-note9pro-<stamp>.tar.gz
    make telegram T=<bot_token> C=<chat_id>
    make rotate-grafana-password

`scripts/setup.sh` is idempotent and safe to re-run. It keeps the existing
Grafana password and Telegram receiver unless you pass new ones, prints a
generated password on first install, and creates random auth keys for the
VictoriaMetrics `/snapshot*` and delete-series endpoints (they are LAN-reachable).

Pin package versions to the ones recorded in `versions.env`:

    make push && ssh -t phone 'sudo env PIN=1 sh /home/user/phonehost/scripts/setup.sh'

## Backup and restore

`make backup` creates a VictoriaMetrics snapshot (hardlinked, no downtime), an
online `sqlite3 .backup` of `grafana.db`, Alertmanager silences/notification log
and every managed config, packs them with a manifest (host, kernel, package
versions, series count) and pulls the archive into `backups/`. The ten newest
archives are kept on the phone.

`make restore F=...` stops the services, moves the old metrics directory aside as
`/var/lib/victoria-metrics.old`, unpacks the snapshot, restores the databases and
starts everything again. It asks for confirmation first. Add `--configs` (run
`restore.sh` directly) to also overwrite `/etc`.

**The archives contain secrets** — the Grafana admin password, the Telegram bot
token and the VictoriaMetrics auth keys. `backups/` is gitignored; treat the
files as you treat access to the phone itself.

## Charging: there is no 80% limit

The PM6150 charger block has no Linux driver. Verified on this device: nothing in
`/sys` exposes `charge_control_limit`, `input_suspend`, `charge_behaviour` or
`constant_charge_current_*`; the only power supplies are the read-only `qcom_qg`
fuel gauge and the Type-C port; the DT has no charger node. Mainline
`qcom_smbx.c` binds only `qcom,pmi8998-charger` and `qcom,pm660-charger`, and the
sm7125-mainline fork ships no pm6150 charger either. Charging therefore runs on
PMIC hardware defaults and the battery sits at 100%.

A real cap has to come from outside the phone (a switchable smart plug, or a hub
with per-port power switching driven by `uhubctl`) or from writing a pm6150 SMB5
charger driver. Until then `BatteryAbove80` and `BatteryFull` in `battery.yml`
just tell you about it.

Gauge quirk: `qcom_qg` reports the raw ADC sign, so **positive current means
discharging** — the driver does not invert it to the Linux convention. Alerts for
losing mains power therefore use the capacity trend (`MainsPowerLost`), not the
current sign.

## Dev toolchains

`make apply-dev` installs go 1.27 and .NET SDK 9 plus gcc/make/git/tmux/htop and
drops `/etc/profile.d/dev-toolchains.sh` (GOPATH, DOTNET_ROOT, telemetry off).
Samples that read the battery from sysfs live in `dev/`. The .NET RID on Alpine is
`linux-musl-arm64`, not `linux-arm64`.

## Why not Docker

The kernel would support it (cgroup v2, `CONFIG_VETH/BRIDGE/BRIDGE_NETFILTER/NF_NAT/OVERLAY_FS`
as modules) and `docker-engine`/`podman` are in the aarch64 repos, but neither
goal that motivated it is served better:

* Reproducibility comes from this repo, not from a runtime. `versions.env` pins
  packages the same way an image tag would.
* Data portability is unchanged — the metrics directory and `grafana.db` are
  already plain files; a volume would only add one level of indirection.
* Docker injects its own iptables-nft chains and publishes ports in `nat`/`FORWARD`,
  bypassing the `policy drop` input chain this host uses. That would expose the
  stack on every interface, `wwan` included, unless every port is bound by hand.
* node_exporter needs host `/proc`, `/sys`, network and PID namespaces anyway, so
  it would stay outside — a hybrid, not a clean compose file.

Containers still make sense for deploying your own Go/C# services later; podman
is the better fit there since it has no daemon and no firewall rules of its own.
