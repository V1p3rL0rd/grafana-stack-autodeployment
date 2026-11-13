# Grafana Stack Autodeployment

Production-ready monitoring and alerting stack for **Ubuntu 24.04 LTS**, deployed by a single idempotent Bash script on Docker Compose.

**Traefik** is the only service exposed to the network: it terminates HTTPS on port 443 with a self-signed certificate (valid for 5 years) and proxies to **Grafana**. Prometheus, Alertmanager and the exporters are never reachable from outside the host. Any additional exporter can be plugged in without touching the script.

Open [`grafana-stack-diagram.html`](grafana-stack-diagram.html) in a browser for an interactive map of components, ports and data flows.

## Components

| Component | Version | Role |
|---|---|---|
| Traefik | 3.7.18 | Single entry point: HTTPS :443 → Grafana, HTTP :80 → redirect to HTTPS |
| Grafana | 11.1.13 | Dashboards; data sources provisioned automatically |
| Prometheus | 2.53.5 | Metrics storage and alert rule evaluation |
| Alertmanager | 0.27.0 | Alert grouping, deduplication and delivery to Telegram |
| Node Exporter | 1.8.2 | Host metrics (this server and remote hosts) |
| Blackbox Exporter | 0.25.0 | HTTP(S) and ICMP availability probes |
| Extra exporters | any | PostgreSQL, Redis, MySQL, Windows… — see [Adding exporters](#adding-exporters) |

## Features

- **One command** to install, reconfigure or upgrade; safe to re-run at any time.
- **Single HTTPS entry point** — everything else is loopback-only or internal to the Docker network; every deployment ends with an automatic exposure audit.
- **Automatic TLS** — self-signed 5-year certificate, re-issued automatically before expiry or when host names change.
- **Validated before applied** — configs are checked with the pinned `promtool`, `amtool`, `blackbox --config.check` and `docker compose config`; a broken config never reaches running services.
- **Zero-downtime reloads** — only services whose configuration changed are reloaded (`SIGHUP`) or restarted.
- **Hardened containers** — non-root users, read-only root filesystems, dropped capabilities, `no-new-privileges`, resource limits, log rotation.
- **Self-monitoring** — alerts for failed reloads, undelivered notifications, Traefik 5xx rates and certificate expiry.
- **Extensible** — add exporters through a compose override and Prometheus target files.
- **Backup and restore** script included.

## Architecture

```
 Users ──HTTPS :443──► Traefik ──TLS──► Grafana ──► Prometheus ──► Alertmanager ──► Telegram
        (:80 → 301)                        │             │
                                           └─────────────┤ scrape
                                                         ├──► Node Exporter (this host, docker0 gateway only)
                                                         ├──► Node Exporter on remote hosts
                                                         ├──► Blackbox Exporter ──► HTTP(S) / ICMP targets
                                                         └──► extra exporters (prometheus/targets/*.yml)

 Exposed to the network:  Traefik :443, :80
 Loopback only:           Prometheus :9090, Alertmanager :9093, Blackbox :9115
 Docker network only:     Grafana, extra exporters
```

## Requirements

- Ubuntu 24.04 LTS with root access (other distributions may work but are not tested).
- 2 vCPU, 4 GB RAM; disk sized for Prometheus retention (≈ 1–2 bytes per sample).
- Free ports 80 and 443 (configurable).
- Access to Docker Hub, or pre-loaded images (see [Air-gapped installation](#air-gapped-installation)).
- Docker and the Compose plugin ≥ 2.20 — installed automatically if missing.

## Quick start

```bash
git clone https://github.com/V1p3rL0rd/grafana-stack-autodeployment.git
cd grafana-stack-autodeployment
sudo bash deploy-observability-stack.sh     # first run creates /opt/observability/.env
sudo nano /opt/observability/.env           # set PUBLIC_HOST, targets, Telegram
sudo bash deploy-observability-stack.sh     # apply
```

Open `https://<PUBLIC_HOST>/` and sign in as `admin`. The generated password:

```bash
sudo grep '^GF_SECURITY_ADMIN_PASSWORD=' /opt/observability/.env
```

The browser shows a certificate warning because the certificate is self-signed. To remove it, add `/opt/observability/traefik/certs/tls.crt` to the clients' trusted certificates (e.g. via Group Policy or `update-ca-certificates`).

## How a deployment works

1. Checks prerequisites, takes a lock against parallel runs, installs Docker if needed.
2. Creates `.env` on the first run; later runs only add missing keys and never change existing values.
3. Validates `.env` (addresses, host names, ports).
4. Generates all configuration files and the TLS certificate (if missing, expiring within 30 days, or the host names changed). User-owned files are never overwritten.
5. Validates every generated config with the pinned binaries and stops on the first error.
6. Starts the stack with `docker compose up --wait` — the run fails if any service is unhealthy.
7. Applies changes only where needed: `SIGHUP` for Prometheus, Alertmanager and Blackbox; restart for Grafana and Traefik; nothing if nothing changed.
8. Verifies Grafana through Traefik with certificate validation, the HTTP→HTTPS redirect and Prometheus→Node Exporter connectivity, then audits that only Traefik is exposed beyond `127.0.0.1`.

## Configuration

All settings live in `/opt/observability/.env` (mode `0600`). [`env.example`](env.example) documents every key.

| Variable | Default | Description |
|---|---|---|
| `PUBLIC_HOST` | host IP | Name or IP users open in the browser; certificate CN and Grafana URL |
| `TLS_EXTRA_SANS` | empty | Additional certificate names or IPs, comma-separated |
| `TRAEFIK_BIND_ADDR` | `0.0.0.0` | Address Traefik is published on |
| `TRAEFIK_HTTPS_PORT` / `TRAEFIK_HTTP_PORT` | `443` / `80` | Published ports (HTTP only redirects) |
| `HOST_IP` | auto-detected | Server address; included in the certificate |
| `BIND_ADDR` | `127.0.0.1` | Address for Prometheus, Alertmanager and Blackbox |
| `NODE_EXPORTER_TARGETS` | this host | Node exporters to scrape, `host:port`, comma-separated |
| `NODE_EXPORTER_LISTEN_ADDR` | docker0 gateway | Listen address of the local Node Exporter |
| `BLACKBOX_TARGETS` | examples | HTTP(S) URLs to probe (self-signed TLS accepted) |
| `BLACKBOX_ICMP_TARGETS` | empty | Hosts to ping; empty disables ICMP probes |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | placeholders | Alert delivery; alerts are discarded until set |
| `ALERTMANAGER_EXTERNAL_URL` | `http://HOST_IP:9093` | Base URL used in alert links |
| `PROMETHEUS_RETENTION` | `30d` | How long metrics are kept |
| `PROMETHEUS_RETENTION_SIZE` | `0` (off) | Size cap, e.g. `40GB` |
| `GF_SECURITY_ADMIN_USER` / `_PASSWORD` | `admin` / random | Applied on the first Grafana start |
| `TRAEFIK_MEM_LIMIT` / `TRAEFIK_CPUS` | `256m` / `1.0` | Traefik resource limits |

Wrap values containing `$` in single quotes — Docker Compose reads the same file.

## Security

- **Network exposure.** Only Traefik is published to the network. Grafana and extra exporters are reachable only inside the Docker network; Prometheus, Alertmanager and Blackbox only on `127.0.0.1` (use `ssh -L 9090:127.0.0.1:9090 user@server`). The local Node Exporter listens on the Docker bridge gateway, which is not routable from the LAN. Docker-published ports bypass UFW, so exposure is controlled by bind addresses and enforced by the post-deployment audit.
- **Traefik.** Runs as an unprivileged user with a read-only filesystem and no capabilities; uses file-based configuration only and never accesses the Docker socket; the dashboard/API is disabled; health and metrics endpoints are internal. TLS 1.2+; request headers are not logged. HSTS is intentionally disabled because it would make the self-signed certificate warning impossible to bypass.
- **Certificate.** RSA 4096, 1825 days, server-auth only, SANs from `PUBLIC_HOST`, `HOST_IP`, `localhost` and `TLS_EXTRA_SANS`. Private key `0400`. Previous certificates are archived in `traefik/certs/archive/`.
- **Traefik → Grafana** traffic is TLS-encrypted with certificate verification.
- **Secrets.** `.env` is parsed as data, never executed. The Telegram token is stored in a separate `0400` file and is not written into `alertmanager.yml`. The Grafana admin password is never printed.
- **Containers.** Non-root users, `no-new-privileges`, read-only filesystems and `cap_drop: ALL` for stateless services; Prometheus runs without the lifecycle API; Grafana has sign-up, telemetry and update checks disabled.

## Adding exporters

Exporters are added in two user-owned locations that the deploy script never overwrites. Ready-to-use examples are in [`examples/extra-exporters/`](examples/extra-exporters/).

**1. Run the exporter** — `/opt/observability/docker-compose.override.yml`

The script merges this file automatically, validates it, waits for health checks and includes it in the exposure audit. Attach services to the `monitoring` network and do not publish ports.

```yaml
services:
  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:v0.15.0
    user: "65534:65534"
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    environment:
      DATA_SOURCE_NAME: "${POSTGRES_EXPORTER_DSN:?set it in .env}"
    networks: [monitoring]
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:9187/"]
```

**2. Tell Prometheus to scrape it** — `/opt/observability/prometheus/targets/<name>.yml`

```yaml
- targets: ["postgres-exporter:9187"]   # service name, or host:port for a remote exporter
  labels:
    job: postgres-exporter
```

Target files are picked up within a minute without a reload. Exporters running on other hosts need only step 2. After step 1, run the deploy script once to start the container. `InstanceDown` covers every new target automatically; exporter-specific alerts go into `prometheus/alert.rules.yml`.

## Alerting

| File | Owner | Rules |
|---|---|---|
| `prometheus/alert.rules.yml` | you (created once) | `InstanceDown`, `HighNodeCPU`, `HighNodeMemory`, `BlackboxProbeFailed` |
| `prometheus/rules/stack.rules.yml` | generated | `PrometheusConfigReloadFailed`, `PrometheusNotificationsFailing`, `AlertmanagerConfigReloadFailed`, `AlertmanagerNotificationsFailing`, `TraefikTLSCertificateExpiringSoon`, `TraefikHighServerErrorRate` |

Routing: `group_wait 30s`, `group_interval 5m`, `repeat_interval 4h`; critical alerts inhibit matching warnings. To apply edited rules without downtime:

```bash
cd /opt/observability
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool \
  prom/prometheus:v2.53.5 check config /etc/prometheus/prometheus.yml
docker compose kill -s SIGHUP prometheus
```

## Monitoring remote hosts

Install Node Exporter on each host with the included script:

```bash
sudo ./install-node-exporter.sh --listen 10.0.0.15:9100 --allow-from 10.0.0.5/32
```

It verifies the release checksum and runs the exporter as a dedicated user under a hardened systemd unit. Add `10.0.0.15:9100` to `NODE_EXPORTER_TARGETS` and re-run the deploy script.

## Backup and restore

```bash
sudo ./backup-observability.sh --dest /var/backups/observability --keep 14
sudo ./backup-observability.sh --restore /var/backups/observability/obs-<timestamp>
```

Backups contain `/opt/observability` (configuration, secrets, certificates, rules, override and target files, dashboards), the Grafana database and active Alertmanager silences. Prometheus data is not included — use storage-level snapshots if you need it. Each backup is checksummed and verified before restore.

```cron
30 2 * * * root /path/to/backup-observability.sh --keep 14 >> /var/log/observability-backup.log 2>&1
```

## Production checklist

- [ ] `PUBLIC_HOST` and `TLS_EXTRA_SANS` cover every name users will open
- [ ] Real `NODE_EXPORTER_TARGETS`, `BLACKBOX_TARGETS`, Telegram token and chat ID
- [ ] Test alert: `docker exec alertmanager amtool alert add TestAlert severity=warning --alertmanager.url=http://localhost:9093`
- [ ] From another host only ports 80/443 respond: `nc -zv <host> 3000 9090 9093 9100 9115` must fail
- [ ] `PROMETHEUS_RETENTION_SIZE` below the free disk space
- [ ] Daily backups scheduled and one restore tested
- [ ] `.env`, `alert.rules.yml`, override and target files kept in version control or a secret store

## Dashboards

Import in **Dashboards → New → Import** by ID:

| ID | Dashboard |
|---|---|
| 1860 | Node Exporter Full |
| 7587 | Prometheus Blackbox Exporter |
| 17346 | Traefik Official Standalone |

JSON files placed in `/opt/observability/grafana/dashboards/` are provisioned automatically.

## Air-gapped installation

```bash
# on a machine with internet access
docker save prom/prometheus:v2.53.5 prom/alertmanager:v0.27.0 prom/blackbox-exporter:v0.25.0 \
  prom/node-exporter:v1.8.2 grafana/grafana:11.1.13 traefik:v3.7.18 | gzip > images.tar.gz
# on the target host
gunzip -c images.tar.gz | sudo docker load
```

Add the images of your extra exporters to the same archive.

## Operations

```bash
cd /opt/observability
docker compose ps                          # status and health
docker compose logs -f traefik             # access log (JSON)
docker compose kill -s SIGHUP prometheus   # reload without downtime
docker compose down                        # stop; data volumes are kept
openssl x509 -in traefik/certs/tls.crt -noout -enddate -ext subjectAltName
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `502 Bad Gateway` in the browser | Traefik cannot reach or verify Grafana: `docker compose logs traefik grafana`. A replaced `grafana/tls/grafana.crt` must keep `DNS:grafana` in its SAN |
| Certificate name mismatch | The opened name is not in the certificate. Add it to `PUBLIC_HOST` or `TLS_EXTRA_SANS` and re-run the script |
| Node Exporter target is down | With UFW enabled, allow the compose network to reach port 9100: `docker network inspect observability_monitoring -f '{{(index .IPAM.Config 0).Subnet}}'`, then `ufw allow from <subnet> to <docker0-gateway> port 9100 proto tcp` |
| Extra exporter is down | Service must be on the `monitoring` network and its name must match the target file; check `docker compose logs prometheus` |
| Exposure audit fails | A service publishes a port beyond `127.0.0.1` — remove `ports:` or bind it to `127.0.0.1` |
| `... is invalid:` during deploy | The validator shows file, line and reason; running services are not affected |

## Limitations

- Single-node design without high availability.
- The certificate is self-signed. For a trusted certificate, replace `traefik/certs/tls.crt` and `tls.key` with one issued by your CA (the script keeps it as long as the host names match and it is not about to expire).
- Apple platforms do not trust imported server certificates valid for more than 825 days; use a CA-issued certificate for managed Apple devices.

## Repository layout

```
deploy-observability-stack.sh   deploy, reconfigure, upgrade
backup-observability.sh         backup and restore
install-node-exporter.sh        Node Exporter installer for remote hosts
env.example                     documented configuration
examples/extra-exporters/       compose override and target file examples
grafana-stack-diagram.html      interactive architecture diagram
```

Server layout after deployment:

```
/opt/observability/
├── .env                              settings and secrets (0600)
├── docker-compose.yml                generated
├── docker-compose.override.yml       yours: extra exporters (optional)
├── prometheus/
│   ├── prometheus.yml                generated
│   ├── alert.rules.yml               yours
│   ├── rules/stack.rules.yml         generated
│   └── targets/*.yml                 yours: extra scrape targets
├── alertmanager/                     generated config, Telegram token (0400)
├── blackbox/blackbox.yml             generated
├── grafana/                          provisioning, dashboards, internal TLS
└── traefik/                          static and dynamic config, certificate
```

## License

MIT — see [LICENSE](LICENSE).
