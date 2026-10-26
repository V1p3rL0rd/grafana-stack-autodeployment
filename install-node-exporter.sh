#!/usr/bin/env bash
###############################################################################
# install-node-exporter.sh
#
# Installs Prometheus node_exporter as a hardened systemd service on a client
# host, so the central Prometheus can scrape it.
#
# Usage:
#   sudo ./install-node-exporter.sh [--listen ADDR:PORT] [--allow-from CIDR] [--version X.Y.Z]
#
#   --listen      Address to listen on (default :9100 — all interfaces).
#                 Prefer the host's LAN/VPN IP, e.g. 10.0.0.15:9100.
#   --allow-from  If UFW is active, allow this CIDR (the observability
#                 server, e.g. 10.0.0.5/32) to reach the port.
#   --version     node_exporter version (default 1.8.2).
#
# Idempotent: re-running with the same version skips the download and only
# re-applies the unit file; a different version upgrades in place.
###############################################################################

set -Eeuo pipefail

VERSION="1.8.2"
LISTEN=":9100"
ALLOW_FROM=""
BIN="/usr/local/bin/node_exporter"
UNIT="/etc/systemd/system/node_exporter.service"
SVC_USER="node_exporter"

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }
trap 'die "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --listen)     LISTEN="${2:?--listen needs a value}"; shift 2 ;;
        --allow-from) ALLOW_FROM="${2:?--allow-from needs a value}"; shift 2 ;;
        --version)    VERSION="${2:?--version needs a value}"; shift 2 ;;
        -h|--help)    usage 0 ;;
        *)            warn "Unknown argument: $1"; usage 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid --version '${VERSION}'"
[[ "${LISTEN}" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3})?:[0-9]{1,5}$ ]] || die "Invalid --listen '${LISTEN}' (expected IP:PORT or :PORT)"
[[ -z "${ALLOW_FROM}" || "${ALLOW_FROM}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || die "Invalid --allow-from '${ALLOW_FROM}'"
command -v curl >/dev/null || die "curl is required (apt-get install -y curl)"

case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    armv7l)  ARCH=armv7 ;;
    *)       die "Unsupported architecture: $(uname -m)" ;;
esac

# --- 1. service user (no login, no home) -------------------------------------
if ! id "${SVC_USER}" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${SVC_USER}"
    log "Created system user ${SVC_USER}"
fi

# --- 2. binary (download + SHA256 verification, skip if already installed) ---
installed="$("${BIN}" --version 2>/dev/null | awk 'NR == 1 {print $3}' || true)"
if [[ "${installed}" == "${VERSION}" ]]; then
    log "node_exporter ${VERSION} already installed, skipping download."
else
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    name="node_exporter-${VERSION}.linux-${ARCH}"
    base="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}"
    log "Downloading ${name}.tar.gz ..."
    curl -fsSL --retry 3 -o "${tmp}/${name}.tar.gz" "${base}/${name}.tar.gz"
    curl -fsSL --retry 3 -o "${tmp}/sha256sums.txt" "${base}/sha256sums.txt"
    (cd "${tmp}" && grep " ${name}.tar.gz\$" sha256sums.txt | sha256sum -c --quiet -) \
        || die "SHA256 verification failed for ${name}.tar.gz"
    tar -xzf "${tmp}/${name}.tar.gz" -C "${tmp}"
    # Owned by root: the service account must not be able to modify its own binary.
    install -m 0755 -o root -g root "${tmp}/${name}/node_exporter" "${BIN}"
    log "Installed node_exporter ${VERSION} (was: ${installed:-none})"
fi

# --- 3. hardened systemd unit -------------------------------------------------
unit_content="[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
ExecStart=${BIN} \\
    --web.listen-address=${LISTEN} \\
    --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc|run/docker|var/lib/docker|snap)(\$\$|/)
Restart=on-failure
RestartSec=5s

# Hardening: read-only view of the system, no privilege escalation.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
"

if [[ ! -f "${UNIT}" ]] || ! diff -q <(printf '%s' "${unit_content}") "${UNIT}" &>/dev/null; then
    printf '%s' "${unit_content}" > "${UNIT}"
    systemctl daemon-reload
    log "Unit file written: ${UNIT}"
fi
systemctl enable node_exporter >/dev/null 2>&1
systemctl restart node_exporter

# --- 4. firewall (optional) ---------------------------------------------------
port="${LISTEN##*:}"
if [[ -n "${ALLOW_FROM}" ]]; then
    if command -v ufw &>/dev/null && ufw status | grep -q '^Status: active'; then
        ufw allow from "${ALLOW_FROM}" to any port "${port}" proto tcp comment 'node_exporter' >/dev/null
        log "UFW: allowed ${ALLOW_FROM} -> tcp/${port}"
    else
        warn "--allow-from given but UFW is not active; configure your firewall manually."
    fi
fi

# --- 5. verify ----------------------------------------------------------------
check_addr="${LISTEN%:*}"; [[ -z "${check_addr}" ]] && check_addr="127.0.0.1"
for _ in $(seq 1 10); do
    if curl -fsS --max-time 2 "http://${check_addr}:${port}/metrics" -o /dev/null 2>/dev/null; then
        log "node_exporter is up: http://${check_addr}:${port}/metrics"
        log "Add '<this-host-ip>:${port}' to NODE_EXPORTER_TARGETS on the observability server and re-run the deploy script."
        exit 0
    fi
    sleep 1
done
systemctl status node_exporter --no-pager || true
die "node_exporter did not respond on ${check_addr}:${port}"
