# Grafana Observability Stack — automated deployment

One idempotent Bash script that deploys a production-ready metrics, logs and alerting stack on **Ubuntu 24.04 LTS** with Docker Compose, plus agent installers for client hosts and a backup/restore tool.

Open **[`grafana-stack-diagram.html`](grafana-stack-diagram.html)** in a browser for an interactive map of the components, ports, bind addresses and data flows.

| Component | Version | Role |
|---|---|---|
| Prometheus | 2.53.5 | Metrics TSDB, alert rule evaluation |
| Alertmanager | 0.27.0 | Alert grouping and routing to Telegram |
| Grafana | 11.1.13 | Dashboards over HTTPS, data sources auto-provisioned |
| Loki | 2.9.17 | Log storage |
| Blackbox Exporter | 0.25.0 | HTTP(S) and ICMP probes; self-signed TLS supported |
| Node Exporter | 1.8.2 | Host metrics |
| Postgres Exporter | 0.15.0 | PostgreSQL metrics |
| Grafana Alloy (agent) | 1.21.2 | Log shipping from client hosts (replaces Promtail) |

## Architecture

```
 LAN users ──HTTPS──► Grafana :3000 (0.0.0.0)
                          │  docker network "monitoring" (service names)
                          ├──► prometheus:9090 ──alerts──► alertmanager:9093 ──► Telegram
                          ├──► loki:3100
                          └──► alertmanager:9093
 prometheus ──scrape──► postgres-exporter:9187 ──► PostgreSQL
            ──/probe──► blackbox-exporter:9115 ──► HTTP(S)/ICMP targets
            ──scrape──► HOST_IP:9100 (node-exporter, host network)
            ──scrape──► remote node_exporter :9100
 client hosts (working network, e.g. 10.100.0.0/16): Alloy ──push──► LOKI_BIND_ADDR:3100

 Published on the host:  0.0.0.0 → Grafana | HOST_IP → Loki (only from LOKI_ALLOWED_CIDRS), node-exporter
                         127.0.0.1 → everything else
```

## Requirements

- Ubuntu 24.04 LTS (other distributions work but are not tested), root access.
- 2 vCPU, 4 GB RAM, and disk sized for retention (Prometheus ≈ 1–2 bytes per sample; Loki depends on log volume).
- Access to Docker Hub, or the images pre-loaded for air-gapped installs (see [Air-gapped hosts](#air-gapped-hosts)).
- Docker and the compose plugin ≥ 2.20 are installed from Ubuntu's repositories if they are missing.

## Quick start

```bash
git clone <this repository> && cd <repository>
sudo bash deploy-observability-stack.sh        # 1st run: creates /opt/observability/.env
sudo nano /opt/observability/.env              # set DSN, targets, Telegram
sudo bash deploy-observability-stack.sh        # applies the configuration
```

Grafana: `https://<HOST_IP>:3000`, user `admin`. The password is in `.env`:

```bash
sudo grep '^GF_SECURITY_ADMIN_PASSWORD=' /opt/observability/.env
```

The browser warns about the self-signed certificate. That is expected.

## What a run does

1. Checks root, takes a lock (no parallel runs), and installs Docker if needed.
2. Creates `.env` on the first run. Later runs only **append missing keys** and never change existing values.
3. Validates `.env` (IP addresses, ports, retention formats).
4. Generates every config. Your own `alert.rules.yml` is created once and never overwritten.
5. **Validates the configs with the exact pinned binaries** (`promtool`, `amtool`, `blackbox --config.check`, `loki -verify-config`, `compose config`). On an error it stops before touching running services and prints the offending line.
6. Runs `docker compose up --wait`, so the run fails (exit ≠ 0) if any service does not become healthy.
7. Applies config changes **only to services whose files changed**:
   - Prometheus, Alertmanager, Blackbox: `SIGHUP` reload with **no downtime**. Success is verified through `*_config_last_reload_successful`.
   - Loki and Grafana: restart.
   - Nothing changed: nothing is restarted.
8. Checks every endpoint from the host and exits non-zero if one is unreachable.

## Configuration (`/opt/observability/.env`)

| Variable | Default | Description |
|---|---|---|
| `HOST_IP` | auto (default-route source IP) | Host address; node-exporter listens here |
| `BIND_ADDR` | `127.0.0.1` | Where Prometheus, Alertmanager, Blackbox and Postgres exporter are published |
| `GRAFANA_BIND_ADDR` | `0.0.0.0` | Where Grafana is published |
| `LOKI_BIND_ADDR` | `HOST_IP` | Where Loki is published (agents push here) |
| `LOKI_ALLOWED_CIDRS` | empty (no restriction) | Comma-separated networks allowed to push to Loki, e.g. `10.100.0.0/16` |
| `*_PORT` | 3000, 9090, 9093, 9115, 9100, 9187, 3100 | Published ports |
| `POSTGRES_EXPORTER_DSN` | placeholder | `postgresql://user:pass@host:5432/db?sslmode=disable`. Use **single quotes** if it contains `$` |
| `BLACKBOX_TARGETS` | examples | Comma-separated HTTP(S) URLs (self-signed TLS accepted) |
| `BLACKBOX_ICMP_TARGETS` | empty | Comma-separated hosts to ping; empty disables ICMP probes |
| `NODE_EXPORTER_TARGETS` | `HOST_IP:9100` | Comma-separated `host:port` list |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | placeholders | While unset, a null-receiver is used (alerts are not delivered) |
| `ALERTMANAGER_EXTERNAL_URL` | `http://HOST_IP:9093` | Base URL used in alert links |
| `PROMETHEUS_RETENTION` | `30d` | Time-based retention |
| `PROMETHEUS_RETENTION_SIZE` | `0` (off) | Size cap, e.g. `40GB`; the oldest blocks are deleted first |
| `LOKI_RETENTION` | `720h` | Log retention |
| `LOKI_TSDB_FROM` | install date + 1 day | Date Loki switches to the TSDB index (schema v13). **Never change it after that date** |
| `*_MEM_LIMIT`, `*_CPUS` | see `env.example` | Optional container resource limits |

`docker compose` reads the same file and interpolates `$`, so wrap any value that contains `$` in single quotes.

## Security model

- **Network exposure is set by bind addresses, not by the firewall.** Docker-published ports bypass UFW/iptables `INPUT` rules. Prometheus, Alertmanager, Blackbox and Postgres exporter have no authentication, so they are loopback-only by default. Reach them over SSH:
  `ssh -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 user@server`
- **Loki has no authentication on push**, so set `LOKI_ALLOWED_CIDRS` to the agents' networks (e.g. `10.100.0.0/16`). The script enforces it in the `DOCKER-USER` iptables chain, where Docker-published traffic is actually filtered (UFW rules would not apply). The `observability-firewall.service` systemd unit re-applies the rules at boot and on every Docker restart. Traffic between containers is never affected. Check the rules with `sudo /usr/local/sbin/observability-firewall status`.
- `.env` is parsed as data (it is never `source`d) and is kept at mode `0600`.
- The Telegram token lives in `alertmanager/secrets/telegram_bot_token` (mode `0400`, uid 65534) and is referenced via `bot_token_file`, so it never appears in `alertmanager.yml`.
- The Grafana admin password is never printed. Grafana applies it on the **first** start only; to change it later run `docker exec -it grafana grafana cli admin reset-admin-password '<new>'`.
- Containers run with `no-new-privileges`. Prometheus, Alertmanager, Loki, Grafana and the exporters run as non-root users. The stateless exporters also run with a read-only root filesystem and `cap_drop: ALL` (Blackbox keeps only `NET_RAW` for ICMP).
- Prometheus runs **without** `--web.enable-lifecycle`, so there is no unauthenticated `/-/quit` endpoint. Reloads use `SIGHUP`.
- Grafana: HTTPS with secure cookies, sign-up disabled, update checks and telemetry disabled. Loki usage reporting is disabled too.

## Alerting

Two rule files are loaded:

| File | Owner | Content |
|---|---|---|
| `prometheus/alert.rules.yml` | **you**: created once, never overwritten | `InstanceDown`, `HighNodeCPU`, `HighNodeMemory`, `BlackboxProbeFailed` |
| `prometheus/rules/stack.rules.yml` | the script, regenerated on every run | Self-monitoring and production rules (below) |

Stack rules: `PrometheusConfigReloadFailed`, `PrometheusRuleEvaluationFailures`, `PrometheusNotificationsFailing`, `PrometheusTSDBCompactionsFailing`, `AlertmanagerConfigReloadFailed`, `AlertmanagerNotificationsFailing`, `BlackboxConfigReloadFailed`, `LokiRequestErrors`, `HostDiskSpaceLow`, `HostDiskWillFillIn24Hours`, `HostOomKillDetected`, `TLSCertificateExpiringSoon` (14 days), `PostgresDown`.

Routing: `group_wait 30s`, `group_interval 5m`, `repeat_interval 4h`. A critical alert inhibits the matching warning.

After editing your rules, validate and apply them without downtime:

```bash
cd /opt/observability
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool prom/prometheus:v2.53.5 check config /etc/prometheus/prometheus.yml
docker compose kill -s SIGHUP prometheus
```

Re-running the deploy script does the same, with validation included.

## Client hosts (agents)

Copy the scripts to each client host.

**Metrics: node_exporter**

```bash
sudo ./install-node-exporter.sh --listen 10.0.0.15:9100 --allow-from 10.0.0.5/32
```

This downloads the release, verifies its SHA256, installs the binary owned by root, and runs it as a dedicated user under a hardened systemd unit. Then add `10.0.0.15:9100` to `NODE_EXPORTER_TARGETS` on the server and re-run the deploy script.

**Logs: Grafana Alloy**

```bash
sudo ./install-alloy.sh --loki-url http://10.0.0.5:3100/loki/api/v1/push --disable-promtail
```

Alloy ships `/var/log/*.log` (`job="varlogs"`), `/var/log/auth.log` (`job="auth"`) and the systemd journal (`job="systemd-journal"`, with labels `unit` and `level`). Every stream gets `host=<hostname>`. The labels match the old Promtail setup, so existing queries keep working. Alloy runs as user `alloy` with read access through the `adm` and `systemd-journal` groups (Promtail ran as root). Positions persist in `/var/lib/alloy`, and new files are read from the end, so history is not re-sent. Pipeline status is at `http://127.0.0.1:12345` on the client.

**Migrating from Promtail.** Promtail reached end-of-life in March 2026. `--disable-promtail` stops and disables `promtail.service` once Alloy is installed. Remove the old binary with `sudo rm /usr/local/bin/promtail /etc/systemd/system/promtail.service`.

## Backup and restore

```bash
sudo ./backup-observability.sh --dest /var/backups/observability --keep 14
sudo ./backup-observability.sh --restore /var/backups/observability/obs-20261026T081415Z
```

| Included | Not included |
|---|---|
| `/opt/observability` (`.env`, secrets, TLS certificate, your rules and dashboards), the Grafana DB, active Alertmanager silences (exported through the API) | Prometheus and Loki data: large, bounded by retention, and rebuilt by scraping. Use storage-level snapshots (LVM/ZFS/VM) if you need them |

Each backup is a `0700` directory with a `MANIFEST` and `SHA256SUMS`. Archives are integrity-checked after writing and checksums are verified before a restore. Grafana is paused for about a second for a consistent SQLite copy; Docker reports it as `unhealthy` until the next healthcheck (≤ 10 s). A restore keeps the current config in `/opt/observability.pre-restore-<ts>`.

Daily cron:

```cron
30 2 * * * root /path/to/backup-observability.sh --keep 14 >> /var/log/observability-backup.log 2>&1
```

**Test a restore regularly.** A backup that has never been restored is not a backup.

## Hosts with an existing installation

If `/opt/observability` already contains a stack, the script adopts it in place:

- missing `.env` keys are appended with safe defaults (existing values are untouched);
- a Prometheus TSDB with root-owned files is `chown`ed once to uid 65534 (Prometheus runs as non-root);
- containers whose definition differs are recreated once; data volumes are kept.

Note that internal services are published on `127.0.0.1` by default. Set `BIND_ADDR` before running if they must stay reachable from the network.

## Production checklist

- [ ] `.env`: real `POSTGRES_EXPORTER_DSN`, `BLACKBOX_TARGETS`, `NODE_EXPORTER_TARGETS`, Telegram token and chat ID
- [ ] Test alert delivery: `docker exec alertmanager amtool alert add TestAlert severity=warning --alertmanager.url=http://localhost:9093`
- [ ] `BIND_ADDR` and `LOKI_BIND_ADDR` match your network design; `LOKI_ALLOWED_CIDRS` set to the agent networks
- [ ] `PROMETHEUS_RETENTION_SIZE` set below the free disk space
- [ ] Backups scheduled in cron, and **one restore tested**
- [ ] Dashboards imported (see below)
- [ ] The deploy script, its `.env` and your `alert.rules.yml` kept under version control or in a secret store

## Grafana dashboards

No dashboards are downloaded automatically, so segmented networks without access to grafana.com work. Import them in **Dashboards → New → Import** by ID:

| ID | Dashboard |
|---|---|
| 1860 | Node Exporter Full |
| 7587 | Prometheus Blackbox Exporter |
| 9628 | PostgreSQL Database |
| 13639 | Logs / App (Loki) |

Dashboard JSON files placed in `/opt/observability/grafana/dashboards/` are provisioned automatically (polled every 30 s).

## Air-gapped hosts

Pull failures are tolerated as long as every pinned image is already present locally. If one is missing, the script stops and lists it. Pre-load the images first:

```bash
# on a machine with internet access
docker save prom/prometheus:v2.53.5 prom/alertmanager:v0.27.0 prom/blackbox-exporter:v0.25.0 \
  prom/node-exporter:v1.8.2 prometheuscommunity/postgres-exporter:v0.15.0 \
  grafana/loki:2.9.17 grafana/grafana:11.1.13 | gzip > observability-images.tar.gz
# on the target
gunzip -c observability-images.tar.gz | sudo docker load
```

## Operations

```bash
cd /opt/observability
docker compose ps                          # status and health
docker compose logs -f <service>           # logs (rotated: 10 MB × 5 per container)
docker compose kill -s SIGHUP prometheus   # reload rules/config without downtime
docker compose down                        # stop (data volumes are kept)
```

## Troubleshooting

**node-exporter is DOWN / `context deadline exceeded`.** node-exporter runs in the host network while Prometheus is on the bridge. With UFW/iptables `INPUT DROP`, allow the bridge subnet:

```bash
docker network inspect observability_monitoring -f '{{(index .IPAM.Config 0).Subnet}}'
sudo ufw allow from <subnet> to any port 9100 proto tcp
```

**`postgres-exporter cannot reach the database (pg_up=0)`.** Check the DSN, the `pg_hba.conf` entry for the server's IP, and `sslmode`. Use `sslmode=disable` if PostgreSQL has no TLS.

**A deploy fails with `... is invalid:`.** The validator output names the file, line and reason. Running services keep their previous configuration.

**`apt update` segfaults in the command-not-found hook.** This is a known Ubuntu 24.04 bug; the script disables the hook automatically.

## Known limitations and roadmap

- Prometheus 2.53, Loki 2.9 and Grafana 11.1 are on their **latest patch** releases, but these minor lines are past upstream support. The next step is a major upgrade (Prometheus 3.x, Loki 3.x, Grafana 12.x) tested on staging. Loki is already prepared: from `LOKI_TSDB_FROM` it writes the TSDB index (schema v13) that Loki 3 requires.
- Single-node design: no HA for Prometheus/Alertmanager/Loki. For HA, run two Alertmanagers in a cluster and pair Prometheus instances (or move to Mimir/Thanos).
- Grafana's TLS certificate is self-signed. For a trusted certificate, put a reverse proxy (Nginx/Traefik with ACME) in front of Grafana, or replace `grafana/tls/grafana.{crt,key}`.

## Repository layout

```
deploy-observability-stack.sh   server: deploy / upgrade / reconfigure
backup-observability.sh         server: backup and restore
install-node-exporter.sh        client: metrics agent
install-alloy.sh                client: log agent
env.example                     all .env variables with comments
grafana-stack-diagram.html      interactive architecture map
```

On the server after deployment:

```
/opt/observability/
├── .env                              # settings and secrets (0600)
├── docker-compose.yml                # generated
├── prometheus/
│   ├── prometheus.yml                # generated
│   ├── alert.rules.yml               # yours: never overwritten
│   └── rules/stack.rules.yml         # generated
├── alertmanager/
│   ├── alertmanager.yml              # generated, no secrets
│   └── secrets/telegram_bot_token    # 0400, uid 65534
├── blackbox/blackbox.yml             # generated
├── loki/loki-config.yml              # generated
├── grafana/{provisioning,dashboards,tls}/
└── .state/config-hashes              # what was last applied
```

## License

MIT, see [LICENSE](LICENSE).
