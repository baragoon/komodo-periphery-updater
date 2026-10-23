#!/bin/bash
set -euo pipefail

##############################################################################
# Periphery Auto-Update Script (runs on Core host OS)
# Monitors moghtech/komodo releases, downloads periphery binaries to remote
# Linux hosts (amd64/arm64), restarts periphery systemd service.
#
# NOTE: when this script is launched by Komodo (post-deploy stage) it runs
# inside the cgroup of the periphery service on the *local* host. Restarting
# that service kills the script. To avoid this:
#   - the restart is issued through a transient systemd timer
#     (systemd-run --on-active), which lives in its own cgroup
#   - the host this script runs on (detected via boot_id) is updated LAST,
#     and its restart is delayed so the script can finish and record state
##############################################################################

GITHUB_OWNER="${GITHUB_OWNER:-moghtech}"
GITHUB_REPO="${GITHUB_REPO:-komodo}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

PERIPHERY_HOSTS="${PERIPHERY_HOSTS:-}"
STATE_FILE="${STATE_FILE:-${HOME}/.local/komodo/periphery-updater.last_tag}"
PERIPHERY_BIN_PATH="${PERIPHERY_BIN_PATH:-/usr/local/bin/periphery}"
PERIPHERY_SERVICE="${PERIPHERY_SERVICE:-periphery}"
REMOTE_SUDO="${REMOTE_SUDO:-sudo}"
# Seconds to wait before the detached service restart fires.
# The local host gets a longer delay so Komodo can receive the stage result.
RESTART_DELAY="${RESTART_DELAY:-3}"
SELF_RESTART_DELAY="${SELF_RESTART_DELAY:-8}"

##############################################################################
# Check for required commands and auto-install if missing
##############################################################################
check_requirements() {
  local missing=()
  local required=("bash" "curl" "jq" "ssh")

  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  echo "WARNING: Missing commands: ${missing[*]}"
  echo "Attempting auto-install..."

  # Detect package manager
  local pm_cmd=""
  local install_cmd=""
  local pkg_names=()

  if command -v apt-get &>/dev/null; then
    pm_cmd="apt-get"
    install_cmd="sudo apt-get update && sudo apt-get install -y"
    for cmd in "${missing[@]}"; do
      case "$cmd" in
        bash) pkg_names+=("bash") ;;
        curl) pkg_names+=("curl") ;;
        jq) pkg_names+=("jq") ;;
        ssh) pkg_names+=("openssh-client") ;;
      esac
    done
  elif command -v yum &>/dev/null; then
    pm_cmd="yum"
    install_cmd="sudo yum install -y"
    for cmd in "${missing[@]}"; do
      case "$cmd" in
        bash) pkg_names+=("bash") ;;
        curl) pkg_names+=("curl") ;;
        jq) pkg_names+=("jq") ;;
        ssh) pkg_names+=("openssh-clients") ;;
      esac
    done
  elif command -v brew &>/dev/null; then
    pm_cmd="brew"
    install_cmd="brew install"
    for cmd in "${missing[@]}"; do
      case "$cmd" in
        bash) pkg_names+=("bash") ;;
        curl) pkg_names+=("curl") ;;
        jq) pkg_names+=("jq") ;;
        ssh) pkg_names+=("openssh") ;;
      esac
    done
  else
    echo "ERROR: Unable to detect package manager (apt-get, yum, brew not found)."
    echo "Please manually install: ${missing[*]}"
    exit 1
  fi

  echo "Using $pm_cmd to install: ${pkg_names[*]}"
  if eval "$install_cmd ${pkg_names[*]}"; then
    echo "✓ Installation successful"
    # Verify again
    local still_missing=()
    for cmd in "${required[@]}"; do
      if ! command -v "$cmd" &>/dev/null; then
        still_missing+=("$cmd")
      fi
    done
    if [[ ${#still_missing[@]} -gt 0 ]]; then
      echo "ERROR: Still missing: ${still_missing[*]}"
      exit 1
    fi
  else
    echo "ERROR: Installation failed. Please manually install: ${missing[*]}"
    exit 1
  fi
}

check_requirements

if [[ -z "$PERIPHERY_HOSTS" ]]; then
  echo "PERIPHERY_HOSTS is empty; nothing to do."
  exit 0
fi

mkdir -p "$(dirname "$STATE_FILE")"

api_get() {
  local url="$1"
  if [[ -n "$GITHUB_TOKEN" ]]; then
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "$url"
  else
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      "$url"
  fi
}

echo "Checking latest Komodo tag..."
latest_tag="$(api_get "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/tags?per_page=1" | jq -r '.[0].name')"
if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
  echo "Failed to resolve latest tag."
  exit 1
fi

last_tag=""
if [[ -f "$STATE_FILE" ]]; then
  last_tag="$(cat "$STATE_FILE" || true)"
fi

echo "Latest tag: $latest_tag (previously: ${last_tag:-none})"

release_json="$(api_get "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tags/${latest_tag}")"

amd64_url="$(echo "$release_json" | jq -r '.assets[] | select(.name=="periphery-x86_64") | .browser_download_url')"
arm64_url="$(echo "$release_json" | jq -r '.assets[] | select(.name=="periphery-aarch64") | .browser_download_url')"

if [[ -z "$amd64_url" || "$amd64_url" == "null" || -z "$arm64_url" || "$arm64_url" == "null" ]]; then
  echo "Release $latest_tag missing expected assets."
  exit 1
fi

echo "Assets found:"
echo "  x86_64: $amd64_url"
echo "  aarch64: $arm64_url"

# Expected sha256 of each asset. The binary's own --version output is not
# reliable (v2.3.4 still reports 2.3.3), so compare file hashes instead.
# GitHub exposes the hash as .digest; fall back to hashing a download.
sha256_stdin() {
  if command -v sha256sum &>/dev/null; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

asset_sha() {
  local name="$1" url="$2" sha
  sha="$(echo "$release_json" | jq -r --arg n "$name" '.assets[] | select(.name==$n) | .digest // empty' | sed 's/^sha256://')"
  if [[ -z "$sha" ]]; then
    sha="$(curl -fsSL "$url" | sha256_stdin || true)"
  fi
  echo "$sha"
}

amd64_sha="$(asset_sha periphery-x86_64 "$amd64_url")"
arm64_sha="$(asset_sha periphery-aarch64 "$arm64_url")"

all_ok=1
updated=0
deferred_hosts=()
local_boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"

##############################################################################
# process_host <host-entry> <pass>
#   pass 1: normal hosts; the host we are running on is deferred
#   pass 2: deferred (local) host, detached delayed restart
# Never returns non-zero; failures set all_ok=0.
##############################################################################
process_host() {
  local host="$1"
  local pass="$2"

  # Parse host entry: user@host[:port[:password]]
  local ssh_host="$host"
  local ssh_port=""
  local ssh_password=""  # No default password
  local remainder first_part

  if [[ "$host" == *:* ]]; then
    ssh_host="${host%%:*}"
    remainder="${host#*:}"

    if [[ "$remainder" == *:* ]]; then
      # Format: user@host:port:password or user@host::password
      first_part="${remainder%%:*}"
      ssh_password="${remainder#*:}"
      if [[ "$first_part" =~ ^[0-9]+$ ]]; then
        ssh_port="$first_part"
      else
        # first_part is actually a password (no port specified)
        ssh_password="$first_part"
      fi
    else
      # Format: user@host:port or user@host:password
      if [[ "$remainder" =~ ^[0-9]+$ ]]; then
        ssh_port="$remainder"
      else
        ssh_password="$remainder"
      fi
    fi
  fi

  local ssh_opts="-o BatchMode=yes -o ConnectTimeout=10"
  if [[ -n "$ssh_port" ]]; then
    ssh_opts="$ssh_opts -p $ssh_port"
  fi

  # Detect whether this host is the machine we are running on
  local is_self=0
  local remote_boot_id
  remote_boot_id="$(ssh $ssh_opts "$ssh_host" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
  if [[ -n "$local_boot_id" && "$remote_boot_id" == "$local_boot_id" ]]; then
    is_self=1
  fi

  if [[ $is_self -eq 1 && "$pass" == "1" ]]; then
    echo "---- Host: $ssh_host is the local host; deferring to the end ----"
    deferred_hosts+=("$host")
    return 0
  fi

  local label="$ssh_host"
  [[ -n "$ssh_port" ]] && label="$label (port $ssh_port"
  if [[ -n "$ssh_password" ]]; then
    if [[ -n "$ssh_port" ]]; then label="$label, with password)"; else label="$label (with password)"; fi
  elif [[ -n "$ssh_port" ]]; then
    label="$label)"
  fi
  [[ $is_self -eq 1 ]] && label="$label [local]"
  echo "---- Host: $label ----"

  # Check if user is root or has passwordless sudo
  local remote_user_check
  remote_user_check="$(ssh $ssh_opts "$ssh_host" 'id -u' 2>/dev/null || true)"
  local is_root=0
  if [[ "$remote_user_check" == "0" ]]; then
    is_root=1
  fi

  # If not root, check if sudo works without password or if password is provided
  if [[ $is_root -eq 0 && -z "$ssh_password" ]]; then
    if ! (ssh $ssh_opts "$ssh_host" 'sudo -n true' 2>/dev/null); then
      echo "sudo requires password; provide it in PERIPHERY_HOSTS as user@host:password or user@host:port:password"
      all_ok=0
      return 0
    fi
  fi

  local remote_arch
  remote_arch="$(ssh $ssh_opts "$ssh_host" 'uname -m' 2>/dev/null || true)"

  if [[ -z "$remote_arch" ]]; then
    echo "Could not probe host $host"
    all_ok=0
    return 0
  fi

  local asset_url expected_sha
  case "$remote_arch" in
    x86_64|amd64) asset_url="$amd64_url"; expected_sha="$amd64_sha" ;;
    aarch64|arm64) asset_url="$arm64_url"; expected_sha="$arm64_sha" ;;
    *)
      echo "Unsupported arch: $remote_arch"
      all_ok=0
      return 0
      ;;
  esac

  echo "Arch: $remote_arch; checking version..."

  # Check current version on remote host
  local remote_version
  remote_version="$(ssh $ssh_opts "$ssh_host" "$PERIPHERY_BIN_PATH --version 2>/dev/null || true" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?' | head -1 || echo "unknown")"

  # Compare the installed binary's sha256 with the release asset (reliable).
  # Fall back to the --version string only if no hash is available.
  local remote_sha=""
  if [[ -n "$expected_sha" ]]; then
    remote_sha="$(ssh $ssh_opts "$ssh_host" "sha256sum '$PERIPHERY_BIN_PATH' 2>/dev/null || shasum -a 256 '$PERIPHERY_BIN_PATH' 2>/dev/null" | awk '{print $1}' || true)"
    if [[ "$remote_sha" == "$expected_sha" ]]; then
      echo "Already up-to-date (sha256 matches release $latest_tag), skipping."
      return 0
    fi
  elif [[ "${remote_version#v}" == "${latest_tag#v}" ]]; then
    echo "Already up-to-date ($remote_version), skipping."
    return 0
  fi

  echo "Binary differs from release $latest_tag (reported version: ${remote_version:-unknown}); updating..."

  local delay="$RESTART_DELAY"
  [[ $is_self -eq 1 ]] && delay="$SELF_RESTART_DELAY"

  if ssh $ssh_opts "$ssh_host" \
      URL="$(printf '%q' "$asset_url")" \
      BIN="$(printf '%q' "$PERIPHERY_BIN_PATH")" \
      SERVICE="$(printf '%q' "$PERIPHERY_SERVICE")" \
      SUDO_CMD="$(printf '%q' "$REMOTE_SUDO")" \
      SUDO_PASSWORD="$(printf '%q' "$ssh_password")" \
      IS_ROOT="$is_root" \
      IS_SELF="$is_self" \
      DELAY="$delay" \
      'bash -s' <<'EOF'
set -euo pipefail
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry 3 --connect-timeout 15 "$URL" -o "$tmp"
chmod +x "$tmp"

# Run a command with the right privileges
run() {
  if [[ "$IS_ROOT" == "1" ]]; then
    "$@"
  elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
    echo "$SUDO_PASSWORD" | $SUDO_CMD -S "$@"
  else
    $SUDO_CMD "$@"
  fi
}

run install -m 0755 "$tmp" "$BIN"

if [[ "$IS_SELF" == "1" ]]; then
  # This host runs the script inside the periphery cgroup: restart through a
  # transient systemd timer so it happens in its own cgroup and cannot kill
  # this session (or the Komodo stage). It fires after the script has exited,
  # so it can only be verified on the next run.
  run systemd-run --quiet --collect --on-active="${DELAY}s" systemctl restart "$SERVICE"
else
  # Other hosts: a plain restart is safe and needs no systemd-run.
  run systemctl restart "$SERVICE"
  sleep 2
  systemctl is-active --quiet "$SERVICE"
fi
EOF
  then
    echo "✓ Updated on $ssh_host"
    updated=$((updated + 1))
  else
    echo "✗ Update failed on $ssh_host"
    all_ok=0
  fi
  return 0
}

for host in $PERIPHERY_HOSTS; do
  process_host "$host" 1
done

for host in "${deferred_hosts[@]+"${deferred_hosts[@]}"}"; do
  # Record state before the local restart fires: it happens a few seconds
  # after this script exits, so nothing can be written afterwards.
  process_host "$host" 2
done

echo ""
echo "Summary: updated=$updated"

if [[ "$all_ok" -eq 1 ]]; then
  echo "$latest_tag" > "$STATE_FILE"
  echo "✓ Success. Recorded: $latest_tag"
  exit 0
fi

echo "✗ Failures detected; state not updated (will retry next run)"
exit 1