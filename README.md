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
    make apply-podman # same, plus rootless podman
    make apply-all    # stack + toolchains + podman
    make images       # build the sample Go and C# container images on the phone
    make verify       # health-check endpoints, scrape targets, battery
    make status       # runlevel, listening sockets, memory, disk
    make diff         # show drift between repo and phone
    make backup       # consistent snapshot, pulled into backups/
    make restore F=backups/phonehost-note9pro-<stamp>.tar.gz
    make telegram C=<chat_id> TOKENFILE=<file>
    make rotate-grafana-password
    make poweroff-check   # dry-run the shutdown checks
    make poweroff         # restore charging, flush, power off

Telegram alerting is live: Alertmanager posts to the private channel through a
bot, with the token in `/etc/alertmanager/telegram_token` (0640 root:prometheus)
referenced as `bot_token_file`, so it is never in the config or in this repo.
`set-telegram-alerts` validates the generated config with `amtool` and refuses
to install one Alertmanager would reject.

Finding the chat id of a private channel: there is no lookup, the bot has to see
an event. Make it a channel **administrator** (otherwise it receives no posts),
post any message, then long-poll

    curl -s "https://api.telegram.org/bot<token>/getUpdates?timeout=60"

and read `result[].channel_post.chat.id` - a channel id is negative.

`scripts/setup.sh` is idempotent and safe to re-run. It keeps the existing
Grafana password and Telegram receiver unless you pass new ones, prints a
generated password on first install, and creates random auth keys for the
VictoriaMetrics `/snapshot*` and delete-series endpoints (they are LAN-reachable).

Pin package versions to the ones recorded in `versions.env`:

    make push && ssh -t phone 'sudo env PIN=1 sh /home/user/phonehost/scripts/setup.sh'

## Shutting it down

Use `sudo poweroff` (busybox, and `/etc/inittab` has `::shutdown:/sbin/openrc
shutdown`, so init runs the OpenRC shutdown runlevel and services stop in
dependency order). **Never `poweroff -f`** - that calls `reboot(2)` directly,
skipping init entirely: no service stop, no read-only remount, and none of the
charge-cap cleanup below.

The thing that makes shutdown special on this host is not the filesystem, it is
the charger. The cap works by clearing `CHARGING_ENABLE_CMD` in the PM6150, and
the PMIC keeps that bit while the system is off - it stays powered so off-mode
charging can work - so powering down while the cap holds `inhibit-charge` can
leave the phone **not charging at all** until it is booted again. Stopping
`chargecap` restores `auto`, and a clean `poweroff` does that for you.

`make poweroff` (or `scripts/safe-poweroff.sh`) checks it instead of trusting
it: stop chargecap, verify `charge_behaviour` really reads `auto`, refuse to
continue otherwise (`--force` overrides), report the battery level, `sync`, then
`poweroff`. `--dry-run` shows what it would do.

It also masks the PMIC's **cable power-on trigger**. Without that, a phone
powered off with a charger connected switches straight back on: CBL ("external
power supply") is a power-on trigger in the PM6150's PON block, and mainline has
no off-mode charging to land in, so PON boots the whole OS. Read on this device:

    PON_TRIGGER_EN  0xe4  kpd=1 cbl=1 usb=0 rtc=1
    PON_REASON1     0x10  last_power_on=usb-insertion

`echo 0 > /sys/kernel/pm6150_chg/cable_wakeup` clears CBL (0xe4 -> 0xa4) and
never touches KPD (bit 7) - a masked power key would mean a phone that cannot be
switched on at all. `pm6150_chg` re-arms the trigger every time it loads, so the
masking lasts exactly until the next boot: a deliberate shutdown stays off, while
a host that died on a flat battery still revives when power returns.
`--keep-cable-wakeup` skips the masking.

**A connected charger switches the phone back on**, about 90 s after the
power-off, and there is nothing Linux can do about it - see
`kernel/pm6150-chg/README.md` for the measurements, including why a boot-time
guard that shuts it down again is either useless or a permanent 90-second
boot/power-off cycle. To keep the phone off, unplug it.

There is no wake-on-LAN either: after a shutdown only the power button brings the
phone back.

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

## Charging: capped at 80%

The PM6150 charger block has no Linux driver. Verified on this device: nothing in
`/sys` exposes `charge_control_limit`, `input_suspend`, `charge_behaviour` or
`constant_charge_current_*`; the only power supplies are the read-only `qcom_qg`
fuel gauge and the Type-C port; the DT has no charger node. Mainline
`qcom_smbx.c` binds only `qcom,pmi8998-charger` and `qcom,pm660-charger`, and the
sm7125-mainline fork ships no pm6150 charger either. Charging therefore runs on
PMIC hardware defaults and the battery sits at 100%.

**This is now solved in software**, without a charger driver, a DTB change or a
kernel flash: `kernel/pm6150-chg/` is a loadable module that drives two single
bits of the charger block and exposes them as `charge_behaviour` on `qcom_qg`,
and `daemon/chargecap` holds the level in a band (default 75–80 %). Measured:
`inhibit-charge` parks the battery at exactly 0 µA with the phone still running
off USB, so the cap costs no cycling, no heat and no wasted power. Read
`kernel/pm6150-chg/README.md` before touching either.

    make build-chargecap                     # daemon, cross-built in a container
    sh scripts/build-module.sh               # module, see the kernel README
    make apply-chargecap                     # install both on the phone

External options were ruled out for this host: it hangs off a Windows PC's USB
port (`Ethernet 3` at 172.16.42.2 is the other end of the phone's NCM gadget),
so `uhubctl` has nothing to talk to, and no smart plug is in play.

Gauge quirk: `qcom_qg` reports the raw ADC sign, so **positive current means
discharging** — the driver does not invert it to the Linux convention. Alerts for
losing mains power therefore use the capacity trend (`MainsPowerLost`), not the
current sign.

## Dev toolchains

`make apply-dev` installs go 1.27 and .NET SDK 9 plus gcc/make/git/tmux/htop and
drops `/etc/profile.d/dev-toolchains.sh` (GOPATH, DOTNET_ROOT, telemetry off).
Samples that read the battery from sysfs live in `dev/`. The .NET RID on Alpine is
`linux-musl-arm64`, not `linux-arm64`.

## The LAN link

WiFi power save is **off** on this host, set in two places: `wifi.powersave=2`
in `etc/NetworkManager/conf.d/10-no-wifi-powersave.conf` (applied when the
connection activates) and the `wifi-powersave-off` OpenRC service, which runs
`iw dev wlan0 set power_save off` after NetworkManager and also fixes an
interface that came up before the setting was read.

It was diagnosed after the phone stopped answering pings and Grafana while being
perfectly healthy. The evidence, all of it from the host itself:

* local scrapes ran 120/hour without a single gap for 14 h, and
  `node_network_carrier_changes_total{device="wlan0"}` never moved off 2 - the
  host was up and the link never dropped;
* `dmesg`/logbookd showed no disconnect, roam or deauth in that window;
* pings from the LAN measured min 3.1 ms, avg 71.7 ms, **max 180.5 ms** - the
  radio was only awake on DTIM beacons, and ARP can be missed long enough for a
  router to write the client off.

After turning power save off: avg 4.8 ms, max 7.1 ms. The cost is roughly a tenth
of a watt of idle draw, which this host, powered over USB, can spare.

Two periodic pokes at the radio were removed at the same time, both pointless on
a headless phone: node_exporter was reading the `ath10k_hwmon` sensor every 30 s
(each read a firmware thermal request, failing twice a minute with "failed to
synchronize thermal read"), now excluded via
`--collector.hwmon.chip-exclude=soc_0_18800000_wifi`; and Sxmo's status bar was
polling WiFi every 60 s to draw an icon on a panel that is switched off, now
stopped from the session start hook.

**Reading the system log:** `logbookd` keeps everything in RAM and only writes
`/var/log/logbookd.db` when stopped or told to save, so after an incident the
interesting hours are not on disk yet. `sudo rc-service logbookd save` flushes
them; `etc/periodic/15min/logbookd-save` now does it on a schedule (crond is in
the default runlevel) so a crash cannot take the evidence with it.

## Screen off, and never suspending

The phone runs Sxmo (dwm) started by `tinydm`. Two things had to be arranged for
a headless host:

* **It must never sleep.** `/sys/power/state` offers `freeze mem` and Sxmo runs
  `sxmo_autosuspend`, which suspends the device 3 s after the session enters
  `screenoff` (`SXMO_SUSPENDABLE_STATES` default). For this host that would stop
  VictoriaMetrics, alerting and the charge cap. `etc/init.d/no-suspend` (in the
  default runlevel) holds a kernel wakelock named `phonehost`;
  `sxmo_autosuspend` follows the wakeup_count protocol, where reading
  `/sys/power/wakeup_count` blocks while any wakelock is held, so suspend cannot
  proceed no matter what the session's state machine does with its own
  `sxmo_not_suspendable` lock. `rc-service no-suspend status` reports whether it
  is held.
* **The session starts with the panel off.** `WITH_SCREENOFF=1` installs
  `sxmo/hooks/sxmo_hook_start.sh` (a verbatim copy of the Sxmo default, same
  `configversion`, plus two lines) into `~/.config/sxmo/hooks/`. It stops
  `sxmo_autosuspend` and sets the `screenoff` state, which powers the panel down
  (`dpms=Off`, `bl_power=4`) and saves the ~80 mW the backlight draws.

This is a dark screen, **not** a password barrier: the power button wakes an
unlocked session. dwm's locker in Sxmo is `i3lock`, which is not installed, and
`/etc/pam.d` here has no `base-auth`/`system-auth` for a locker to authenticate
against (which is also why sshd runs `UsePAM no`). A real local barrier means
either fixing PAM and installing a locker, or dropping `tinydm` from the
runlevel so physical access lands on a `getty` password prompt — at the cost of
the on-screen keyboard, so local recovery would then need a USB keyboard.

## Containers: rootless podman

`make apply-podman` installs podman 6.1 with crun, netavark/aardvark-dns, pasta and
fuse-overlayfs, and configures what rootless mode needs on this host:

* subuid/subgid ranges for the `user` account (`user:100000:65536`) — without them
  podman falls back to a single-uid mapping and many images break;
* `fuse` and `overlay` in `/etc/modules-load.d/podman.conf` (both are modules here);
* `mount --make-rshared /` via `/etc/local.d/10-podman-shared-mount.start`, which
  silences the "/ is not a shared mount" warning on every run;
* `etc/conf.d/podman` with `podman_user=user`, so the OpenRC `podman` service runs
  the API socket unprivileged.

Autostart for your own services comes from that service: its `start_post` calls
`start_containers`, so anything created with a restart policy comes up at boot.

    podman run -d --restart=always --name myservice localhost/myservice
    sudo rc-service podman start_containers   # bring them up without rebooting

`podman-docker` provides a `docker` command alias and `podman-compose` is installed.

`make images` builds the two samples in `dev/` on the phone:

| Image | Base | Size |
|---|---|---|
| `localhost/hello-go` | multi-stage `golang:1.27-alpine` → `scratch` | 1.58 MB |
| `localhost/hello-cs` | `dotnet/sdk:9.0-alpine` → `dotnet/runtime:9.0-alpine` | 96.3 MB |

Both read the battery from sysfs, so run them with it mounted:

    podman run --rm -v /sys/class/power_supply:/sys/class/power_supply:ro localhost/hello-go

Two things to know:

* **Published ports are not opened in the firewall.** Rootless podman uses
  `rootlessport`/pasta and creates no nft table or chain of its own, so the host's
  `policy drop` input chain still blocks published ports. Expose a container
  deliberately by extending `etc/nftables.d/60_monitoring.nft.tmpl`.
  Installing podman does pull in `postmarketos-config-nftables-docker` (an
  install_if of the pmOS nftables config), which drops `/etc/nftables.d/51_docker.nft`
  accepting all input from `docker*` interfaces. It is inert here — rootless podman
  has no bridge and rootful netavark names its bridge `podman0` — but it would open
  up any interface actually named `docker*`.
* **Rootless resource limits need the delegated subtree below.** Out of the box
  podman *silently ignores* `--memory`/`--cpus` when rootless here: it tries to
  create its cgroups at the cgroup root (`mkdir /sys/fs/cgroup/conmon: permission
  denied`) and then leaves the container in whatever cgroup it inherited.

### Resource limits for rootless containers

There is no `user.slice` on this host and there cannot be one: that is a systemd
construct. elogind (which pmOS/Sxmo uses) is only the logind half — it puts each
login in a session cgroup (`/c131`, owned by root, no controllers delegated) but
has no unit manager, and it is systemd's `Delegate=` on `user@.service` that
normally hands a user a writable subtree. sshd here also runs with `UsePAM no`,
so a `pam_exec` hook would never fire for ssh logins.

What works instead is an explicit delegation, which `make apply-podman` sets up:

* `cgroup-delegate` (OpenRC service, `etc/init.d/cgroup-delegate`) creates
  `/sys/fs/cgroup/deleg/u<uid>/{shell,containers}` at boot, enables
  `+cpu +io +memory +pids` down the path and chowns the subtree to the user. The
  two children exist because a cgroup may hold either processes or enabled
  controllers, never both.
* `cg-attach` (`/usr/local/sbin`) moves one of your own processes into
  `deleg/u<uid>/shell`. This needs root: cgroup v2 delegation containment refuses
  a move whose common ancestor with the source is the (root-owned) cgroup root.
  The helper refuses any pid the caller does not own.
* `/etc/profile.d/cgroup-delegate.sh` exports `PODMAN_CGROUP_PARENT` and tries
  `sudo -n cg-attach $$`, staying silent if that needs a password.

So per login shell:

    sudo cg-attach $$
    podman run --rm --cgroup-parent="$PODMAN_CGROUP_PARENT" \
        --memory=200m --cpus=0.5 --pids-limit=64 alpine:3.22 ...

Verified inside such a container: `memory.max 209715200`, `cpu.max 50000 100000`,
`pids.max 64`, and a 400 MB write into `/dev/shm` gets killed at the 200 MB cap.

To skip the manual `cg-attach` on every login, add a passwordless rule for that
one helper — your call, it is not installed by default:

    echo 'user ALL=(root) NOPASSWD: /usr/local/sbin/cg-attach' \
        | sudo tee /etc/sudoers.d/cg-attach
    sudo chmod 440 /etc/sudoers.d/cg-attach

### Limits without any of that

For containers you actually deploy, run them as OpenRC services and let OpenRC
apply the limits — no delegation, no flags, works for rootless containers:

    sudo install -m 755 examples/container-service /etc/init.d/myservice
    sudo install -m 644 examples/container-service.conf /etc/conf.d/myservice
    sudo rc-update add myservice default && sudo rc-service myservice start

`rc_cgroup_settings` in `/etc/conf.d/myservice` is written to the service's own
cgroup, so it covers podman, conmon and the container together. Verified: the
container process lands in `/sys/fs/cgroup/openrc.myservice` with
`memory.max 209715200`, `pids.max 64`, `cpu.max 50000 100000` — and the container
sees the same value from the inside.

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

Containers still make sense for deploying your own Go/C# services, which is why
rootless podman is installed alongside the stack — no daemon, and no firewall
rules of its own.
