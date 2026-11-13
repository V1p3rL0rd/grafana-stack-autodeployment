#!/usr/bin/env bash
###############################################################################
# deploy-observability-stack.sh
#
# Production deployment of an observability stack on Ubuntu 24.04 LTS:
#   - Prometheus          metrics TSDB + alert rule evaluation
#   - Alertmanager        alert routing (Telegram)
#   - Blackbox Exporter   HTTP(S) / ICMP probes (self-signed TLS supported)
#   - Node Exporter       host metrics
#   - Grafana             dashboards (datasources auto-provisioned)
#   - Traefik             the ONLY externally published service: HTTPS :443
#                         (self-signed cert, 5 years) -> Grafana.
#                         Everything else is loopback-only or unpublished.
#
# Extra exporters (postgres, redis, snmp, ...) are added without editing this
# script: docker-compose.override.yml + prometheus/targets/*.yml (see README).
#
# All services run via the docker compose plugin.
#
# Usage:
#   sudo bash deploy-observability-stack.sh
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

# Image versions
PROMETHEUS_VERSION="v2.53.5"
ALERTMANAGER_VERSION="v0.27.0"
BLACKBOX_VERSION="v0.25.0"
NODE_EXPORTER_VERSION="v1.8.2"
GRAFANA_VERSION="11.1.13"
TRAEFIK_VERSION="v3.7.18"

PROMETHEUS_IMAGE="prom/prometheus:${PROMETHEUS_VERSION}"
ALERTMANAGER_IMAGE="prom/alertmanager:${ALERTMANAGER_VERSION}"
BLACKBOX_IMAGE="prom/blackbox-exporter:${BLACKBOX_VERSION}"
NODE_EXPORTER_IMAGE="prom/node-exporter:${NODE_EXPORTER_VERSION}"
GRAFANA_IMAGE="grafana/grafana:${GRAFANA_VERSION}"
TRAEFIK_IMAGE="traefik:${TRAEFIK_VERSION}"

# Ports published on the host
PROMETHEUS_PORT_DEFAULT=9090
ALERTMANAGER_PORT_DEFAULT=9093
BLACKBOX_PORT_DEFAULT=9115
NODE_EXPORTER_PORT_DEFAULT=9100

# Traefik TLS certificate
TLS_CERT_DAYS=1825          # 5 years
TLS_RENEW_BEFORE_DAYS=30    # regenerate automatically when fewer days are left

CONFIG_SERVICES=(prometheus alertmanager blackbox-exporter grafana traefik)
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

OVERRIDE_FILE="${BASE_DIR}/docker-compose.override.yml"   # yours: extra exporters, never overwritten
compose() {
    local -a files=(-f "${COMPOSE_FILE}")
    [[ -f "${OVERRIDE_FILE}" ]] && files+=(-f "${OVERRIDE_FILE}")
    docker compose --project-directory "${BASE_DIR}" "${files[@]}" "$@"
}

# ----------------------------------------------------------------------------
# Safe .env loader
# ----------------------------------------------------------------------------
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

reach_addr() {
    local bind="$1"
    [[ "${bind}" == "0.0.0.0" || -z "${bind}" ]] && bind="127.0.0.1"
    echo "${bind}"
}

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
# 3. Detect host IP
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
        "${BASE_DIR}/prometheus/targets" \
        "${BASE_DIR}/grafana/provisioning/datasources" \
        "${BASE_DIR}/grafana/provisioning/dashboards" \
        "${BASE_DIR}/grafana/dashboards" \
        "${BASE_DIR}/grafana/tls" \
        "${BASE_DIR}/traefik/dynamic"
    install -d -m 0755 "${BASE_DIR}/traefik/certs"
    install -d -m 0700 "${STATE_DIR}"
}

# ----------------------------------------------------------------------------
# 5. Generate and validate .env
# ----------------------------------------------------------------------------

ensure_env_var() {
    local key="$1" default_value="$2" comment="${3:-}"
    if ! grep -qE "^${key}=" "${ENV_FILE}" 2>/dev/null; then
        [[ -n "$comment" ]] && echo -e "\n${comment}" >> "${ENV_FILE}"
        echo "${key}=${default_value}" >> "${ENV_FILE}"
        log "Added new variable to ${ENV_FILE}: ${key}"
    fi
}

ensure_new_env_vars() {
    ensure_env_var "BIND_ADDR" "127.0.0.1"
    ensure_env_var "TRAEFIK_BIND_ADDR" "0.0.0.0" \
        "# Traefik is the only service published outside the host (HTTPS -> Grafana)."
    ensure_env_var "TRAEFIK_HTTPS_PORT" "443"
    ensure_env_var "TRAEFIK_HTTP_PORT" "80"
    ensure_env_var "PUBLIC_HOST" "${HOST_IP:-127.0.0.1}" \
        "# Name/IP users type in the browser: certificate CN and Grafana root_url."
    ensure_env_var "TLS_EXTRA_SANS" "" \
        "# Extra certificate names, comma-separated (DNS names or IPs). Changing it re-issues the cert."
    ensure_env_var "NODE_EXPORTER_LISTEN_ADDR" "" \
        "# Local node-exporter listen IP. Empty = docker0 gateway (not reachable from the LAN)."
    ensure_env_var "TELEGRAM_BOT_TOKEN" "CHANGE_ME_telegram_bot_token"
    ensure_env_var "TELEGRAM_CHAT_ID" "CHANGE_ME_telegram_chat_id"
    ensure_env_var "BLACKBOX_ICMP_TARGETS" ""
    ensure_env_var "PROMETHEUS_RETENTION_SIZE" "0"
    ensure_env_var "ALERTMANAGER_EXTERNAL_URL" ""
}

generate_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        log ".env already exists, supplementing with missing variables: ${ENV_FILE}"
        chmod 600 "${ENV_FILE}"
        load_env
        ensure_new_env_vars
        load_env
        return 0
    fi

    log "Generating ${ENV_FILE}..."
    local host_ip grafana_admin_pass
    host_ip="$(detect_host_ip)"
    grafana_admin_pass="$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-20)"

    install -m 600 /dev/null "${ENV_FILE}"
    cat <<EOF > "${ENV_FILE}"
PROMETHEUS_PORT=${PROMETHEUS_PORT_DEFAULT}
ALERTMANAGER_PORT=${ALERTMANAGER_PORT_DEFAULT}
BLACKBOX_PORT=${BLACKBOX_PORT_DEFAULT}
NODE_EXPORTER_PORT=${NODE_EXPORTER_PORT_DEFAULT}

HOST_IP=${host_ip}
BIND_ADDR=127.0.0.1

# Traefik: the only service published outside the host
TRAEFIK_BIND_ADDR=0.0.0.0
TRAEFIK_HTTPS_PORT=443
TRAEFIK_HTTP_PORT=80
PUBLIC_HOST=${host_ip}
TLS_EXTRA_SANS=

NODE_EXPORTER_LISTEN_ADDR=

GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=${grafana_admin_pass}

TELEGRAM_BOT_TOKEN=CHANGE_ME_telegram_bot_token
TELEGRAM_CHAT_ID=CHANGE_ME_telegram_chat_id
ALERTMANAGER_EXTERNAL_URL=

BLACKBOX_TARGETS=https://192.168.1.10,https://192.168.1.20:8443,http://192.168.1.30:80
BLACKBOX_ICMP_TARGETS=
NODE_EXPORTER_TARGETS=${host_ip}:9100

PROMETHEUS_RETENTION=30d
PROMETHEUS_RETENTION_SIZE=0
EOF

    log ".env file created (mode 600)."
    load_env
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_dns()  { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62})(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}))*$ ]]; }

validate_env() {
    local key item
    for key in HOST_IP BIND_ADDR TRAEFIK_BIND_ADDR; do
        is_ipv4 "${!key:-}" || die "${key}='${!key:-}' in ${ENV_FILE} is not an IPv4 address."
    done
    [[ -z "${NODE_EXPORTER_LISTEN_ADDR:-}" ]] || is_ipv4 "${NODE_EXPORTER_LISTEN_ADDR}" \
        || die "NODE_EXPORTER_LISTEN_ADDR='${NODE_EXPORTER_LISTEN_ADDR}' is not an IPv4 address."
    for key in PROMETHEUS_PORT ALERTMANAGER_PORT BLACKBOX_PORT NODE_EXPORTER_PORT TRAEFIK_HTTPS_PORT TRAEFIK_HTTP_PORT; do
        [[ "${!key:-}" =~ ^[0-9]+$ ]] && (( ${!key} >= 1 && ${!key} <= 65535 )) || die "${key}='${!key:-}' is not a valid port."
    done
    (( TRAEFIK_HTTPS_PORT != TRAEFIK_HTTP_PORT )) || die "TRAEFIK_HTTPS_PORT and TRAEFIK_HTTP_PORT must differ."

    is_ipv4 "${PUBLIC_HOST:-}" || is_dns "${PUBLIC_HOST:-}" || die "PUBLIC_HOST='${PUBLIC_HOST:-}' is neither an IPv4 address nor a DNS name."
    IFS=',' read -ra _sans <<< "${TLS_EXTRA_SANS:-}"
    for item in "${_sans[@]}"; do
        item="$(xargs <<< "${item}")"; [[ -z "${item}" ]] && continue
        is_ipv4 "${item}" || is_dns "${item}" || die "TLS_EXTRA_SANS: '${item}' is neither an IPv4 address nor a DNS name."
    done

    return 0
}

# Local node-exporter (host network) listens on the docker0 gateway: containers
# reach it, LAN hosts do not (the address is not routed outside this host).
resolve_node_exporter_addr() {
    if [[ -n "${NODE_EXPORTER_LISTEN_ADDR:-}" ]]; then
        NE_ADDR="${NODE_EXPORTER_LISTEN_ADDR}"
    else
        NE_ADDR="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
        is_ipv4 "${NE_ADDR}" || die "Cannot detect the docker0 gateway IP (default bridge disabled?). Set NODE_EXPORTER_LISTEN_ADDR in ${ENV_FILE}."
    fi
    log "Local node-exporter will listen on ${NE_ADDR}:${NODE_EXPORTER_PORT} (instance label stays ${HOST_IP}:${NODE_EXPORTER_PORT})."
}

# ----------------------------------------------------------------------------
# 5.1 Firewall (UFW) configuration for host-mode Node Exporter
# ----------------------------------------------------------------------------

configure_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        log "UFW is active: ensuring Docker bridge network (172.16.0.0/12) can access Node Exporter on port ${NODE_EXPORTER_PORT}..."
        # Idempotent rule addition
        ufw allow from 172.16.0.0/12 to "${NE_ADDR}" port "${NODE_EXPORTER_PORT}" proto tcp comment "Docker bridge to Node Exporter" >/dev/null || true
        log "UFW rule verified: 172.16.0.0/12 -> port ${NODE_EXPORTER_PORT}/tcp"
    fi
}

# ----------------------------------------------------------------------------
# 6. Prometheus configuration and alert rules
# ----------------------------------------------------------------------------

generate_prometheus_config() {
    log "Generating prometheus.yml and stack alert rules..."

    local blackbox_targets_yaml node_targets_yaml icmp_targets_yaml remote_nodes="" item
    blackbox_targets_yaml="$(csv_to_yaml_list "${BLACKBOX_TARGETS:-}" "          ")"
    # The local node-exporter is scraped via NE_ADDR; drop it from the remote list.
    IFS=',' read -ra _nodes <<< "${NODE_EXPORTER_TARGETS:-}"
    for item in "${_nodes[@]}"; do
        item="$(xargs <<< "${item}")"
        [[ -z "${item}" || "${item}" == "${HOST_IP}:${NODE_EXPORTER_PORT}" || "${item}" == "${HOST_IP}" ]] && continue
        remote_nodes+="${item},"
    done
    node_targets_yaml="$(csv_to_yaml_list "${remote_nodes}" "          ")"
    icmp_targets_yaml="$(csv_to_yaml_list "${BLACKBOX_ICMP_TARGETS:-}" "          " host)"

    cat <<EOF > "${BASE_DIR}/prometheus/prometheus.yml"
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
  - /etc/prometheus/alert.rules.yml
  - /etc/prometheus/rules/*.yml

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

  - job_name: grafana
    scheme: https
    tls_config:
      insecure_skip_verify: true
    static_configs:
      - targets: ["grafana:3000"]

  - job_name: traefik
    static_configs:
      - targets: ["traefik:8082"]

  - job_name: node-exporter
    static_configs:
      - targets: ["${NE_ADDR}:${NODE_EXPORTER_PORT}"]
        labels:
          instance: "${HOST_IP}:${NODE_EXPORTER_PORT}"
      - targets:
${node_targets_yaml}

  # Extra exporters: drop a file into prometheus/targets/ (see README).
  # Each file sets its own job label; Prometheus re-reads them without a reload.
  - job_name: extra
    file_sd_configs:
      - files: ["/etc/prometheus/targets/*.yml"]
        refresh_interval: 1m

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

  - job_name: blackbox-traefik-tls
    metrics_path: /probe
    params:
      module: [https_selfsigned]
    static_configs:
      - targets: ["https://traefik:8443/api/health"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - target_label: instance
        replacement: "https://${PUBLIC_HOST}:${TRAEFIK_HTTPS_PORT}"
      - target_label: __address__
        replacement: blackbox-exporter:9115

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

    if [[ ! -f "${BASE_DIR}/prometheus/alert.rules.yml" ]]; then
        cat <<'EOF' > "${BASE_DIR}/prometheus/alert.rules.yml"
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

      - alert: PrometheusNotificationsFailing
        expr: rate(prometheus_notifications_errors_total[5m]) > 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Prometheus cannot deliver alerts to Alertmanager"
          description: "Alerts are not reaching Alertmanager."

      - alert: AlertmanagerConfigReloadFailed
        expr: alertmanager_config_last_reload_successful == 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Alertmanager config reload failed"
          description: "Alertmanager is running with a stale configuration."

      - alert: TraefikTLSCertificateExpiringSoon
        expr: (probe_ssl_earliest_cert_expiry{job="blackbox-traefik-tls"} - time()) / 86400 < 21
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Traefik TLS certificate expires in {{ $value | humanize }} days"
          description: "Re-run deploy-observability-stack.sh: it re-issues the certificate automatically when fewer than 30 days are left."

      - alert: TraefikHighServerErrorRate
        expr: |
          sum by (service) (rate(traefik_service_requests_total{code=~"5.."}[5m]))
            / sum by (service) (rate(traefik_service_requests_total[5m])) > 0.05
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Traefik: >5% 5xx responses for {{ $labels.service }}"
          description: "Check the backend: docker compose logs traefik grafana"

      - alert: AlertmanagerNotificationsFailing
        expr: rate(alertmanager_notifications_failed_total[5m]) > 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Alertmanager fails to send notifications via {{ $labels.integration }}"
          description: "Check the Telegram token/chat_id and outbound access to api.telegram.org."
EOF
}

# ----------------------------------------------------------------------------
# 7. Alertmanager configuration
# ----------------------------------------------------------------------------

generate_alertmanager_config() {
    local telegram_ready=true
    [[ -z "${TELEGRAM_BOT_TOKEN:-}" || "${TELEGRAM_BOT_TOKEN}" == "CHANGE_ME_telegram_bot_token" ]] && telegram_ready=false
    [[ "${TELEGRAM_CHAT_ID:-}" =~ ^-?[0-9]+$ ]] || telegram_ready=false

    local secrets_dir="${BASE_DIR}/alertmanager/secrets"
    local token_file="${secrets_dir}/telegram_bot_token"
    install -d -m 0500 -o 65534 -g 65534 "${secrets_dir}"

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
        install -m 0400 -o 65534 -g 65534 /dev/null "${token_file}"
        printf '%s' "${TELEGRAM_BOT_TOKEN}" > "${token_file}"
        cat <<EOF > "${BASE_DIR}/alertmanager/alertmanager.yml"
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
          {{ if eq .Status "firing" }}<b>Fired At:</b> {{ (.StartsAt.Add 10800000000000).Format "2006-01-02 15:04:05" }} MSK{{ else }}<b>Resolved At:</b> {{ (.EndsAt.Add 10800000000000).Format "2006-01-02 15:04:05" }} MSK{{ end }}
          {{ end }}

${inhibit}
EOF
    else
        warn "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID are not set or invalid in ${ENV_FILE}."
        rm -f "${token_file}"
        cat <<EOF > "${BASE_DIR}/alertmanager/alertmanager.yml"
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
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []
      method: GET
      preferred_ip_protocol: ip4
      tls_config:
        insecure_skip_verify: false

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
EOF
}

# ----------------------------------------------------------------------------
# 10. Grafana TLS
# ----------------------------------------------------------------------------

generate_grafana_tls_cert() {
    local cert_dir="${BASE_DIR}/grafana/tls"
    local cert_file="${cert_dir}/grafana.crt"
    local key_file="${cert_dir}/grafana.key"

    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        log "Grafana TLS certificate already exists: ${cert_file}"
    else
        log "Generating self-signed TLS certificate for Grafana (CN=${HOST_IP})..."
        openssl req -x509 -nodes -newkey rsa:4096 \
            -days 3650 \
            -keyout "$key_file" \
            -out "$cert_file" \
            -subj "/CN=${HOST_IP}" \
            -addext "subjectAltName=IP:${HOST_IP},DNS:localhost,DNS:grafana" \
            2>/dev/null
    fi
    chown 472:472 "$key_file" "$cert_file"
    chmod 640 "$key_file"
    chmod 644 "$cert_file"
}

# ----------------------------------------------------------------------------
# 10.1 Traefik: self-signed certificate (5 years), static + dynamic config
# ----------------------------------------------------------------------------

build_sans() {
    local -a out=() seen=()
    local item s
    add() {
        local v="$1" t
        is_ipv4 "${v}" && t="IP:${v}" || t="DNS:${v}"
        for s in "${seen[@]}"; do [[ "${s}" == "${t}" ]] && return 0; done
        seen+=("${t}"); out+=("${t}")
    }
    add "${PUBLIC_HOST}"; add "${HOST_IP}"; add "127.0.0.1"; add "localhost"
    IFS=',' read -ra _extra <<< "${TLS_EXTRA_SANS:-}"
    for item in "${_extra[@]}"; do
        item="$(xargs <<< "${item}")"; [[ -n "${item}" ]] && add "${item}"
    done
    local IFS=','; echo "${out[*]}"
}

generate_traefik_cert() {
    local dir="${BASE_DIR}/traefik/certs" crt key sans reason=""
    crt="${dir}/tls.crt"; key="${dir}/tls.key"
    sans="$(build_sans)"

    if [[ ! -s "${crt}" || ! -s "${key}" ]]; then
        reason="not present"
    elif ! openssl x509 -in "${crt}" -noout -checkend $(( TLS_RENEW_BEFORE_DAYS * 86400 )) >/dev/null; then
        reason="expires within ${TLS_RENEW_BEFORE_DAYS} days"
    elif [[ "$(cat "${STATE_DIR}/traefik-cert.sans" 2>/dev/null)" != "${sans}" ]]; then
        reason="SAN list changed"
    elif [[ "$(openssl x509 -in "${crt}" -noout -pubkey)" != "$(openssl pkey -in "${key}" -pubout 2>/dev/null)" ]]; then
        reason="certificate and key do not match"
    fi

    if [[ -n "${reason}" ]]; then
        log "Issuing self-signed Traefik certificate (${TLS_CERT_DAYS} days, CN=${PUBLIC_HOST}, SAN=${sans}): ${reason}."
        if [[ -s "${crt}" ]]; then
            local arch="${dir}/archive"; install -d -m 0700 "${arch}"
            mv -f "${crt}" "${arch}/tls-$(date +%Y%m%d%H%M%S).crt"
            [[ -f "${key}" ]] && mv -f "${key}" "${arch}/tls-$(date +%Y%m%d%H%M%S).key"
        fi
        local tmpk tmpc
        tmpk="$(mktemp "${dir}/.key.XXXXXX")"; tmpc="$(mktemp "${dir}/.crt.XXXXXX")"
        openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days "${TLS_CERT_DAYS}" \
            -keyout "${tmpk}" -out "${tmpc}" \
            -subj "/CN=${PUBLIC_HOST}" \
            -addext "subjectAltName=${sans}" \
            -addext "basicConstraints=critical,CA:FALSE" \
            -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
            -addext "extendedKeyUsage=serverAuth" 2>/dev/null
        mv -f "${tmpk}" "${key}"; mv -f "${tmpc}" "${crt}"
        printf '%s' "${sans}" > "${STATE_DIR}/traefik-cert.sans"
    else
        log "Traefik certificate is valid until $(openssl x509 -in "${crt}" -noout -enddate | cut -d= -f2)."
    fi
    chown 65534:65534 "${key}"; chmod 0400 "${key}"
    chown root:root "${crt}"; chmod 0444 "${crt}"
}

generate_traefik_config() {
    log "Generating Traefik config..."
    local https_suffix=""
    [[ "${TRAEFIK_HTTPS_PORT}" != "443" ]] && https_suffix=":${TRAEFIK_HTTPS_PORT}"

    cat <<EOF > "${BASE_DIR}/traefik/traefik.yml"
# Generated by deploy-observability-stack.sh — do not edit.
global:
  checkNewVersion: false
  sendAnonymousUsage: false

log:
  level: INFO
  format: json

accessLog:
  format: json
  fields:
    headers:
      defaultMode: drop          # never log Authorization / cookies

# Unprivileged ports inside the container (runs as 65534); the host maps
# TRAEFIK_HTTPS_PORT -> 8443 and TRAEFIK_HTTP_PORT -> 8080.
entryPoints:
  web:
    address: ":8080"
    http:
      redirections:
        entryPoint:
          to: ":${TRAEFIK_HTTPS_PORT}"
          scheme: https
          permanent: true
  websecure:
    address: ":8443"
    http:
      tls: {}
    transport:
      respondingTimeouts:
        readTimeout: 120s
        idleTimeout: 180s
  # Internal only (not published): /ping for the healthcheck, /metrics for Prometheus.
  internal:
    address: ":8082"

ping:
  entryPoint: internal

metrics:
  prometheus:
    entryPoint: internal
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true

# No Docker provider: Traefik never gets the Docker socket.
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true
EOF

    cat <<EOF > "${BASE_DIR}/traefik/dynamic/routes.yml"
# Generated by deploy-observability-stack.sh — do not edit.
tls:
  options:
    default:
      minVersion: VersionTLS12
      sniStrict: false             # clients connecting by IP send no SNI
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/certs/tls.crt
        keyFile: /etc/traefik/certs/tls.key

http:
  routers:
    grafana:
      entryPoints: [websecure]
      rule: "PathPrefix(\`/\`)"
      priority: 1
      service: grafana
      middlewares:
        - security-headers
      tls: {}

  middlewares:
    security-headers:
      headers:
        contentTypeNosniff: true
        customFrameOptionsValue: SAMEORIGIN
        referrerPolicy: strict-origin-when-cross-origin
        # No HSTS on purpose: with a self-signed certificate HSTS makes the
        # browser's certificate warning non-bypassable for that hostname.
        customResponseHeaders:
          Server: ""
          X-Powered-By: ""

  services:
    grafana:
      loadBalancer:
        serversTransport: grafana-tls
        servers:
          - url: "https://grafana:3000"

  # Traefik -> Grafana stays TLS, verified against Grafana's own certificate.
  serversTransports:
    grafana-tls:
      serverName: grafana
      rootCAs:
        - /etc/traefik/upstream/grafana.crt
EOF
    chmod 0644 "${BASE_DIR}/traefik/traefik.yml" "${BASE_DIR}/traefik/dynamic/routes.yml"
    EDGE_URL="https://${PUBLIC_HOST}${https_suffix}"
    GRAFANA_ROOT_URL="${EDGE_URL}/"
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
      - "--cluster.listen-address="
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

  blackbox-exporter:
    <<: *default-service
    image: ${BLACKBOX_IMAGE}
    container_name: blackbox-exporter
    read_only: true
    cap_drop: [ALL]
    cap_add: [NET_RAW]
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
      - "--web.listen-address=${NE_ADDR}:\${NODE_EXPORTER_PORT}"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://${NE_ADDR}:\${NODE_EXPORTER_PORT}/metrics"]
      interval: 15s
      timeout: 5s
      retries: 4
      start_period: 10s

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
      GF_SERVER_ROOT_URL: "${GRAFANA_ROOT_URL}"
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
    # No published port: reachable only through Traefik.
    networks: [monitoring]
    healthcheck:
      test: ["CMD", "curl", "-fsk", "-o", "/dev/null", "https://localhost:3000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 60s
    depends_on:
      - prometheus
      - alertmanager

  traefik:
    <<: *default-service
    image: ${TRAEFIK_IMAGE}
    container_name: traefik
    user: "65534:65534"
    read_only: true
    cap_drop: [ALL]
    command: ["--configFile=/etc/traefik/traefik.yml"]
    volumes:
      - ./traefik:/etc/traefik:ro
      - ./grafana/tls/grafana.crt:/etc/traefik/upstream/grafana.crt:ro
    ports:
      - "\${TRAEFIK_BIND_ADDR}:\${TRAEFIK_HTTPS_PORT}:8443"
      - "\${TRAEFIK_BIND_ADDR}:\${TRAEFIK_HTTP_PORT}:8080"
    networks: [monitoring]
    deploy:
      resources:
        limits:
          memory: \${TRAEFIK_MEM_LIMIT:-256m}
          cpus: "\${TRAEFIK_CPUS:-1.0}"
    healthcheck:
      test: ["CMD", "traefik", "healthcheck", "--configFile=/etc/traefik/traefik.yml"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 10s
    depends_on:
      - grafana
EOF
}

# ----------------------------------------------------------------------------
# 13. Pull images and validate
# ----------------------------------------------------------------------------

pull_images() {
    log "Pulling images..."
    compose pull --quiet --ignore-pull-failures >/dev/null 2>&1 || true
    local img missing=()
    for img in "${PROMETHEUS_IMAGE}" "${ALERTMANAGER_IMAGE}" "${BLACKBOX_IMAGE}" "${NODE_EXPORTER_IMAGE}" \
               "${GRAFANA_IMAGE}" "${TRAEFIK_IMAGE}"; do
        docker image inspect "${img}" &>/dev/null || missing+=("${img}")
    done
    if (( ${#missing[@]} )); then
        err "Images missing: ${missing[*]}"
        die "Check internet connection."
    fi
}

check_or_die() {
    local what="$1" out; shift
    if ! out="$("$@" 2>&1)"; then
        err "${what} is invalid:"
        printf '%s\n' "${out}" | sed 's/^/    /' >&2
        die "Config validation failed."
    fi
}

validate_configs() {
    log "Validating generated configs..."
    local run=(docker run --rm --network none)

    check_or_die "prometheus.yml" "${run[@]}" -v "${BASE_DIR}/prometheus:/etc/prometheus:ro" \
        --entrypoint promtool "${PROMETHEUS_IMAGE}" check config /etc/prometheus/prometheus.yml
    check_or_die "alertmanager.yml" "${run[@]}" -v "${BASE_DIR}/alertmanager:/etc/alertmanager:ro" \
        --entrypoint amtool "${ALERTMANAGER_IMAGE}" check-config /etc/alertmanager/alertmanager.yml
    check_or_die "blackbox.yml" "${run[@]}" -v "${BASE_DIR}/blackbox:/etc/blackbox_exporter:ro" \
        "${BLACKBOX_IMAGE}" --config.file=/etc/blackbox_exporter/blackbox.yml --config.check
    check_or_die "docker-compose.yml" compose config --quiet
    log "All configs are valid."
}

# ----------------------------------------------------------------------------
# 14. Volume migration & deploy
# ----------------------------------------------------------------------------

migrate_prometheus_volume() {
    local vol="${COMPOSE_PROJECT}_prometheus_data" foreign
    docker volume inspect "${vol}" &>/dev/null || return 0
    foreign="$(docker run --rm --network none --user 0 --entrypoint sh \
        -v "${vol}:/prometheus" "${PROMETHEUS_IMAGE}" -c 'find /prometheus ! -user 65534 | head -n 1')"
    [[ -z "${foreign}" ]] && return 0

    log "Migrating ${vol} ownership to 65534..."
    compose stop prometheus >/dev/null 2>&1 || true
    docker run --rm --network none --user 0 --entrypoint chown \
        -v "${vol}:/prometheus" "${PROMETHEUS_IMAGE}" -R 65534:65534 /prometheus
}

config_hash() {
    local -a paths
    case "$1" in
        prometheus)        paths=(prometheus/prometheus.yml prometheus/alert.rules.yml prometheus/rules) ;;
        alertmanager)      paths=(alertmanager) ;;
        blackbox-exporter) paths=(blackbox) ;;
        grafana)           paths=(grafana/provisioning grafana/tls) ;;
        traefik)           paths=(traefik/traefik.yml traefik/certs/tls.crt grafana/tls/grafana.crt) ;;
    esac
    (cd "${BASE_DIR}" && find "${paths[@]}" -type f -print0 | sort -z | xargs -0 -r sha256sum) \
        | sha256sum | cut -d' ' -f1
}

declare -A PRE_IDS=()
declare -A OLD_HASHES=()

snapshot_state() {
    local svc
    for svc in "${CONFIG_SERVICES[@]}"; do
        PRE_IDS["${svc}"]="$(compose ps -q "${svc}" 2>/dev/null || true)"
    done
    if [[ -f "${STATE_DIR}/config-hashes" ]]; then
        while IFS='=' read -r svc line; do
            [[ -n "${svc}" ]] && OLD_HASHES["${svc}"]="${line}"
        done < "${STATE_DIR}/config-hashes"
    fi
}

deploy_stack() {
    log "Starting stack (docker compose up --wait)..."
    if ! compose up -d --remove-orphans --wait --wait-timeout "${WAIT_TIMEOUT}"; then
        compose ps
        die "docker compose up failed. Check: cd ${BASE_DIR} && docker compose logs"
    fi

    local svc new_hash post_id
    : > "${STATE_DIR}/config-hashes.new"
    for svc in "${CONFIG_SERVICES[@]}"; do
        new_hash="$(config_hash "${svc}")"
        post_id="$(compose ps -q "${svc}")"
        if [[ -n "${PRE_IDS[${svc}]}" && "${PRE_IDS[${svc}]}" == "${post_id}" \
              && "${new_hash}" != "${OLD_HASHES[${svc}]:-}" ]]; then
            if [[ "${HUP_SERVICES}" == *" ${svc} "* ]]; then
                log "Config of ${svc} changed: reloading (SIGHUP)..."
                compose kill -s SIGHUP "${svc}" >/dev/null
            else
                log "Config of ${svc} changed: restarting..."
                compose restart "${svc}" >/dev/null
            fi
        fi
        echo "${svc}=${new_hash}" >> "${STATE_DIR}/config-hashes.new"
    done
    mv "${STATE_DIR}/config-hashes.new" "${STATE_DIR}/config-hashes"
    compose ps
}

# ----------------------------------------------------------------------------
# 15. Endpoint checks (host + cross-container connectivity)
# ----------------------------------------------------------------------------

health_check() {
    log "Checking service endpoints..."
    local int_addr edge_addr failed=0
    int_addr="$(reach_addr "${BIND_ADDR}")"
    edge_addr="$(reach_addr "${TRAEFIK_BIND_ADDR}")"

    local endpoints=(
        "Prometheus|http://${int_addr}:${PROMETHEUS_PORT}/-/ready"
        "Alertmanager|http://${int_addr}:${ALERTMANAGER_PORT}/-/ready"
        "Blackbox Exporter|http://${int_addr}:${BLACKBOX_PORT}/-/healthy"
        "Node Exporter (Host access)|http://${NE_ADDR}:${NODE_EXPORTER_PORT}/metrics"
    )

    local entry name url
    for entry in "${endpoints[@]}"; do
        name="${entry%%|*}"
        url="${entry##*|}"
        if curl -fsSk --max-time 5 "$url" -o /dev/null 2>/dev/null; then
            echo -e "  ${c_green}OK${c_reset}   ${name} (${url})"
        else
            echo -e "  ${c_red}FAIL${c_reset} ${name} (${url})"
            failed=1
        fi
    done

    # Grafana through Traefik, with real certificate verification (SAN must match).
    local cert="${BASE_DIR}/traefik/certs/tls.crt" code
    if curl -fsS --max-time 5 --cacert "${cert}" -o /dev/null "https://${edge_addr}:${TRAEFIK_HTTPS_PORT}/api/health" 2>/dev/null; then
        echo -e "  ${c_green}OK${c_reset}   Grafana via Traefik (https://${edge_addr}:${TRAEFIK_HTTPS_PORT}/api/health, cert verified)"
    else
        echo -e "  ${c_red}FAIL${c_reset} Grafana via Traefik (https://${edge_addr}:${TRAEFIK_HTTPS_PORT}/api/health)"
        failed=1
    fi
    code="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://${edge_addr}:${TRAEFIK_HTTP_PORT}/" 2>/dev/null || true)"
    if [[ "${code}" == "308" || "${code}" == "301" ]]; then
        echo -e "  ${c_green}OK${c_reset}   HTTP :${TRAEFIK_HTTP_PORT} redirects to HTTPS (${code})"
    else
        echo -e "  ${c_red}FAIL${c_reset} HTTP :${TRAEFIK_HTTP_PORT} redirect (got ${code:-no answer})"; failed=1
    fi

    # Critical: verify Prometheus inside the Docker bridge network can reach host-mode Node Exporter
    if compose exec -T prometheus wget -q -T 5 -O /dev/null "http://${NE_ADDR}:${NODE_EXPORTER_PORT}/metrics" 2>/dev/null; then
        echo -e "  ${c_green}OK${c_reset}   Prometheus -> Node Exporter (http://${NE_ADDR}:${NODE_EXPORTER_PORT}/metrics)"
    else
        echo -e "  ${c_red}FAIL${c_reset} Prometheus -> Node Exporter (http://${NE_ADDR}:${NODE_EXPORTER_PORT}/metrics) — check UFW/firewall"
        failed=1
    fi

    # Exposure audit: only Traefik may publish on a non-loopback address.
    local name ports exposed audit_ok=1
    while IFS=$'\t' read -r name ports; do
        [[ "${name}" == "traefik" || -z "${ports}" ]] && continue
        exposed="$(tr ',' '\n' <<< "${ports}" | grep -E -- '->' | grep -Ev '^ *127\.0\.0\.1:' || true)"
        if [[ -n "${exposed}" ]]; then
            echo -e "  ${c_red}FAIL${c_reset} ${name} is published beyond loopback: $(xargs <<< "${exposed}")"
            failed=1; audit_ok=0
        fi
    done < <(compose ps --format '{{.Name}}	{{.Ports}}')
    (( audit_ok )) && echo -e "  ${c_green}OK${c_reset}   Exposure audit: only traefik is published beyond loopback"

    (( failed == 0 )) || die "One or more endpoints are not reachable."
}

# ----------------------------------------------------------------------------
# 16. Summary
# ----------------------------------------------------------------------------

print_summary() {
    cat <<EOF

===============================================================================
 Observability stack successfully deployed & verified.
===============================================================================
 Stack directory:    ${BASE_DIR}
 Environment file:   ${ENV_FILE}

 Service access:
   Grafana:            ${GRAFANA_ROOT_URL}   (login: ${GF_SECURITY_ADMIN_USER})
   TLS certificate:    valid until $(openssl x509 -in "${BASE_DIR}/traefik/certs/tls.crt" -noout -enddate | cut -d= -f2)

 Loopback only (ssh -L): Prometheus :${PROMETHEUS_PORT}, Alertmanager :${ALERTMANAGER_PORT},
                         Blackbox :${BLACKBOX_PORT}
 Docker-internal only:   Grafana, node-exporter (${NE_ADDR}:${NODE_EXPORTER_PORT})
 Extra exporters:        ${OVERRIDE_FILE} + ${BASE_DIR}/prometheus/targets/*.yml
===============================================================================
EOF
}

# ----------------------------------------------------------------------------
# Main execution
# ----------------------------------------------------------------------------

main() {
    check_root
    acquire_lock
    check_os
    install_docker
    create_dirs
    generate_env
    validate_env
    resolve_node_exporter_addr
    configure_firewall
    generate_prometheus_config
    generate_alertmanager_config
    generate_blackbox_config
    generate_grafana_tls_cert
    generate_traefik_cert
    generate_traefik_config
    generate_grafana_provisioning
    generate_compose_file
    pull_images
    validate_configs
    snapshot_state
    migrate_prometheus_volume
    deploy_stack
    health_check
    print_summary
}

main "$@"
