#!/bin/bash
# provision-monitoring-instance.sh - Install and configure Prometheus on the
# out-of-cluster Monitoring_Instance.
#
# What this does, over SSH, to a running EC2 instance:
#   1. installs the Prometheus binary (package if the repo carries one, pinned
#      upstream release tarball otherwise)
#   2. renders k8s/monitoring/prometheus.yml and places it at
#      /etc/prometheus/prometheus.yml
#   3. writes the Grafana Cloud remote_write password to
#      /etc/prometheus/remote_write_password with mode 0600
#   4. installs an enabled systemd unit carrying the local retention flag and
#      binding the web UI to 127.0.0.1 only
#   5. verifies the service is active and answering, on the host
#
# NETWORK EXPOSURE: Prometheus binds 127.0.0.1:9090 and nothing else. No
# inbound port is opened; the UI is deliberately NOT reachable from the
# internet. Operator access is an SSH tunnel:
#   ssh -i <key> -L 9090:127.0.0.1:9090 ec2-user@<public-ip>
# The Prometheus UI has no authentication of its own, which is exactly why the
# loopback bind is load-bearing and must not be widened.
#
# SECRETS: the three Grafana Cloud values are read from the environment only.
# They are never hardcoded, never written anywhere inside the repository,
# never placed in user_data, and never passed as command-line arguments (which
# would expose them in `ps` output and in shell history). The password travels
# over SSH on stdin. All three are masked in every line this script prints.
#
# Usage:
#   export GRAFANA_CLOUD_REMOTE_WRITE_URL='https://prometheus-prod-xx.grafana.net/api/prom/push'
#   export GRAFANA_CLOUD_USERNAME='1234567'
#   export GRAFANA_CLOUD_PASSWORD='glc_...'
#   bash scripts/provision-monitoring-instance.sh
#   bash scripts/provision-monitoring-instance.sh --host <public-ip> --retention 24h
#   MONITORING_HOST=<public-ip> bash scripts/provision-monitoring-instance.sh
#
# Re-running is safe: every step overwrites in place and nothing is duplicated.
#
# Requirements: 2.7, 2.8, 2.13, 11.3, 11.5, 14.13

set -euo pipefail

# --- Configuration (defaults match terraform/variables.tf) ---
CLUSTER_NAME="${CLUSTER_NAME:-eks-istanbul}"
REGION="${REGION:-eu-central-1}"
MONITORING_HOST="${MONITORING_HOST:-}"
SSH_KEY="${SSH_KEY:-}"
SSH_USER="${SSH_USER:-ec2-user}"
# Requirement 2.8: at least 24 hours. Mirrors var.monitoring_local_retention.
RETENTION="${MONITORING_LOCAL_RETENTION:-24h}"

# Pinned on purpose. "latest" would make two runs of this script produce two
# different hosts, and an unverified download at that. The checksums below are
# the official ones published alongside the release.
PROM_VERSION="2.53.3"
PROM_SHA256_AMD64="ebe549477a699c464a0cef0d8d55c0cc9972a1b301fc910b5f260cfc3e08f6a3"
PROM_SHA256_ARM64="36d72895b6369c1b6ee51e897f903edc2a9f41d1bee82c5d517f3179276d3cdc"

SSH_CONNECT_TIMEOUT=15
READY_TIMEOUT=120
READY_INTERVAL=10

while [ $# -gt 0 ]; do
  case "$1" in
    --host)         MONITORING_HOST="${2:-}"; shift 2 ;;
    --ssh-key)      SSH_KEY="${2:-}"; shift 2 ;;
    --ssh-user)     SSH_USER="${2:-}"; shift 2 ;;
    --retention)    RETENTION="${2:-}"; shift 2 ;;
    --cluster-name) CLUSTER_NAME="${2:-}"; shift 2 ;;
    --region)       REGION="${2:-}"; shift 2 ;;
    *) echo "❌ Unknown argument: $1" >&2; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_TEMPLATE="$REPO_ROOT/k8s/monitoring/prometheus.yml"
TERRAFORM_DIR="$REPO_ROOT/terraform"

# --- Secret masking (Requirement 11.5) ---
#
# A fixed mask of exactly 8 characters that shares no character with any real
# value (Requirement 11.5). The alphabet is searched rather than hardcoded so
# the guarantee still holds if a credential happens to contain the first
# candidate character: '*' is used for a token like "glc_abc", but a token
# containing '*' gets '#' instead, and so on.
pick_mask() {
  local all="${GRAFANA_CLOUD_REMOTE_WRITE_URL:-}${GRAFANA_CLOUD_USERNAME:-}${GRAFANA_CLOUD_PASSWORD:-}"
  local i char
  local alphabet='*#%+=~^!?@,;'
  for ((i = 0; i < ${#alphabet}; i++)); do
    char="${alphabet:i:1}"
    case "$all" in
      *"$char"*) continue ;;
    esac
    printf '%s%s%s%s%s%s%s%s' "$char" "$char" "$char" "$char" "$char" "$char" "$char" "$char"
    return 0
  done
  return 1
}

# Refusing to continue is the right failure here: with no safe mask there is no
# way to print progress without leaking a character of a credential.
if ! MASK="$(pick_mask)"; then
  echo "❌ Could not derive a masking string that shares no character with the supplied credentials." >&2
  echo "   Every candidate mask character appears in one of the Grafana Cloud values." >&2
  echo "   Nothing was changed on the monitoring instance." >&2
  echo "=== Provision Monitoring_Instance: FAILED (startup) ===" >&2
  exit 1
fi

# Replace every occurrence of any secret with the mask. Every line this script
# writes to stdout or stderr goes through here.
say() {
  local line="$*"
  local secret
  for secret in "${GRAFANA_CLOUD_REMOTE_WRITE_URL:-}" "${GRAFANA_CLOUD_USERNAME:-}" "${GRAFANA_CLOUD_PASSWORD:-}"; do
    [ -n "$secret" ] || continue
    line="${line//"$secret"/$MASK}"
  done
  printf '%s\n' "$line"
}

die() { say "❌ $*" >&2; say "=== Provision Monitoring_Instance: FAILED ($CURRENT_STEP) ===" >&2; exit 1; }

CURRENT_STEP="startup"

# Temp workspace outside the repository. No rendered config and no credential
# ever lands under $REPO_ROOT.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/provision-monitoring.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# --- Input validation ---
if [ -z "$CLUSTER_NAME" ] || [ ${#CLUSTER_NAME} -gt 100 ] || ! [[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9-]+$ ]]; then
  die "Invalid cluster name '$CLUSTER_NAME'. Expected letters, digits and hyphens, max 100 characters."
fi
if [ -z "$REGION" ] || [ ${#REGION} -gt 30 ]; then
  die "Invalid region '$REGION'. Expected a non-empty value of at most 30 characters."
fi
if ! [[ "$RETENTION" =~ ^[0-9]+(ms|s|m|h|d|w|y)$ ]]; then
  die "Invalid retention '$RETENTION'. Expected a Prometheus duration such as 24h, 7d or 2w."
fi

# Requirement 2.8 is a floor, not a suggestion: a shorter local TSDB would
# discard the incident window that the local copy exists to preserve.
retention_value="${RETENTION%%[a-z]*}"
retention_unit="${RETENTION#"$retention_value"}"
case "$retention_unit" in
  ms|s|m) retention_hours=0 ;;
  h)      retention_hours="$retention_value" ;;
  d)      retention_hours=$((retention_value * 24)) ;;
  w)      retention_hours=$((retention_value * 168)) ;;
  y)      retention_hours=$((retention_value * 8760)) ;;
esac
if [ "$retention_hours" -lt 24 ]; then
  die "Retention '$RETENTION' is below the 24 hour floor (Requirement 2.8). Local storage guarantees continuity during a disaster; long term retention lives in Grafana Cloud."
fi

echo "=== Provision Monitoring_Instance: Prometheus ==="
echo "  Cluster: $CLUSTER_NAME   Region: $REGION"
echo "  Local retention: $RETENTION   Prometheus: v$PROM_VERSION"
echo ""

# ---------------------------------------------------------------------------
# [1/6] Prerequisites. Nothing on the instance is touched until all of these
# pass, so a missing credential or an unreachable host leaves the host exactly
# as it was.
# ---------------------------------------------------------------------------
CURRENT_STEP="1/6 prerequisites"
echo "[1/6] Validating prerequisites..."

# Requirement 11.3 / 11.4: report the NAMES of missing variables, never values,
# create nothing, and exit non-zero quickly.
missing=""
for var in GRAFANA_CLOUD_REMOTE_WRITE_URL GRAFANA_CLOUD_USERNAME GRAFANA_CLOUD_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    missing="$missing $var"
  fi
done
if [ -n "$missing" ]; then
  echo "❌ Missing or empty environment variable(s):$missing" >&2
  echo "   These carry the Grafana Cloud remote_write credentials and are read" >&2
  echo "   from the environment only. Export them and re-run:" >&2
  echo "     export GRAFANA_CLOUD_REMOTE_WRITE_URL='https://prometheus-prod-xx.grafana.net/api/prom/push'" >&2
  echo "     export GRAFANA_CLOUD_USERNAME='<stack user id>'" >&2
  echo "     export GRAFANA_CLOUD_PASSWORD='<stack access token>'" >&2
  echo "   Nothing was changed on the monitoring instance." >&2
  echo "=== Provision Monitoring_Instance: FAILED (1/6 prerequisites) ===" >&2
  exit 1
fi
say "  ✅ Credentials present in the environment (values masked as $MASK)"

# The URL shape is worth checking: a plain-HTTP endpoint would send the
# credentials in clear text.
case "$GRAFANA_CLOUD_REMOTE_WRITE_URL" in
  https://*) : ;;
  *) die "GRAFANA_CLOUD_REMOTE_WRITE_URL must be an https:// URL. remote_write carries basic auth credentials and must not travel over plain HTTP." ;;
esac

# The two substituted values are injected into the config with sed, so a value
# containing the delimiter or a newline would corrupt the config silently.
for var in GRAFANA_CLOUD_REMOTE_WRITE_URL GRAFANA_CLOUD_USERNAME; do
  case "${!var}" in
    *"|"*|*$'\n'*|*$'\r'*|*"&"*)
      die "$var contains a character that cannot be substituted safely (newline, '|' or '&'). Check the value copied from Grafana Cloud." ;;
  esac
done
case "$GRAFANA_CLOUD_PASSWORD" in
  *$'\n'*|*$'\r'*) die "GRAFANA_CLOUD_PASSWORD contains a newline. Prometheus reads the password file verbatim; re-copy the token without a trailing line break." ;;
esac

for tool in ssh scp sed; do
  command -v "$tool" >/dev/null 2>&1 || die "Required tool '$tool' not found on this machine. See the prerequisites table in README.md."
done
say "  ✅ ssh, scp and sed available"

[ -r "$CONFIG_TEMPLATE" ] || die "Prometheus config template not found or unreadable: $CONFIG_TEMPLATE"
grep -q '__GRAFANA_CLOUD_REMOTE_WRITE_URL__' "$CONFIG_TEMPLATE" \
  || die "Template $CONFIG_TEMPLATE no longer contains __GRAFANA_CLOUD_REMOTE_WRITE_URL__. The substitution contract changed; update this script before provisioning."
grep -q '__GRAFANA_CLOUD_USERNAME__' "$CONFIG_TEMPLATE" \
  || die "Template $CONFIG_TEMPLATE no longer contains __GRAFANA_CLOUD_USERNAME__. The substitution contract changed; update this script before provisioning."
say "  ✅ Config template found with both expected placeholders"

# Resolve the host from Terraform rather than hardcoding an address that
# changes whenever the instance is replaced.
if [ -z "$MONITORING_HOST" ]; then
  if command -v terraform >/dev/null 2>&1 && [ -d "$TERRAFORM_DIR" ]; then
    MONITORING_HOST="$(terraform -chdir="$TERRAFORM_DIR" output -raw monitoring_public_ip 2>/dev/null || true)"
  fi
fi
if [ -z "$MONITORING_HOST" ]; then
  die "Monitoring instance address unknown. Pass --host <public-ip>, set MONITORING_HOST, or run from a workspace where 'terraform -chdir=terraform output -raw monitoring_public_ip' succeeds."
fi
say "  ✅ Target host: $MONITORING_HOST"

if [ -z "$SSH_KEY" ]; then
  SSH_KEY="$HOME/.ssh/${CLUSTER_NAME}-monitoring.pem"
fi
[ -r "$SSH_KEY" ] || die "SSH private key not found or unreadable: $SSH_KEY. Pass --ssh-key <path> or set SSH_KEY."

# A world- or group-readable private key is both an OpenSSH hard error and a
# real exposure, so it fails here with the fix spelled out.
if stat -f '%OLp' "$SSH_KEY" >/dev/null 2>&1; then
  key_mode="$(stat -f '%OLp' "$SSH_KEY")"          # BSD / macOS
else
  key_mode="$(stat -c '%a' "$SSH_KEY" 2>/dev/null || echo unknown)"  # GNU / Linux
fi
if [ "$key_mode" != "600" ] && [ "$key_mode" != "400" ]; then
  die "SSH key $SSH_KEY has mode $key_mode. Expected 600. Fix with: chmod 600 '$SSH_KEY'"
fi
say "  ✅ SSH key $SSH_KEY present with mode $key_mode"

SSH_OPTS=(
  -i "$SSH_KEY"
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o BatchMode=yes
  -o LogLevel=ERROR
)
REMOTE="$SSH_USER@$MONITORING_HOST"

remote() { ssh "${SSH_OPTS[@]}" "$REMOTE" "$@"; }

if ! remote 'echo ok' >/dev/null 2>&1; then
  die "Cannot reach $REMOTE over SSH. Check that the instance is running, that your current public IP matches var.my_ip in the monitoring security group, and that $SSH_KEY is the matching key pair."
fi
say "  ✅ SSH reachable: $REMOTE"

if ! remote 'sudo -n true' >/dev/null 2>&1; then
  die "Passwordless sudo is not available for $SSH_USER on $MONITORING_HOST. Provisioning writes to /etc/prometheus and installs a systemd unit."
fi
echo "  ✅ Passwordless sudo available"
echo ""

# ---------------------------------------------------------------------------
# [2/6] Prometheus binary.
#
# user_data already attempted `dnf install prometheus2 || prometheus`. Amazon
# Linux 2023 repositories may well not carry either, so both outcomes are
# handled: an existing binary is kept, and otherwise the pinned upstream
# release tarball is downloaded and checksum-verified.
# ---------------------------------------------------------------------------
CURRENT_STEP="2/6 install Prometheus"
echo "[2/6] Installing Prometheus..."

cat >"$WORKDIR/install-prometheus.sh" <<'REMOTE_INSTALL'
#!/bin/bash
set -euo pipefail

PROM_VERSION="$1"
SHA_AMD64="$2"
SHA_ARM64="$3"

# Created by user_data, but recreated here so this script also works on a host
# where user_data did not complete.
getent group prometheus >/dev/null || groupadd --system prometheus
getent passwd prometheus >/dev/null || \
  useradd --system --no-create-home --shell /sbin/nologin -g prometheus prometheus
install -d -m 0755 -o prometheus -g prometheus /etc/prometheus
install -d -m 0750 -o prometheus -g prometheus /var/lib/prometheus

find_binary() {
  for candidate in /usr/local/bin/prometheus /usr/bin/prometheus /bin/prometheus; do
    [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

if bin="$(find_binary)"; then
  echo "PROMETHEUS_BIN=$bin"
  echo "PROMETHEUS_SOURCE=existing"
  "$bin" --version 2>&1 | head -1
  exit 0
fi

echo "No Prometheus binary present (the package install in user_data did not"
echo "provide one). Falling back to the pinned upstream release tarball."

case "$(uname -m)" in
  x86_64)  arch="amd64"; want_sha="$SHA_AMD64" ;;
  aarch64) arch="arm64"; want_sha="$SHA_ARM64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

tarball="prometheus-${PROM_VERSION}.linux-${arch}.tar.gz"
url="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${tarball}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

curl -fsSL --retry 3 --retry-delay 3 -o "$tarball" "$url"

# An unverified binary running as a service is not acceptable, so a checksum
# mismatch aborts rather than installing.
echo "${want_sha}  ${tarball}" >expected.sha256
sha256sum -c expected.sha256

tar -xzf "$tarball"
src="prometheus-${PROM_VERSION}.linux-${arch}"
install -m 0755 -o root -g root "$src/prometheus" /usr/local/bin/prometheus
install -m 0755 -o root -g root "$src/promtool"   /usr/local/bin/promtool

echo "PROMETHEUS_BIN=/usr/local/bin/prometheus"
echo "PROMETHEUS_SOURCE=upstream-tarball-v${PROM_VERSION}"
/usr/local/bin/prometheus --version 2>&1 | head -1
REMOTE_INSTALL

scp "${SSH_OPTS[@]}" -q "$WORKDIR/install-prometheus.sh" "$REMOTE:/tmp/install-prometheus.sh" \
  || die "Failed to copy the install helper to $MONITORING_HOST."

install_output="$(remote "sudo bash /tmp/install-prometheus.sh '$PROM_VERSION' '$PROM_SHA256_AMD64' '$PROM_SHA256_ARM64' 2>&1")" \
  || { say "$install_output" >&2; die "Prometheus installation failed on $MONITORING_HOST."; }
remote 'rm -f /tmp/install-prometheus.sh' >/dev/null 2>&1 || true

PROMETHEUS_BIN="$(printf '%s\n' "$install_output" | sed -n 's/^PROMETHEUS_BIN=//p' | tail -1)"
PROMETHEUS_SOURCE="$(printf '%s\n' "$install_output" | sed -n 's/^PROMETHEUS_SOURCE=//p' | tail -1)"
[ -n "$PROMETHEUS_BIN" ] || { say "$install_output" >&2; die "Could not determine the Prometheus binary path on the host."; }

printf '%s\n' "$install_output" | grep -v '^PROMETHEUS_\(BIN\|SOURCE\)=' | sed 's/^/     /' || true
echo "  ✅ Prometheus binary: $PROMETHEUS_BIN ($PROMETHEUS_SOURCE)"
echo ""

# ---------------------------------------------------------------------------
# [3/6] Configuration.
#
# Substitution contract from k8s/monitoring/prometheus.yml: placeholders are
# __UPPERCASE_TOKEN__ and are replaced with sed. Exactly two tokens exist.
# Prometheus does not expand environment variables inside its config, which is
# why this is sed and not envsubst.
# ---------------------------------------------------------------------------
CURRENT_STEP="3/6 place configuration"
echo "[3/6] Rendering and placing prometheus.yml..."

RENDERED="$WORKDIR/prometheus.yml"
# '|' as the sed delimiter because the URL contains '/'. Both values were
# checked above for '|', '&', CR and LF.
sed -e "s|__GRAFANA_CLOUD_REMOTE_WRITE_URL__|${GRAFANA_CLOUD_REMOTE_WRITE_URL}|g" \
    -e "s|__GRAFANA_CLOUD_USERNAME__|${GRAFANA_CLOUD_USERNAME}|g" \
    "$CONFIG_TEMPLATE" >"$RENDERED" \
  || die "Failed to render the Prometheus configuration."

# A surviving placeholder means Prometheus would try to remote_write to a
# literal "__GRAFANA_CLOUD_REMOTE_WRITE_URL__" and fail at runtime instead of
# here. Comment lines are excluded: the template's own header documents the
# `__UPPERCASE_TOKEN__` convention and those mentions are not placeholders.
leftover="$(grep -v '^[[:space:]]*#' "$RENDERED" | grep -o '__[A-Z_]\+__' | sort -u || true)"
if [ -n "$leftover" ]; then
  say "  ❌ Unsubstituted placeholders remain:" >&2
  printf '%s\n' "$leftover" | sed 's/^/     /' >&2
  die "Rendered configuration still contains placeholders. The substitution contract in $CONFIG_TEMPLATE has gained a token this script does not know about."
fi
echo "  ✅ Both placeholders substituted (values masked in this output)"

scp "${SSH_OPTS[@]}" -q "$RENDERED" "$REMOTE:/tmp/prometheus.yml.staged" \
  || die "Failed to copy the rendered configuration to $MONITORING_HOST."

# Validate before it becomes the live config, if promtool made it onto the host.
if remote 'command -v promtool >/dev/null 2>&1' ; then
  if ! check_output="$(remote 'promtool check config /tmp/prometheus.yml.staged 2>&1')"; then
    say "$check_output" >&2
    remote 'rm -f /tmp/prometheus.yml.staged' >/dev/null 2>&1 || true
    die "promtool rejected the rendered configuration. The live config was left untouched."
  fi
  echo "  ✅ promtool check config passed"
else
  echo "  ⚠️  promtool not present on the host, skipping config validation"
fi

remote 'sudo install -m 0644 -o prometheus -g prometheus /tmp/prometheus.yml.staged /etc/prometheus/prometheus.yml && rm -f /tmp/prometheus.yml.staged' \
  || die "Failed to install /etc/prometheus/prometheus.yml."
echo "  ✅ /etc/prometheus/prometheus.yml placed (mode 0644, owner prometheus)"
echo ""

# ---------------------------------------------------------------------------
# [4/6] remote_write password (Requirements 2.7, 11.3, 11.5).
#
# The password reaches the host on stdin. It is never an argument (visible in
# `ps` and in shell history), never in user_data (readable from instance
# metadata), and never written inside the repository. `umask 077` makes the
# staging file 0600 from creation, so there is no window in which it is
# world-readable.
# ---------------------------------------------------------------------------
CURRENT_STEP="4/6 write password file"
echo "[4/6] Writing the remote_write password file..."

# `set -e` on the remote side matters: without it the exit status would be that
# of the staging-file cleanup, so a failed `install` would look like a success.
if ! printf '%s' "$GRAFANA_CLOUD_PASSWORD" | remote 'set -eu
                   umask 077
                   staged="$HOME/.remote_write_password.staged"
                   cat > "$staged"
                   trap "{ command -v shred >/dev/null 2>&1 && shred -u \"$staged\"; } || rm -f \"$staged\"" EXIT
                   [ -s "$staged" ] || { echo "empty password received on stdin" >&2; exit 1; }
                   sudo install -m 0600 -o prometheus -g prometheus "$staged" /etc/prometheus/remote_write_password'; then
  die "Failed to write /etc/prometheus/remote_write_password."
fi

pw_mode="$(remote 'stat -c "%a %U:%G" /etc/prometheus/remote_write_password' 2>/dev/null || echo 'unknown')"
case "$pw_mode" in
  "600 prometheus:prometheus") echo "  ✅ /etc/prometheus/remote_write_password written (mode 600, owner prometheus:prometheus)" ;;
  *) die "Password file has unexpected permissions/ownership: $pw_mode. Expected '600 prometheus:prometheus'." ;;
esac

# Defence in depth: prove the secret is not in the config file that the next
# person will read over an SSH tunnel.
if remote 'sudo grep -q "password:" /etc/prometheus/prometheus.yml' 2>/dev/null; then
  die "The live prometheus.yml contains an inline 'password:' key. The password must only ever live in /etc/prometheus/remote_write_password."
fi
echo "  ✅ No inline password in prometheus.yml (password_file reference only)"
echo ""

# ---------------------------------------------------------------------------
# [5/6] systemd unit (Requirements 2.8, 2.13, 14.13).
#
# Retention and the listen address are command-line flags, not YAML keys, so
# they live here. `enable` is what makes the service survive a stop/start of
# the instance, which Requirement 14.13 asks for and which matters because the
# instance is meant to be stopped between demos to stop the hourly charge.
# ---------------------------------------------------------------------------
CURRENT_STEP="5/6 install systemd unit"
echo "[5/6] Installing and enabling the systemd unit..."

cat >"$WORKDIR/prometheus.service" <<UNIT
# Managed by scripts/provision-monitoring-instance.sh - edits are overwritten.
[Unit]
Description=Prometheus (out-of-cluster collector for ${CLUSTER_NAME})
Documentation=https://prometheus.io/docs/prometheus/latest/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=${PROMETHEUS_BIN} \\
  --config.file=/etc/prometheus/prometheus.yml \\
  --storage.tsdb.path=/var/lib/prometheus \\
  --storage.tsdb.retention.time=${RETENTION} \\
  --web.listen-address=127.0.0.1:9090
ExecReload=/bin/kill -HUP \$MAINPID

# Scraping must not stop because of a transient fault; the local TSDB is the
# copy that has to stay writable through a disaster.
Restart=always
RestartSec=5s

# Hardening. ProtectSystem=strict makes the whole filesystem read-only except
# the TSDB path, which is the only thing Prometheus needs to write.
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/prometheus
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

scp "${SSH_OPTS[@]}" -q "$WORKDIR/prometheus.service" "$REMOTE:/tmp/prometheus.service" \
  || die "Failed to copy the systemd unit to $MONITORING_HOST."

remote 'sudo install -m 0644 -o root -g root /tmp/prometheus.service /etc/systemd/system/prometheus.service \
        && rm -f /tmp/prometheus.service \
        && sudo systemctl daemon-reload \
        && sudo systemctl enable prometheus >/dev/null \
        && sudo systemctl restart prometheus' \
  || die "Failed to install, enable or start the prometheus service."

enabled_state="$(remote 'systemctl is-enabled prometheus' 2>/dev/null || echo 'unknown')"
if [ "$enabled_state" != "enabled" ]; then
  die "Service is '$enabled_state', expected 'enabled'. Prometheus would not come back after the instance is stopped and started (Requirement 14.13)."
fi
echo "  ✅ Unit installed with --storage.tsdb.retention.time=$RETENTION"
echo "  ✅ Unit installed with --web.listen-address=127.0.0.1:9090 (no inbound exposure)"
echo "  ✅ systemd unit enabled, so Prometheus restarts with the instance"
echo ""

# ---------------------------------------------------------------------------
# [6/6] Verification, from the host.
#
# curl runs over SSH on the instance, not locally: 9090 is bound to loopback
# and is deliberately unreachable from this machine, so a local curl would be
# testing the wrong thing and would fail even on a correct deployment.
# ---------------------------------------------------------------------------
CURRENT_STEP="6/6 verify"
echo "[6/6] Verifying Prometheus on the host..."

active_state="$(remote 'systemctl is-active prometheus' 2>/dev/null || echo 'inactive')"
if [ "$active_state" != "active" ]; then
  say "  ❌ Service state: $active_state" >&2
  remote 'sudo journalctl -u prometheus -n 30 --no-pager' 2>&1 | sed 's/^/     /' >&2 || true
  die "Prometheus service is not active."
fi
echo "  ✅ Service active"

elapsed=0
while :; do
  if remote 'curl -fsS --max-time 5 http://127.0.0.1:9090/-/ready >/dev/null 2>&1'; then
    break
  fi
  if [ "$elapsed" -ge "$READY_TIMEOUT" ]; then
    say "  ❌ Prometheus did not report ready on 127.0.0.1:9090 after ${READY_TIMEOUT}s" >&2
    remote 'sudo journalctl -u prometheus -n 30 --no-pager' 2>&1 | sed 's/^/     /' >&2 || true
    die "Prometheus is not answering on 127.0.0.1:9090."
  fi
  echo "  ⏳ Waiting for Prometheus to report ready (${elapsed}s/${READY_TIMEOUT}s)..."
  sleep "$READY_INTERVAL"
  elapsed=$((elapsed + READY_INTERVAL))
done
echo "  ✅ Prometheus answering on 127.0.0.1:9090 (loopback only, via SSH)"

# Confirm the loopback bind is what is actually listening, rather than trusting
# the flag we wrote.
listen_line="$(remote "ss -ltnp 2>/dev/null | grep ':9090' || true")"
if [ -n "$listen_line" ]; then
  if printf '%s' "$listen_line" | grep -q '127\.0\.0\.1:9090'; then
    echo "  ✅ Listener confirmed on 127.0.0.1:9090"
  else
    say "     $listen_line" >&2
    die "Prometheus is listening on an address other than 127.0.0.1:9090. The UI has no authentication; refusing to leave it exposed."
  fi
fi

# Target health. Expected steady state: 2 node-exporter targets and exactly 1
# kube-state-metrics target, all up=1. The KSM job keeps only the node with EC2
# tag eks:nodegroup-name=ng-istanbul-isolate; scraping the NodePort on both nodes would duplicate every KSM
# series (externalTrafficPolicy: Cluster answers on either node).
targets_json="$(remote 'curl -fsS --max-time 10 http://127.0.0.1:9090/api/v1/targets' 2>/dev/null || true)"
if [ -n "$targets_json" ]; then
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$targets_json" | python3 -c "
import sys, json
from collections import defaultdict
try:
    data = json.load(sys.stdin)
except Exception:
    print('     (could not parse the targets response)'); sys.exit()
groups = defaultdict(lambda: [0, 0, []])
for t in data.get('data', {}).get('activeTargets', []):
    job = t.get('labels', {}).get('job', '?')
    g = groups[job]
    if t.get('health') == 'up':
        g[0] += 1
    else:
        g[1] += 1
        g[2].append(t.get('labels', {}).get('instance', '?'))
if not groups:
    print('     no active targets yet; EC2 service discovery can take a scrape interval or two')
for job, (up, down, down_list) in sorted(groups.items()):
    print(f'     {job}: {up} up, {down} down' + (f'  (down: {\", \".join(down_list)})' if down_list else ''))
expected = {'node-exporter': 2, 'kube-state-metrics': 1}
total_up = sum(g[0] for g in groups.values())
total = sum(g[0] + g[1] for g in groups.values())
ok = total == 3 and total_up == 3 and all(groups[j][0] == n and groups[j][1] == 0 for j, n in expected.items())
print(f'     total: {total_up}/{total} up (expected 3/3)  ->  ' + ('OK' if ok else 'MISMATCH'))
" || echo "     (could not summarise targets)"
  else
    up_count="$(printf '%s' "$targets_json" | grep -o '"health":"up"' | wc -l | tr -d ' ')"
    down_count="$(printf '%s' "$targets_json" | grep -o '"health":"down"' | wc -l | tr -d ' ')"
    echo "     targets: $up_count up, $down_count down"
  fi
  echo "  ℹ️  Expected: exactly 3 targets, all up=1:"
  echo "     node-exporter 2 up (stress + isolate), kube-state-metrics 1 up (isolate node only)."
  echo "     Right after provisioning, discovery may need one scrape interval (30s)."
  echo "     Any target reporting down, or a KSM count other than 1, needs investigation."
else
  echo "  ⚠️  Could not read the targets API; check it through the SSH tunnel."
fi
echo ""

echo "=== Provision Monitoring_Instance: SUCCESS ==="
echo ""
echo "Prometheus UI (loopback only, reachable through an SSH tunnel):"
echo "  ssh -i $SSH_KEY -L 9090:127.0.0.1:9090 $REMOTE"
echo "  then open http://127.0.0.1:9090/targets"
echo ""
echo "Next: confirm 3 targets report up=1 (2 node-exporter + 1 kube-state-metrics),"
echo "      then check Grafana Cloud for the"
echo "first successful remote_write and an active series count below 6,000."
