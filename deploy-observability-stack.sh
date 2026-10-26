#!/usr/bin/env bash
###############################################################################
# deploy-observability-stack.sh
#
# Production deployment of an observability stack on Ubuntu 24.04 LTS:
#   - Prometheus          metrics TSDB + alert rule evaluation
#   - Alertmanager        alert routing (Telegram)
#   - Blackbox Exporter   HTTP(S) / ICMP probes (self-signed TLS supported)
#   - Node Exporter       host metrics
#   - Postgres Exporter   PostgreSQL metrics
#   - Loki                log storage
#   - Grafana             dashboards (HTTPS, datasources auto-provisioned)
#
# All services run via the docker compose plugin.
#
# Usage:
#   sudo bash deploy-observability-stack.sh
#
# Idempotent: an existing .env is never overwritten (only missing keys are
# appended), configs are regenerated and validated, and only services whose
# configuration actually changed are reloaded (SIGHUP) or restarted. Data
# lives in named docker volumes and survives re-runs.
###############################################################################

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# 0. Base settings / variables
# ----------------------------------------------------------------------------

BASE_DIR="${OBS_BASE_DIR:-/opt/observability}"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
ENV_FILE="${BASE_DIR}/.env"
STATE_DIR="${BASE_DIR}/.state"
COMPOSE_PROJECT="observability"
LOCK_FILE="/run/lock/observability-deploy.lock"

# Image versions (pinned; latest patch release of each minor line)
PROMETHEUS_VERSION="v2.53.5"
ALERTMANAGER_VERSION="v0.27.0"
BLACKBOX_VERSION="v0.25.0"
NODE_EXPORTER_VERSION="v1.8.2"
POSTGRES_EXPORTER_VERSION="v0.15.0"
LOKI_VERSION="2.9.17"
GRAFANA_VERSION="11.1.13"

PROMETHEUS_IMAGE="prom/prometheus:${PROMETHEUS_VERSION}"
ALERTMANAGER_IMAGE="prom/alertmanager:${ALERTMANAGER_VERSION}"
BLACKBOX_IMAGE="prom/blackbox-exporter:${BLACKBOX_VERSION}"
NODE_EXPORTER_IMAGE="prom/node-exporter:${NODE_EXPORTER_VERSION}"
POSTGRES_EXPORTER_IMAGE="prometheuscommunity/postgres-exporter:${POSTGRES_EXPORTER_VERSION}"
LOKI_IMAGE="grafana/loki:${LOKI_VERSION}"
GRAFANA_IMAGE="grafana/grafana:${GRAFANA_VERSION}"

# Ports published on the host (defaults for a fresh .env)
GRAFANA_PORT_DEFAULT=3000
PROMETHEUS_PORT_DEFAULT=9090
ALERTMANAGER_PORT_DEFAULT=9093
BLACKBOX_PORT_DEFAULT=9115
NODE_EXPORTER_PORT_DEFAULT=9100
POSTGRES_EXPORTER_PORT_DEFAULT=9187
LOKI_PORT_DEFAULT=3100

# Services that read config files from ${BASE_DIR}. Prometheus, Alertmanager
# and Blackbox re-read their config on SIGHUP (no downtime); Loki and Grafana
# need a restart.
CONFIG_SERVICES=(prometheus alertmanager blackbox-exporter loki grafana)
HUP_SERVICES=" prometheus alertmanager blackbox-exporter "

MIN_COMPOSE_VERSION="2.20.0"
WAIT_TIMEOUT=240

# ----------------------------------------------------------------------------
# Logging / error handling
# ----------------------------------------------------------------------------

c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
log()  { echo -e "${c_green}[INFO]${c_reset} $*"; }
warn() { echo -e "${c_yellow}[WARN]${c_reset} $*"; }
err()  { echo -e "${c_red}[ERROR]${c_reset} $*" >&2; }
die()  { err "$*"; exit 1; }

on_error() {
    local rc=$? line=$1 cmd=$2
    err "Command failed (exit ${rc}) at line ${line}: ${cmd}"
    err "Nothing was rolled back automatically. Running containers keep their previous in-memory config."
    exit "${rc}"
}
trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap 'err "Interrupted."; exit 130' INT TERM

compose() { docker compose --project-directory "${BASE_DIR}" -f "${COMPOSE_FILE}" "$@"; }

# ----------------------------------------------------------------------------
# Safe .env loader
# ----------------------------------------------------------------------------
# .env is parsed as plain KEY=VALUE data and is NEVER executed by bash
# (no `source`). With `source`, a value such as a DSN containing `&`
# (`...?sslmode=disable&connect_timeout=5`) silently backgrounds part of the
# line and leaves the variable empty, and `$`, backticks or `$(...)` in a
# password are expanded/executed as root. The rules below mirror what
# `docker compose` itself accepts in .env, so both see the same values:
#   - blank lines and lines starting with # are ignored
#   - optional leading `export `
#   - value may be wrapped in matching '...' or "..." (quotes are stripped)
#   - for unquoted values, a trailing ` # comment` is stripped
# Keys that could alter the script's own behaviour are refused.
load_env() {
    [[ -f "${ENV_FILE}" ]] || die "Environment file not found: ${ENV_FILE}"

    local _le_line _le_key _le_val _le_n=0
    while IFS= read -r _le_line || [[ -n "${_le_line}" ]]; do
        _le_n=$((_le_n + 1))
        _le_line="${_le_line%$'\r'}"
        [[ "${_le_line}" =~ ^[[:space:]]*(#|$) ]] && continue

        if [[ ! "${_le_line}" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            warn "${ENV_FILE}:${_le_n}: malformed line ignored (expected KEY=VALUE)"
            continue
        fi
        _le_key="${BASH_REMATCH[2]}"
        _le_val="${BASH_REMATCH[3]}"

        case "${_le_key}" in
            PATH|IFS|HOME|SHELL|ENV|BASH_ENV|LD_*|BASH*|_le_*|BASE_DIR|ENV_FILE|COMPOSE_FILE|STATE_DIR|COMPOSE_PROJECT|LOCK_FILE|*_VERSION|*_IMAGE|CONFIG_SERVICES|HUP_SERVICES)
                warn "${ENV_FILE}:${_le_n}: key '${_le_key}' is reserved and was ignored"
                continue ;;
        esac

        if [[ "${_le_val}" =~ ^\"(.*)\"[[:space:]]*$ || "${_le_val}" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
            _le_val="${BASH_REMATCH[1]}"
        else
            _le_val="$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<< "${_le_val}")"
        fi

        printf -v "${_le_key}" '%s' "${_le_val}"
    done < "${ENV_FILE}"
}

# Address used by health checks / summary to reach a service published on $1.
reach_addr() {
    local bind="$1"
    [[ "${bind}" == "0.0.0.0" || -z "${bind}" ]] && bind="127.0.0.1"
    echo "${bind}"
}

# Comma-separated list -> YAML list items (indented), or "[]" when empty.
# $1 = list, $2 = indent, $3 = "host" to strip any :port suffix.
csv_to_yaml_list() {
    local list="$1" indent="$2" mode="${3:-}" out="" item
    local -a arr=()
    IFS=',' read -ra arr <<< "${list}"
    for item in "${arr[@]}"; do
        item="$(xargs <<< "${item}")"
        [[ -z "${item}" ]] && continue
        [[ "${mode}" == "host" ]] && item="${item%%:*}"
        out+="${indent}- ${item}"$'\n'
    done
    [[ -z "${out}" ]] && out="${indent}[]"$'\n'
    printf '%s' "${out%$'\n'}"
}

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

# ----------------------------------------------------------------------------
# 1. Environment checks
# ----------------------------------------------------------------------------

check_root() {
    [[ $EUID -eq 0 ]] || die "The script must be run as root (use sudo). Example: sudo bash $0"
}

acquire_lock() {
    mkdir -p "$(dirname "${LOCK_FILE}")"
    exec 9>"${LOCK_FILE}"
    flock -n 9 || die "Another deployment is already running (lock: ${LOCK_FILE})."
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" != "ubuntu" ]]; then
            warn "Detected OS '${ID:-unknown}', the script is designed for Ubuntu 24.04 LTS. Continuing at your own risk..."
        elif [[ "${VERSION_ID:-}" != "24.04" ]]; then
            warn "Detected Ubuntu ${VERSION_ID:-unknown}, the script is tested on 24.04. Continuing..."
        else
            log "Ubuntu 24.04 LTS verified."
        fi
    else
        warn "Could not determine OS (/etc/os-release missing). Continuing..."
    fi
}

# ----------------------------------------------------------------------------
# 2. Install Docker + docker compose plugin
# ----------------------------------------------------------------------------

install_docker() {
    if ! { command -v docker &>/dev/null && docker compose version &>/dev/null; }; then
        log "Installing Docker and Docker Compose from standard Ubuntu repositories (docker.io + docker-compose-v2)..."

        # On some Ubuntu 24.04 builds the command-not-found apt hook segfaults
        # and makes apt-get return non-zero, which kills the script under set -e.
        if [[ ! -f /etc/apt/apt.conf.d/99-disable-post-invoke-hooks ]]; then
            echo '#clear APT::Update::Post-Invoke-Success;' > /etc/apt/apt.conf.d/99-disable-post-invoke-hooks
            log "Disabled the command-not-found apt post-invoke hook (known segfault on Ubuntu 24.04)."
        fi

        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2
        systemctl enable --now docker

        if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
            usermod -aG docker "${SUDO_USER}" || true
            log "User '${SUDO_USER}' added to the docker group (re-login to apply)."
        fi
    fi

    local v
    v="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
    version_ge "${v}" "${MIN_COMPOSE_VERSION}" \
        || die "docker compose ${v} is too old; ${MIN_COMPOSE_VERSION}+ is required (for 'up --wait'). Upgrade docker-compose-v2."
    log "Docker $(docker version --format '{{.Server.Version}}'), compose ${v}."
}

# ----------------------------------------------------------------------------
# 3. Detect the host IP (address of the default route's source interface,
#    i.e. what other hosts see — not docker0 / a VPN tun that happens to be
#    listed first by `hostname -I`).
# ----------------------------------------------------------------------------

detect_host_ip() {
    local ip
    if command -v ip &>/dev/null; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)"
    fi
    [[ -z "${ip:-}" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [[ -z "${ip}" ]]; then
        ip="127.0.0.1"
        warn "Could not detect the host IP, using 127.0.0.1. Set HOST_IP in ${ENV_FILE}."
    fi
    echo "${ip}"
}

# ----------------------------------------------------------------------------
# 4. Create directory structure
# ----------------------------------------------------------------------------

create_dirs() {
    log "Creating directory structure in ${BASE_DIR}..."
    mkdir -p \
        "${BASE_DIR}/prometheus/rules" \
        "${BASE_DIR}/alertmanager" \
        "${BASE_DIR}/blackbox" \
        "${BASE_DIR}/loki" \
        "${BASE_DIR}/grafana/provisioning/datasources" \
        "${BASE_DIR}/grafana/provisioning/dashboards" \
        "${BASE_DIR}/grafana/dashboards" \
        "${BASE_DIR}/grafana/tls"
    install -d -m 0700 "${STATE_DIR}"
}

# ----------------------------------------------------------------------------
# 5. Generate .env (created once; later runs only append missing keys)
# ----------------------------------------------------------------------------

ensure_env_var() {
    local key="$1" default_value="$2" comment="${3:-}"
    if ! grep -qE "^${key}=" "${ENV_FILE}" 2>/dev/null; then
        [[ -n "$comment" ]] && echo -e "\n${comment}" >> "${ENV_FILE}"
        echo "${key}=${default_value}" >> "${ENV_FILE}"
        log "Added new variable to ${ENV_FILE}: ${key}"
    fi
}

# Keys that may be missing from an existing or hand-written .env. They are
# appended with safe defaults; a freshly generated .env already has them all.
ensure_new_env_vars() {
    if ! grep -qE "^BIND_ADDR=" "${ENV_FILE}"; then
        warn "BIND_ADDR is not set: Prometheus/Alertmanager/Blackbox/Postgres-exporter will be published on 127.0.0.1 only."
        warn "Set BIND_ADDR in ${ENV_FILE} (e.g. a management/VPN IP) if you need them reachable from other hosts."
    fi
    ensure_env_var "BIND_ADDR" "127.0.0.1" \
        "# --- Network exposure (added automatically) ---
# Address internal services (Prometheus, Alertmanager, Blackbox, Postgres exporter)
# are published on. 127.0.0.1 = local only (use an SSH tunnel); set to a
# management/VPN IP to expose them there. Avoid 0.0.0.0: Docker-published ports
# bypass UFW/iptables INPUT rules."
    ensure_env_var "GRAFANA_BIND_ADDR" "0.0.0.0"
    ensure_env_var "LOKI_BIND_ADDR" "${HOST_IP:-127.0.0.1}" \
        "# Loki must be reachable by remote log agents; restrict with a firewall/VPN."
    ensure_env_var "TELEGRAM_BOT_TOKEN" "CHANGE_ME_telegram_bot_token" \
        "# --- Alertmanager: Telegram notifications (added automatically) ---"
    ensure_env_var "TELEGRAM_CHAT_ID" "CHANGE_ME_telegram_chat_id"
    ensure_env_var "BLACKBOX_ICMP_TARGETS" "" \
        "# --- Blackbox Exporter: separate ICMP ping target list (added automatically) ---
# Comma-separated, host/IP only, no :port. Empty = ICMP probing disabled."
    ensure_env_var "PROMETHEUS_RETENTION_SIZE" "0" \
        "# --- Prometheus size-based retention (added automatically) ---
# Oldest blocks are deleted when the TSDB exceeds this size (e.g. 40GB).
# 0 = disabled (time-based PROMETHEUS_RETENTION only)."
    ensure_env_var "LOKI_RETENTION" "720h" \
        "# --- Loki log retention (added automatically) ---"
    ensure_env_var "LOKI_TSDB_FROM" "$(date -u -d tomorrow +%F)" \
        "# --- Loki index schema switch date (added automatically) ---
# From this UTC date Loki writes the TSDB index (schema v13) instead of
# boltdb-shipper (v11). This is the prerequisite for upgrading to Loki 3.x.
# NEVER change this value after that date has passed — older data would
# become unreadable."
    ensure_env_var "LOKI_ALLOWED_CIDRS" "" \
        "# --- Loki push access (added automatically) ---
# Comma-separated source networks allowed to reach Loki (LOKI_BIND_ADDR:LOKI_PORT),
# e.g. 10.100.0.0/16. Enforced in the DOCKER-USER iptables chain (UFW does not
# apply to Docker-published ports). Empty = no restriction."
    ensure_env_var "ALERTMANAGER_EXTERNAL_URL" "" \
        "# --- Optional: external URLs used in alert links (added automatically) ---
# Empty = http://HOST_IP:ALERTMANAGER_PORT"
}

generate_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        log ".env already exists, supplementing with missing variables (leaving existing values untouched): ${ENV_FILE}"
        chmod 600 "${ENV_FILE}"
        load_env
        ensure_new_env_vars
        load_env
        return 0
    fi

    log "Generating ${ENV_FILE}..."

    local host_ip grafana_admin_pass tsdb_from
    host_ip="$(detect_host_ip)"
    grafana_admin_pass="$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-20)"
    tsdb_from="$(date -u -d tomorrow +%F)"

    # Create with 0600 before writing secrets into it (no world-readable window).
    install -m 600 /dev/null "${ENV_FILE}"
    cat <<EOF > "${ENV_FILE}"
###############################################################################
# Observability stack configuration. Edit to match your environment and
# re-run the deploy script. Values containing \$ must be wrapped in
# 'single quotes' (docker compose interpolates \$ otherwise).
###############################################################################

# --- Ports published on the host ---
GRAFANA_PORT=${GRAFANA_PORT_DEFAULT}
PROMETHEUS_PORT=${PROMETHEUS_PORT_DEFAULT}
ALERTMANAGER_PORT=${ALERTMANAGER_PORT_DEFAULT}
BLACKBOX_PORT=${BLACKBOX_PORT_DEFAULT}
NODE_EXPORTER_PORT=${NODE_EXPORTER_PORT_DEFAULT}
POSTGRES_EXPORTER_PORT=${POSTGRES_EXPORTER_PORT_DEFAULT}
LOKI_PORT=${LOKI_PORT_DEFAULT}

# --- Host IP the stack runs on (node-exporter listens here; used in links) ---
HOST_IP=${host_ip}

# --- Network exposure ---
# Address internal services (Prometheus, Alertmanager, Blackbox, Postgres exporter)
# are published on. 127.0.0.1 = local only (use an SSH tunnel); set to a
# management/VPN IP to expose them there. Avoid 0.0.0.0: Docker-published ports
# bypass UFW/iptables INPUT rules.
BIND_ADDR=127.0.0.1
# Grafana is the user-facing entry point (HTTPS + login).
GRAFANA_BIND_ADDR=0.0.0.0
# Loki must be reachable by remote log agents.
LOKI_BIND_ADDR=${host_ip}
# Source networks allowed to push to Loki (comma-separated CIDRs), e.g. 10.100.0.0/16.
# Enforced in the DOCKER-USER iptables chain (UFW does not apply to Docker-published
# ports). Empty = any host that can reach LOKI_BIND_ADDR.
LOKI_ALLOWED_CIDRS=

# --- Grafana ---
# The password is applied on the FIRST start only. To change it later:
#   docker exec -it grafana grafana cli admin reset-admin-password '<new>'
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=${grafana_admin_pass}

# --- Alertmanager: Telegram notifications ---
# 1) Create a bot via @BotFather, get TELEGRAM_BOT_TOKEN (looks like 123456:ABC-DEF...)
# 2) Add the bot to the target chat/channel, send any message and open
#    https://api.telegram.org/bot<TOKEN>/getUpdates to find chat.id.
# 3) For a channel/supergroup chat_id is negative (e.g. -1001234567890).
TELEGRAM_BOT_TOKEN=CHANGE_ME_telegram_bot_token
TELEGRAM_CHAT_ID=CHANGE_ME_telegram_chat_id
# Optional: external URL used in alert links. Empty = http://HOST_IP:ALERTMANAGER_PORT
ALERTMANAGER_EXTERNAL_URL=

# --- Postgres Exporter: connection string to your database ---
# The DB user needs pg_monitor (PostgreSQL 10+):
#   CREATE USER postgres_exporter WITH PASSWORD 'strong_password';
#   GRANT pg_monitor TO postgres_exporter;
POSTGRES_EXPORTER_DSN='postgresql://postgres_exporter:CHANGE_ME_password@192.168.1.50:5432/postgres?sslmode=disable'

# --- Blackbox Exporter: comma-separated HTTP(S) targets ---
# Probed with the https_selfsigned module (self-signed certificates accepted).
BLACKBOX_TARGETS=https://192.168.1.10,https://192.168.1.20:8443,http://192.168.1.30:80

# --- Blackbox Exporter: comma-separated ICMP targets (host/IP only). Empty = disabled ---
BLACKBOX_ICMP_TARGETS=

# --- node-exporter hosts (comma-separated host:port). This server is included ---
NODE_EXPORTER_TARGETS=${host_ip}:9100

# --- Prometheus retention ---
PROMETHEUS_RETENTION=30d
# Size cap for the TSDB (e.g. 40GB); oldest blocks are deleted first. 0 = disabled.
PROMETHEUS_RETENTION_SIZE=0

# --- Loki ---
LOKI_RETENTION=720h
# From this UTC date Loki writes the TSDB index (schema v13). Prerequisite for
# Loki 3.x. NEVER change this value after that date has passed.
LOKI_TSDB_FROM=${tsdb_from}

# --- Optional resource limits (defaults shown; uncomment to override) ---
#PROMETHEUS_MEM_LIMIT=2g
#PROMETHEUS_CPUS=1.0
#LOKI_MEM_LIMIT=1g
#LOKI_CPUS=1.0
#GRAFANA_MEM_LIMIT=512m
#ALERTMANAGER_MEM_LIMIT=256m
#BLACKBOX_MEM_LIMIT=128m
#NODE_EXPORTER_MEM_LIMIT=128m
#POSTGRES_EXPORTER_MEM_LIMIT=128m
EOF

    log ".env file created (mode 600). Grafana admin password is stored there as GF_SECURITY_ADMIN_PASSWORD."
    warn "Edit POSTGRES_EXPORTER_DSN, BLACKBOX_TARGETS and TELEGRAM_* in ${ENV_FILE}, then re-run the script."
    load_env
}

validate_env() {
    local key
    for key in HOST_IP BIND_ADDR GRAFANA_BIND_ADDR LOKI_BIND_ADDR; do
        [[ "${!key:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "${key}='${!key:-}' in ${ENV_FILE} is not an IPv4 address."
    done
    for key in GRAFANA_PORT PROMETHEUS_PORT ALERTMANAGER_PORT BLACKBOX_PORT NODE_EXPORTER_PORT POSTGRES_EXPORTER_PORT LOKI_PORT; do
        [[ "${!key:-}" =~ ^[0-9]+$ ]] && (( ${!key} >= 1 && ${!key} <= 65535 )) || die "${key}='${!key:-}' is not a valid port."
    done
    [[ "${LOKI_TSDB_FROM:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "LOKI_TSDB_FROM must be YYYY-MM-DD."
    local cidr
    local -a cidrs=()
    IFS=',' read -ra cidrs <<< "${LOKI_ALLOWED_CIDRS:-}"
    for cidr in "${cidrs[@]}"; do
        cidr="$(xargs <<< "${cidr}")"
        [[ -z "${cidr}" || "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] \
            || die "LOKI_ALLOWED_CIDRS: '${cidr}' is not an IPv4 CIDR (e.g. 10.100.0.0/16)."
    done
    [[ "${PROMETHEUS_RETENTION:-}" =~ ^[0-9]+(ms|s|m|h|d|w|y)$ ]] || die "PROMETHEUS_RETENTION='${PROMETHEUS_RETENTION:-}' is invalid (e.g. 30d)."
    [[ "${PROMETHEUS_RETENTION_SIZE:-}" =~ ^[0-9]+([KMGTPE]?B)?$ ]] || die "PROMETHEUS_RETENTION_SIZE='${PROMETHEUS_RETENTION_SIZE:-}' is invalid (e.g. 40GB or 0)."
    [[ "${LOKI_RETENTION:-}" =~ ^[0-9]+(h|d|w|y)$ ]] || die "LOKI_RETENTION='${LOKI_RETENTION:-}' is invalid (e.g. 720h)."
    if grep -qE '^POSTGRES_EXPORTER_DSN=[^'"'"']*\$' "${ENV_FILE}"; then
        warn "POSTGRES_EXPORTER_DSN contains '\$' but is not single-quoted; docker compose will mangle it."
    fi
}

# ----------------------------------------------------------------------------
# 6. Prometheus configuration and alert rules
# ----------------------------------------------------------------------------

generate_prometheus_config() {
    log "Generating prometheus.yml and stack alert rules..."

    local blackbox_targets_yaml node_targets_yaml icmp_targets_yaml
    blackbox_targets_yaml="$(csv_to_yaml_list "${BLACKBOX_TARGETS:-}" "          ")"
    node_targets_yaml="$(csv_to_yaml_list "${NODE_EXPORTER_TARGETS:-}" "          ")"
    icmp_targets_yaml="$(csv_to_yaml_list "${BLACKBOX_ICMP_TARGETS:-}" "          " host)"

    cat <<EOF > "${BASE_DIR}/prometheus/prometheus.yml"
# Generated by deploy-observability-stack.sh — do not edit, change .env instead.
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s
  external_labels:
    monitor: observability-${HOST_IP}

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

rule_files:
  - /etc/prometheus/alert.rules.yml   # yours: created once, never overwritten
  - /etc/prometheus/rules/*.yml       # stack rules: regenerated on every run

scrape_configs:

  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: alertmanager
    static_configs:
      - targets: ["alertmanager:9093"]

  - job_name: blackbox-exporter
    static_configs:
      - targets: ["blackbox-exporter:9115"]

  - job_name: loki
    static_configs:
      - targets: ["loki:3100"]

  - job_name: grafana
    scheme: https
    tls_config:
      insecure_skip_verify: true   # Grafana uses a self-signed certificate
    static_configs:
      - targets: ["grafana:3000"]

  - job_name: node-exporter
    static_configs:
      - targets:
${node_targets_yaml}

  - job_name: postgres-exporter
    static_configs:
      - targets: ["postgres-exporter:9187"]

  # HTTP(S) probes. https_selfsigned accepts self-signed certificates and is
  # also safe for plain http:// targets (TLS settings are simply not used).
  - job_name: blackbox-https-selfsigned
    metrics_path: /probe
    params:
      module: [https_selfsigned]
    static_configs:
      - targets:
${blackbox_targets_yaml}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115

  # ICMP ping (blackbox container has CAP_NET_RAW).
  - job_name: blackbox-icmp
    metrics_path: /probe
    params:
      module: [icmp]
    static_configs:
      - targets:
${icmp_targets_yaml}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115
EOF

    # User-owned rules file: created once, then left alone.
    if [[ ! -f "${BASE_DIR}/prometheus/alert.rules.yml" ]]; then
        cat <<'EOF' > "${BASE_DIR}/prometheus/alert.rules.yml"
# Your alert rules. Created once by the deploy script and never overwritten.
# Stack/self-monitoring rules live in rules/stack.rules.yml (regenerated).
groups:
  - name: basic-alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Instance {{ $labels.instance }} down"
          description: "{{ $labels.instance }} (job {{ $labels.job }}) has been unavailable for more than 2 minutes."

      - alert: HighNodeCPU
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage on {{ $labels.instance }}"
          description: "CPU usage exceeds 90% for more than 5 minutes."

      - alert: HighNodeMemory
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory consumption on {{ $labels.instance }}"
          description: "Memory usage exceeds 90% for more than 5 minutes."

      - alert: BlackboxProbeFailed
        expr: probe_success == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Probe failed for {{ $labels.instance }}"
          description: "Blackbox probe for {{ $labels.instance }} has been failing for more than 2 minutes."
EOF
    fi

    cat <<'EOF' > "${BASE_DIR}/prometheus/rules/stack.rules.yml"
# Generated by deploy-observability-stack.sh — do not edit (overwritten on
# every run). Put your own rules into alert.rules.yml.
groups:
  - name: stack-self-monitoring
    rules:
      - alert: PrometheusConfigReloadFailed
        expr: prometheus_config_last_reload_successful == 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Prometheus config reload failed"
          description: "Prometheus is running with a stale configuration. Check: docker compose logs prometheus"

      - alert: PrometheusRuleEvaluationFailures
        expr: increase(prometheus_rule_evaluation_failures_total[5m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Prometheus rule evaluation failures"
          description: "{{ $value | humanize }} rule evaluation failures in the last 5 minutes (group {{ $labels.rule_group }})."

      - alert: PrometheusNotificationsFailing
        expr: rate(prometheus_notifications_errors_total[5m]) > 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Prometheus cannot deliver alerts to Alertmanager"
          description: "Alerts are not reaching Alertmanager ({{ $labels.alertmanager }})."

      - alert: PrometheusTSDBCompactionsFailing
        expr: increase(prometheus_tsdb_compactions_failed_total[3h]) > 0
        labels:
          severity: warning
        annotations:
          summary: "Prometheus TSDB compactions are failing"
          description: "Check disk space and docker compose logs prometheus."

      - alert: AlertmanagerConfigReloadFailed
        expr: alertmanager_config_last_reload_successful == 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Alertmanager config reload failed"
          description: "Alertmanager is running with a stale configuration."

      - alert: AlertmanagerNotificationsFailing
        expr: rate(alertmanager_notifications_failed_total[5m]) > 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Alertmanager fails to send notifications via {{ $labels.integration }}"
          description: "Notifications are not being delivered. Check the Telegram token/chat_id and outbound access to api.telegram.org."

      - alert: BlackboxConfigReloadFailed
        expr: blackbox_exporter_config_last_reload_successful == 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Blackbox exporter config reload failed"
          description: "Blackbox exporter is running with a stale configuration."

      - alert: LokiRequestErrors
        expr: |
          100 * sum by (route) (rate(loki_request_duration_seconds_count{status_code=~"5..", route!~"ready|metrics"}[5m]))
            / sum by (route) (rate(loki_request_duration_seconds_count{route!~"ready|metrics"}[5m])) > 5
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Loki returns errors on {{ $labels.route }}"
          description: "{{ $value | humanize }}% of requests fail with 5xx."

  - name: hosts
    rules:
      - alert: HostDiskSpaceLow
        expr: |
          node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"} / node_filesystem_size_bytes * 100 < 10
            and node_filesystem_readonly == 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Low disk space on {{ $labels.instance }} ({{ $labels.mountpoint }})"
          description: "Only {{ $value | humanize }}% free."

      - alert: HostDiskWillFillIn24Hours
        expr: |
          predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"}[6h], 24 * 3600) < 0
            and node_filesystem_readonly == 0
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Disk {{ $labels.mountpoint }} on {{ $labels.instance }} will fill within 24h"
          description: "At the current write rate the filesystem runs out of space within a day."

      - alert: HostOomKillDetected
        expr: increase(node_vmstat_oom_kill[5m]) > 0
        labels:
          severity: warning
        annotations:
          summary: "OOM kill on {{ $labels.instance }}"
          description: "The kernel OOM killer terminated a process in the last 5 minutes."

  - name: probes-and-databases
    rules:
      - alert: TLSCertificateExpiringSoon
        expr: probe_ssl_earliest_cert_expiry - time() < 14 * 86400
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "TLS certificate for {{ $labels.instance }} expires soon"
          description: "Expires in {{ $value | humanizeDuration }}."

      - alert: PostgresDown
        expr: pg_up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL is unreachable from postgres-exporter"
          description: "Check POSTGRES_EXPORTER_DSN, credentials and network access to the database."
EOF
}

# ----------------------------------------------------------------------------
# 7. Alertmanager configuration
# ----------------------------------------------------------------------------

generate_alertmanager_config() {
    # chat_id must be numeric (negative for channels). With placeholders a
    # null-receiver is generated so Alertmanager doesn't crash-loop.
    local telegram_ready=true
    [[ -z "${TELEGRAM_BOT_TOKEN:-}" || "${TELEGRAM_BOT_TOKEN}" == "CHANGE_ME_telegram_bot_token" ]] && telegram_ready=false
    [[ "${TELEGRAM_CHAT_ID:-}" =~ ^-?[0-9]+$ ]] || telegram_ready=false

    local secrets_dir="${BASE_DIR}/alertmanager/secrets"
    local token_file="${secrets_dir}/telegram_bot_token"
    # Owned by the alertmanager container user (nobody, 65534): readable in the
    # container, unreadable by other unprivileged users on the host.
    install -d -m 0500 -o 65534 -g 65534 "${secrets_dir}"

    # Shared parts: grouping tuned to avoid notification storms when a target flaps.
    local route_common inhibit
    route_common='  group_by: ["alertname", "instance"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h'
    inhibit='inhibit_rules:
  - source_matchers: [severity="critical"]
    target_matchers: [severity="warning"]
    equal: ["alertname", "instance"]'

    if [[ "${telegram_ready}" == "true" ]]; then
        log "Generating alertmanager.yml (receiver: Telegram, chat_id=${TELEGRAM_CHAT_ID})..."
        # The token goes to a separate 0400 file referenced via bot_token_file,
        # never into alertmanager.yml.
        install -m 0400 -o 65534 -g 65534 /dev/null "${token_file}"
        printf '%s' "${TELEGRAM_BOT_TOKEN}" > "${token_file}"
        cat <<EOF > "${BASE_DIR}/alertmanager/alertmanager.yml"
# Generated by deploy-observability-stack.sh — do not edit, change .env instead.
global:
  resolve_timeout: 5m

route:
  receiver: telegram-default
${route_common}

receivers:
  - name: telegram-default
    telegram_configs:
      - bot_token_file: /etc/alertmanager/secrets/telegram_bot_token
        chat_id: ${TELEGRAM_CHAT_ID}
        parse_mode: HTML
        send_resolved: true
        message: |
          {{- if eq .Status "firing" -}}
          🚨 <b>[PROBLEM] {{ .CommonLabels.alertname }}</b>
          {{- else -}}
          ✅ <b>[RESOLVED] {{ .CommonLabels.alertname }}</b>
          {{- end }}
          {{ range .Alerts }}
          <b>Node:</b> {{ .Labels.instance | html }}
          <b>Job:</b> {{ .Labels.job | html }}
          <b>Severity:</b> {{ .Labels.severity | html }}
          <b>Description:</b> {{ .Annotations.description | html }}
          <b>Modification Time:</b> {{ (.StartsAt.Add 10800000000000).Format "2006-01-02 15:04:05" }} MSK
          {{ end }}

${inhibit}
EOF
    else
        warn "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID are not set or invalid in ${ENV_FILE}."
        warn "Generating alertmanager.yml with a null-receiver (alerts are NOT delivered) to prevent a crash-loop."
        rm -f "${token_file}"
        cat <<EOF > "${BASE_DIR}/alertmanager/alertmanager.yml"
# Generated by deploy-observability-stack.sh — do not edit, change .env instead.
# Fill in TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env and re-run the script.
global:
  resolve_timeout: 5m

route:
  receiver: null-receiver
${route_common}

receivers:
  - name: null-receiver

${inhibit}
EOF
    fi
    chmod 644 "${BASE_DIR}/alertmanager/alertmanager.yml"
}

# ----------------------------------------------------------------------------
# 8. Blackbox Exporter configuration
# ----------------------------------------------------------------------------

generate_blackbox_config() {
    log "Generating blackbox.yml..."
    cat <<'EOF' > "${BASE_DIR}/blackbox/blackbox.yml"
# Generated by deploy-observability-stack.sh — do not edit.
modules:

  # HTTP(S) with certificate validation (sites with publicly trusted certificates)
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []   # 2xx
      method: GET
      preferred_ip_protocol: ip4
      tls_config:
        insecure_skip_verify: false

  # HTTPS with self-signed / untrusted certificates — TLS verification disabled
  https_selfsigned:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []
      method: GET
      preferred_ip_protocol: ip4
      fail_if_ssl: false
      fail_if_not_ssl: false
      tls_config:
        insecure_skip_verify: true

  tcp_connect:
    prober: tcp
    timeout: 5s

  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4

  dns_udp:
    prober: dns
    timeout: 5s
    dns:
      query_name: example.com
      query_type: A
      valid_rcodes: [NOERROR]
EOF
}

# ----------------------------------------------------------------------------
# 9. Loki configuration
# ----------------------------------------------------------------------------

generate_loki_config() {
    log "Generating loki-config.yml..."
    cat <<EOF > "${BASE_DIR}/loki/loki-config.yml"
# Generated by deploy-observability-stack.sh — do not edit, change .env instead.
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: info

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

schema_config:
  configs:
    # Original period — kept so existing data stays readable.
    - from: 2020-10-24
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h
    # TSDB index from LOKI_TSDB_FROM onwards (required for Loki 3.x).
    - from: ${LOKI_TSDB_FROM}
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /loki/tsdb-index
    cache_location: /loki/tsdb-cache

limits_config:
  retention_period: ${LOKI_RETENTION}
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  max_cache_freshness_per_query: 10m
  ingestion_rate_mb: 8
  ingestion_burst_size_mb: 16

compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  compactor_ring:
    kvstore:
      store: inmemory

ruler:
  storage:
    type: local
    local:
      directory: /loki/rules
  rule_path: /loki/rules-temp
  alertmanager_url: http://alertmanager:9093
  ring:
    kvstore:
      store: inmemory
  enable_api: true

analytics:
  reporting_enabled: false
EOF
}

# ----------------------------------------------------------------------------
# 10. Self-signed TLS certificate for Grafana
# ----------------------------------------------------------------------------

# Created once and left untouched on re-runs so browser exceptions stay
# valid. Delete grafana/tls/grafana.{crt,key} to force re-issuance.
generate_grafana_tls_cert() {
    local cert_dir="${BASE_DIR}/grafana/tls"
    local cert_file="${cert_dir}/grafana.crt"
    local key_file="${cert_dir}/grafana.key"

    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        log "Grafana TLS certificate already exists, leaving untouched: ${cert_file}"
    else
        log "Generating self-signed TLS certificate for Grafana (CN=${HOST_IP})..."
        openssl req -x509 -nodes -newkey rsa:4096 \
            -days 3650 \
            -keyout "$key_file" \
            -out "$cert_file" \
            -subj "/CN=${HOST_IP}" \
            -addext "subjectAltName=IP:${HOST_IP},DNS:localhost,DNS:grafana" \
            2>/dev/null
        log "TLS certificate created: ${cert_file} (valid for 10 years)"
    fi

    # The grafana image runs as uid:gid 472:472.
    chown 472:472 "$key_file" "$cert_file"
    chmod 640 "$key_file"
    chmod 644 "$cert_file"
}

# ----------------------------------------------------------------------------
# 11. Grafana provisioning
# ----------------------------------------------------------------------------

generate_grafana_provisioning() {
    log "Generating Grafana provisioning..."
    cat <<'EOF' > "${BASE_DIR}/grafana/provisioning/datasources/datasources.yml"
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true

  - name: Alertmanager
    type: alertmanager
    access: proxy
    url: http://alertmanager:9093
    jsonData:
      implementation: prometheus
    editable: true

  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: true
EOF

    cat <<'EOF' > "${BASE_DIR}/grafana/provisioning/dashboards/dashboards.yml"
apiVersion: 1

providers:
  - name: "default"
    orgId: 1
    folder: ""
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
EOF
}

# ----------------------------------------------------------------------------
# 12. docker-compose.yml
# ----------------------------------------------------------------------------

generate_compose_file() {
    log "Generating docker-compose.yml..."
    local am_external_url="${ALERTMANAGER_EXTERNAL_URL:-}"
    [[ -z "${am_external_url}" ]] && am_external_url="http://${HOST_IP}:${ALERTMANAGER_PORT}"

    cat <<EOF > "${COMPOSE_FILE}"
# Generated by deploy-observability-stack.sh — do not edit, change .env instead.
name: ${COMPOSE_PROJECT}

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"

x-service: &default-service
  restart: unless-stopped
  logging: *default-logging
  security_opt:
    - no-new-privileges:true

networks:
  monitoring:
    driver: bridge

volumes:
  prometheus_data:
  alertmanager_data:
  loki_data:
  grafana_data:

services:

  prometheus:
    <<: *default-service
    image: ${PROMETHEUS_IMAGE}
    container_name: prometheus
    user: "65534:65534"
    volumes:
      - ./prometheus:/etc/prometheus:ro
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=\${PROMETHEUS_RETENTION}"
      - "--storage.tsdb.retention.size=\${PROMETHEUS_RETENTION_SIZE}"
      - "--web.external-url=http://\${HOST_IP}:\${PROMETHEUS_PORT}"
      - "--web.route-prefix=/"
    ports:
      - "\${BIND_ADDR}:\${PROMETHEUS_PORT}:9090"
    networks: [monitoring]
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:9090/-/ready"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 60s
    deploy:
      resources:
        limits:
          cpus: "\${PROMETHEUS_CPUS:-1.0}"
          memory: "\${PROMETHEUS_MEM_LIMIT:-2g}"

  alertmanager:
    <<: *default-service
    image: ${ALERTMANAGER_IMAGE}
    container_name: alertmanager
    volumes:
      - ./alertmanager:/etc/alertmanager:ro
      - alertmanager_data:/alertmanager
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"
      - "--cluster.listen-address="   # single instance: disable HA gossip on :9094
      - "--web.external-url=${am_external_url}"
      - "--web.route-prefix=/"
    ports:
      - "\${BIND_ADDR}:\${ALERTMANAGER_PORT}:9093"
    networks: [monitoring]
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:9093/-/ready"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 20s
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: "\${ALERTMANAGER_MEM_LIMIT:-256m}"

  blackbox-exporter:
    <<: *default-service
    image: ${BLACKBOX_IMAGE}
    container_name: blackbox-exporter
    read_only: true
    cap_drop: [ALL]
    cap_add: [NET_RAW]   # ICMP probes
    volumes:
      - ./blackbox:/etc/blackbox_exporter:ro
    command:
      - "--config.file=/etc/blackbox_exporter/blackbox.yml"
    ports:
      - "\${BIND_ADDR}:\${BLACKBOX_PORT}:9115"
    networks: [monitoring]
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:9115/-/healthy"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: "\${BLACKBOX_MEM_LIMIT:-128m}"

  node-exporter:
    <<: *default-service
    image: ${NODE_EXPORTER_IMAGE}
    container_name: node-exporter
    read_only: true
    cap_drop: [ALL]
    pid: host
    network_mode: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - "--path.procfs=/host/proc"
      - "--path.sysfs=/host/sys"
      - "--path.rootfs=/rootfs"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc|run/docker|var/lib/docker)(\$\$|/)"
      - "--web.listen-address=\${HOST_IP}:\${NODE_EXPORTER_PORT}"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://\${HOST_IP}:\${NODE_EXPORTER_PORT}/metrics"]
      interval: 15s
      timeout: 5s
      retries: 4
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: "\${NODE_EXPORTER_MEM_LIMIT:-128m}"

  postgres-exporter:
    <<: *default-service
    image: ${POSTGRES_EXPORTER_IMAGE}
    container_name: postgres-exporter
    read_only: true
    cap_drop: [ALL]
    environment:
      DATA_SOURCE_NAME: "\${POSTGRES_EXPORTER_DSN}"
    ports:
      - "\${BIND_ADDR}:\${POSTGRES_EXPORTER_PORT}:9187"
    networks: [monitoring]
    healthcheck:
      # Landing page: stays healthy when the DB is down (pg_up=0 + PostgresDown alert)
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:9187/"]
      interval: 15s
      timeout: 5s
      retries: 4
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: "\${POSTGRES_EXPORTER_MEM_LIMIT:-128m}"

  loki:
    <<: *default-service
    image: ${LOKI_IMAGE}
    container_name: loki
    volumes:
      - ./loki:/etc/loki:ro
      - loki_data:/loki
    command:
      - "-config.file=/etc/loki/loki-config.yml"
    ports:
      - "\${LOKI_BIND_ADDR}:\${LOKI_PORT}:3100"
    networks: [monitoring]
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:3100/ready"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 60s
    deploy:
      resources:
        limits:
          cpus: "\${LOKI_CPUS:-1.0}"
          memory: "\${LOKI_MEM_LIMIT:-1g}"

  grafana:
    <<: *default-service
    image: ${GRAFANA_IMAGE}
    container_name: grafana
    environment:
      GF_SECURITY_ADMIN_USER: "\${GF_SECURITY_ADMIN_USER}"
      GF_SECURITY_ADMIN_PASSWORD: "\${GF_SECURITY_ADMIN_PASSWORD}"
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_SERVER_PROTOCOL: "https"
      GF_SERVER_CERT_FILE: "/etc/grafana/tls/grafana.crt"
      GF_SERVER_CERT_KEY: "/etc/grafana/tls/grafana.key"
      GF_SERVER_ROOT_URL: "https://\${HOST_IP}:\${GRAFANA_PORT}/"
      GF_SECURITY_COOKIE_SECURE: "true"
      GF_SECURITY_DISABLE_GRAVATAR: "true"
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES: "false"
      GF_LOG_MODE: "console"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
      - ./grafana/tls:/etc/grafana/tls:ro
    ports:
      - "\${GRAFANA_BIND_ADDR}:\${GRAFANA_PORT}:3000"
    networks: [monitoring]
    healthcheck:
      test: ["CMD", "curl", "-fsk", "-o", "/dev/null", "https://localhost:3000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 60s
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: "\${GRAFANA_MEM_LIMIT:-512m}"
    depends_on:
      - prometheus
      - loki
      - alertmanager
EOF
}

# ----------------------------------------------------------------------------
# 13. Pull images and validate configs with the exact pinned binaries
# ----------------------------------------------------------------------------

pull_images() {
    log "Pulling images..."
    # Pull failures are tolerated (air-gapped hosts with pre-loaded images);
    # what matters is that every pinned image is present afterwards.
    compose pull --quiet --ignore-pull-failures >/dev/null 2>&1 || true
    local img missing=()
    for img in "${PROMETHEUS_IMAGE}" "${ALERTMANAGER_IMAGE}" "${BLACKBOX_IMAGE}" "${NODE_EXPORTER_IMAGE}" \
               "${POSTGRES_EXPORTER_IMAGE}" "${LOKI_IMAGE}" "${GRAFANA_IMAGE}"; do
        docker image inspect "${img}" &>/dev/null || missing+=("${img}")
    done
    if (( ${#missing[@]} )); then
        err "Images not available (pull failed and not present locally):"
        printf '    %s\n' "${missing[@]}" >&2
        die "Check access to Docker Hub, or pre-load the images (see README: Air-gapped hosts)."
    fi
}

# Run a validator; on failure print its full output and abort.
check_or_die() {
    local what="$1" out; shift
    if ! out="$("$@" 2>&1)"; then
        err "${what} is invalid:"
        printf '%s\n' "${out}" | sed 's/^/    /' >&2
        die "Fix the problem above and re-run. Running services were NOT reloaded and keep their previous config."
    fi
}

validate_configs() {
    log "Validating generated configs with the pinned binaries..."
    local run=(docker run --rm --network none)

    check_or_die "prometheus.yml / rule files" "${run[@]}" -v "${BASE_DIR}/prometheus:/etc/prometheus:ro" \
        --entrypoint promtool "${PROMETHEUS_IMAGE}" check config /etc/prometheus/prometheus.yml
    check_or_die "alertmanager.yml" "${run[@]}" -v "${BASE_DIR}/alertmanager:/etc/alertmanager:ro" \
        --entrypoint amtool "${ALERTMANAGER_IMAGE}" check-config /etc/alertmanager/alertmanager.yml
    check_or_die "blackbox.yml" "${run[@]}" -v "${BASE_DIR}/blackbox:/etc/blackbox_exporter:ro" \
        "${BLACKBOX_IMAGE}" --config.file=/etc/blackbox_exporter/blackbox.yml --config.check
    check_or_die "loki-config.yml" "${run[@]}" -v "${BASE_DIR}/loki:/etc/loki:ro" \
        "${LOKI_IMAGE}" -config.file=/etc/loki/loki-config.yml -verify-config
    check_or_die "docker-compose.yml" compose config --quiet
    log "All configs are valid."
}

# ----------------------------------------------------------------------------
# 14. Prometheus runs as nobody (65534). A TSDB volume that already contains
#     root-owned files (e.g. written by a Prometheus that ran as root) is
#     chowned once, otherwise Prometheus cannot write to it.
# ----------------------------------------------------------------------------

migrate_prometheus_volume() {
    local vol="${COMPOSE_PROJECT}_prometheus_data" foreign
    docker volume inspect "${vol}" &>/dev/null || return 0

    # Check every entry, not just the volume root: docker initialises a new
    # volume's root with the image's ownership (65534) while the files written
    # by a root-run Prometheus inside it stay root-owned.
    foreign="$(docker run --rm --network none --user 0 --entrypoint sh \
        -v "${vol}:/prometheus" "${PROMETHEUS_IMAGE}" -c 'find /prometheus ! -user 65534 | head -n 1')"
    [[ -z "${foreign}" ]] && return 0

    log "Fixing ownership of ${vol} to 65534 (Prometheus runs as non-root)..."
    compose stop prometheus >/dev/null 2>&1 || true
    docker run --rm --network none --user 0 --entrypoint chown \
        -v "${vol}:/prometheus" "${PROMETHEUS_IMAGE}" -R 65534:65534 /prometheus
}

# ----------------------------------------------------------------------------
# 15. Deploy and apply config changes without unnecessary restarts
# ----------------------------------------------------------------------------

# Hash of everything a service reads from ${BASE_DIR}.
config_hash() {
    local -a paths
    case "$1" in
        prometheus)        paths=(prometheus) ;;
        alertmanager)      paths=(alertmanager) ;;
        blackbox-exporter) paths=(blackbox) ;;
        loki)              paths=(loki) ;;
        grafana)           paths=(grafana/provisioning grafana/tls) ;;  # dashboards: provider polls every 30s
    esac
    (cd "${BASE_DIR}" && find "${paths[@]}" -type f -print0 | sort -z | xargs -0 -r sha256sum) \
        | sha256sum | cut -d' ' -f1
}

declare -A PRE_IDS=()
declare -A OLD_HASHES=()

snapshot_state() {
    local svc line
    for svc in "${CONFIG_SERVICES[@]}"; do
        PRE_IDS["${svc}"]="$(compose ps -q "${svc}" 2>/dev/null || true)"
    done
    if [[ -f "${STATE_DIR}/config-hashes" ]]; then
        while IFS='=' read -r svc line; do
            if [[ -n "${svc}" ]]; then OLD_HASHES["${svc}"]="${line}"; fi
        done < "${STATE_DIR}/config-hashes"
    fi
}

# Wait until <service> reports its config reload as successful via its own
# *_config_last_reload_successful metric.
verify_reload() {
    local svc="$1" port metric
    case "${svc}" in
        prometheus)        port=9090; metric=prometheus_config_last_reload_successful ;;
        alertmanager)      port=9093; metric=alertmanager_config_last_reload_successful ;;
        blackbox-exporter) port=9115; metric=blackbox_exporter_config_last_reload_successful ;;
    esac
    for _ in $(seq 1 15); do
        if compose exec -T "${svc}" wget -qO- "http://localhost:${port}/metrics" 2>/dev/null \
            | grep -qE "^${metric} 1(\.0+)?$"; then
            return 0
        fi
        sleep 1
    done
    die "${svc} rejected the new config (${metric} != 1). It keeps running with the previous config. Check: docker compose logs ${svc}"
}

deploy_stack() {
    log "Starting stack (docker compose up --wait)..."
    if ! compose up -d --remove-orphans --wait --wait-timeout "${WAIT_TIMEOUT}"; then
        compose ps
        die "docker compose up failed or services did not become healthy within ${WAIT_TIMEOUT}s. Inspect: cd ${BASE_DIR} && docker compose logs <service>"
    fi

    # Services that were NOT recreated by `up` still run the old in-memory
    # config. Reload (SIGHUP) or restart only those whose files changed.
    local svc new_hash post_id changed=0
    : > "${STATE_DIR}/config-hashes.new"
    for svc in "${CONFIG_SERVICES[@]}"; do
        new_hash="$(config_hash "${svc}")"
        post_id="$(compose ps -q "${svc}")"
        if [[ -n "${PRE_IDS[${svc}]}" && "${PRE_IDS[${svc}]}" == "${post_id}" \
              && "${new_hash}" != "${OLD_HASHES[${svc}]:-}" ]]; then
            if [[ "${HUP_SERVICES}" == *" ${svc} "* ]]; then
                log "Config of ${svc} changed: reloading (SIGHUP, no downtime)..."
                compose kill -s SIGHUP "${svc}" >/dev/null
                verify_reload "${svc}"
            else
                log "Config of ${svc} changed: restarting..."
                compose restart "${svc}" >/dev/null
                changed=1
            fi
        fi
        echo "${svc}=${new_hash}" >> "${STATE_DIR}/config-hashes.new"
    done

    if (( changed )); then
        compose up -d --wait --wait-timeout "${WAIT_TIMEOUT}" >/dev/null \
            || die "A restarted service did not become healthy. Inspect: cd ${BASE_DIR} && docker compose logs"
    fi
    mv "${STATE_DIR}/config-hashes.new" "${STATE_DIR}/config-hashes"
    compose ps
}

# ----------------------------------------------------------------------------
# 15b. Restrict who can reach Loki's push port.
#      Docker-published ports bypass UFW / the INPUT chain, so the filter lives
#      in DOCKER-USER (traversed by all forwarded traffic to containers). Only
#      connections whose ORIGINAL destination port is LOKI_PORT are matched;
#      traffic between containers on docker bridges (Grafana/Prometheus -> Loki)
#      is never affected. A oneshot systemd unit re-applies the rules on boot
#      and whenever docker.service (re)starts.
# ----------------------------------------------------------------------------

FW_SCRIPT="/usr/local/sbin/observability-firewall"
FW_UNIT="/etc/systemd/system/observability-firewall.service"

configure_loki_firewall() {
    local -a list=()
    local cidr allowed=""
    IFS=',' read -ra list <<< "${LOKI_ALLOWED_CIDRS:-}"
    for cidr in "${list[@]}"; do
        cidr="$(xargs <<< "${cidr}")"
        if [[ -n "${cidr}" ]]; then allowed+="${cidr} "; fi
    done
    allowed="${allowed% }"

    # Remove the previous rules first: port or networks may have changed.
    if [[ -x "${FW_SCRIPT}" ]]; then "${FW_SCRIPT}" remove || true; fi

    if [[ -z "${allowed}" ]]; then
        if [[ -f "${FW_UNIT}" ]]; then
            systemctl disable --now observability-firewall >/dev/null 2>&1 || true
            rm -f "${FW_UNIT}"
            systemctl daemon-reload
        fi
        rm -f "${FW_SCRIPT}"
        warn "LOKI_ALLOWED_CIDRS is empty: Loki (${LOKI_BIND_ADDR}:${LOKI_PORT}) accepts pushes from any host that can reach it."
        return 0
    fi

    command -v iptables &>/dev/null || die "iptables is required to enforce LOKI_ALLOWED_CIDRS."
    log "Restricting Loki :${LOKI_PORT} to: ${allowed}"

    cat <<'EOF' > "${FW_SCRIPT}"
#!/usr/bin/env bash
# Generated by deploy-observability-stack.sh — do not edit, change LOKI_ALLOWED_CIDRS in .env.
# Allows connections to Loki's published port only from the listed networks.
set -euo pipefail
CHAIN=OBS-LOKI
PORT=@PORT@
CIDRS="@CIDRS@"
MATCH=(-p tcp -m conntrack --ctorigdstport "${PORT}" --ctdir ORIGINAL)

apply() {
    iptables -N "${CHAIN}" 2>/dev/null || iptables -F "${CHAIN}"
    iptables -A "${CHAIN}" -i docker0 -j RETURN     # container <-> container traffic
    iptables -A "${CHAIN}" -i br-+ -j RETURN
    local c
    for c in ${CIDRS}; do iptables -A "${CHAIN}" -s "${c}" -j RETURN; done
    iptables -A "${CHAIN}" -j DROP
    iptables -C DOCKER-USER "${MATCH[@]}" -j "${CHAIN}" 2>/dev/null \
        || iptables -I DOCKER-USER 1 "${MATCH[@]}" -j "${CHAIN}"
}

remove() {
    while iptables -D DOCKER-USER "${MATCH[@]}" -j "${CHAIN}" 2>/dev/null; do :; done
    iptables -F "${CHAIN}" 2>/dev/null || true
    iptables -X "${CHAIN}" 2>/dev/null || true
}

case "${1:-apply}" in
    apply)  apply ;;
    remove) remove ;;
    status) iptables -L "${CHAIN}" -n -v ;;
    *)      echo "usage: $0 apply|remove|status" >&2; exit 1 ;;
esac
EOF
    sed -i "s|@PORT@|${LOKI_PORT}|; s|@CIDRS@|${allowed}|" "${FW_SCRIPT}"
    chmod 0750 "${FW_SCRIPT}"

    if [[ -d /run/systemd/system ]]; then
        cat <<EOF > "${FW_UNIT}"
[Unit]
Description=Observability stack: restrict Loki push port to LOKI_ALLOWED_CIDRS
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${FW_SCRIPT} apply
ExecStop=${FW_SCRIPT} remove

[Install]
WantedBy=multi-user.target docker.service
EOF
        systemctl daemon-reload
        systemctl enable observability-firewall >/dev/null 2>&1
        systemctl restart observability-firewall
    else
        "${FW_SCRIPT}" apply
        warn "systemd is not running: Loki firewall rules applied now but will not survive a reboot."
    fi
}

# ----------------------------------------------------------------------------
# 16. Endpoint checks (as seen from the host, through the published ports)
# ----------------------------------------------------------------------------

health_check() {
    log "Checking service endpoints..."
    local int_addr grafana_addr loki_addr failed=0
    int_addr="$(reach_addr "${BIND_ADDR}")"
    grafana_addr="$(reach_addr "${GRAFANA_BIND_ADDR}")"
    loki_addr="$(reach_addr "${LOKI_BIND_ADDR}")"

    local endpoints=(
        "Prometheus|http://${int_addr}:${PROMETHEUS_PORT}/-/ready"
        "Alertmanager|http://${int_addr}:${ALERTMANAGER_PORT}/-/ready"
        "Grafana|https://${grafana_addr}:${GRAFANA_PORT}/api/health"
        "Loki|http://${loki_addr}:${LOKI_PORT}/ready"
        "Blackbox Exporter|http://${int_addr}:${BLACKBOX_PORT}/-/healthy"
        "Node Exporter|http://${HOST_IP}:${NODE_EXPORTER_PORT}/metrics"
        "Postgres Exporter|http://${int_addr}:${POSTGRES_EXPORTER_PORT}/"
    )

    local entry name url
    for entry in "${endpoints[@]}"; do
        name="${entry%%|*}"
        url="${entry##*|}"
        # -k: Grafana's certificate is self-signed.
        if curl -fsSk --max-time 5 "$url" -o /dev/null 2>/dev/null; then
            echo -e "  ${c_green}OK${c_reset}   ${name} (${url})"
        else
            echo -e "  ${c_red}FAIL${c_reset} ${name} (${url})"
            failed=1
        fi
    done

    local pg_up
    pg_up="$(curl -fsS --max-time 10 "http://${int_addr}:${POSTGRES_EXPORTER_PORT}/metrics" 2>/dev/null \
        | awk '$1 == "pg_up" {print $2}' || true)"
    [[ "${pg_up}" == "1" ]] || warn "postgres-exporter cannot reach the database (pg_up=${pg_up:-n/a}). Check POSTGRES_EXPORTER_DSN."

    (( failed == 0 )) || die "One or more endpoints are not reachable from the host."
}

# ----------------------------------------------------------------------------
# 17. Final summary
# ----------------------------------------------------------------------------

print_summary() {
    # Address a human would use from another machine: 0.0.0.0 -> HOST_IP.
    local int_ip grafana_ip loki_ip
    int_ip="${BIND_ADDR}";             [[ "${int_ip}" == "0.0.0.0" ]] && int_ip="${HOST_IP}"
    grafana_ip="${GRAFANA_BIND_ADDR}"; [[ "${grafana_ip}" == "0.0.0.0" ]] && grafana_ip="${HOST_IP}"
    loki_ip="${LOKI_BIND_ADDR}";       [[ "${loki_ip}" == "0.0.0.0" ]] && loki_ip="${HOST_IP}"

    cat <<EOF

===============================================================================
 Observability stack deployed.
===============================================================================
 Stack directory:    ${BASE_DIR}
 Environment file:   ${ENV_FILE}
 Compose file:       ${COMPOSE_FILE}

 Service access:
   Grafana:            https://${grafana_ip}:${GRAFANA_PORT}  (self-signed TLS — browser warning is expected)
                        login: ${GF_SECURITY_ADMIN_USER}
                        password: sudo grep '^GF_SECURITY_ADMIN_PASSWORD=' ${ENV_FILE}
   Prometheus:         http://${int_ip}:${PROMETHEUS_PORT}
   Alertmanager:       http://${int_ip}:${ALERTMANAGER_PORT}
   Blackbox Exporter:  http://${int_ip}:${BLACKBOX_PORT}
   Postgres Exporter:  http://${int_ip}:${POSTGRES_EXPORTER_PORT}/metrics
   Node Exporter:      http://${HOST_IP}:${NODE_EXPORTER_PORT}/metrics
   Loki (push API):    http://${loki_ip}:${LOKI_PORT}/loki/api/v1/push
                        allowed from: ${LOKI_ALLOWED_CIDRS:-any host (LOKI_ALLOWED_CIDRS is empty)}

   Internal services are published on BIND_ADDR=${BIND_ADDR}. From a workstation:
     ssh -L 9090:127.0.0.1:${PROMETHEUS_PORT} -L 9093:127.0.0.1:${ALERTMANAGER_PORT} <user>@${HOST_IP}

 Configuration: edit ${ENV_FILE} and re-run this script. Only services whose
 config changed are reloaded (Prometheus/Alertmanager/Blackbox: SIGHUP, no
 downtime) or restarted (Loki/Grafana).

 Your alert rules:  ${BASE_DIR}/prometheus/alert.rules.yml  (never overwritten)
   Apply after edit: cd ${BASE_DIR} && docker compose kill -s SIGHUP prometheus

 Backups:            sudo bash backup-observability.sh   (see README)

 Useful commands:
   Logs:     cd ${BASE_DIR} && docker compose logs -f [service]
   Status:   cd ${BASE_DIR} && docker compose ps
   Stop:     cd ${BASE_DIR} && docker compose down
===============================================================================
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    check_root
    acquire_lock
    check_os
    install_docker
    create_dirs
    generate_env
    validate_env
    generate_prometheus_config
    generate_alertmanager_config
    generate_blackbox_config
    generate_loki_config
    generate_grafana_tls_cert
    generate_grafana_provisioning
    generate_compose_file
    pull_images
    validate_configs
    snapshot_state
    migrate_prometheus_volume
    deploy_stack
    configure_loki_firewall
    health_check
    print_summary
}

main "$@"
