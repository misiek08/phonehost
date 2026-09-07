# Dev toolchains on note9pro (postmarketOS / Alpine edge, aarch64)

Installed: go 1.27.1 (`/usr/bin/go`), .NET SDK 9.0.120 (`/usr/bin/dotnet`), gcc 15, make, git, tmux, htop.
Env comes from `/etc/profile.d/dev-toolchains.sh` (GOPATH=~/go, DOTNET_ROOT=/usr/lib/dotnet,
telemetry off, ~/go/bin and ~/.dotnet/tools on PATH). Log in again after changes.

## Go

    cd ~/dev/hello-go
    go build -o hello . && ./hello
    go run .

Cross-compile from this phone for other targets: `GOOS=linux GOARCH=amd64 go build`.

## C#

    cd ~/dev/hello-cs
    dotnet run
    dotnet build -c Release

Single-file, no runtime needed on the target:

    dotnet publish -c Release -r linux-musl-arm64 --self-contained \
      -p:PublishSingleFile=true

NativeAOT (smaller/faster start, needs `apk add dotnet9-sdk-aot clang lld`):

    dotnet publish -c Release -r linux-musl-arm64 -p:PublishAot=true

Note the RID is **linux-musl-arm64** (Alpine/musl), not linux-arm64.

## Monitoring stack (LAN only, 192.168.1.0/24)

| Service         | URL                        |
|-----------------|----------------------------|
| Grafana         | http://192.168.1.79:3000   |
| VictoriaMetrics | http://192.168.1.79:8428   |
| vmalert         | http://192.168.1.79:8880   |
| Alertmanager    | http://192.168.1.79:9093   |
| node_exporter   | http://192.168.1.79:9100   |

Configs: `/etc/conf.d/{victoria-metrics,vmalert,grafana,node-exporter,alertmanager}`,
scrape config `/etc/victoria-metrics/scrape.yml`, rules `/etc/victoria-metrics/alerts/*.yml`,
Grafana provisioning `/var/lib/grafana/provisioning/`.

Reload rules after editing: `sudo rc-service vmalert restart`
Reload scrape config: automatic within 30s (`-promscrape.configCheckInterval`).

Enable Telegram alerts: `sudo set-telegram-alerts <bot_token> <chat_id>`
