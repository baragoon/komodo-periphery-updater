#!/bin/bash
set -euo pipefail

##############################################################################
# Periphery Auto-Update Script (runs on Core host OS)
# Monitors moghtech/komodo releases, downloads periphery binaries to remote
# Linux hosts (amd64/arm64), restarts periphery systemd service.
##############################################################################

GITHUB_OWNER="${GITHUB_OWNER:-moghtech}"
GITHUB_REPO="${GITHUB_REPO:-komodo}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

PERIPHERY_HOSTS="${PERIPHERY_HOSTS:-}"
STATE_FILE="${STATE_FILE:-${HOME}/.local/komodo/periphery-updater.last_tag}"
PERIPHERY_BIN_PATH="${PERIPHERY_BIN_PATH:-/usr/local/bin/periphery}"
PERIPHERY_SERVICE="${PERIPHERY_SERVICE:-periphery}"
REMOTE_SUDO="${REMOTE_SUDO:-sudo}"

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

all_ok=1
updated=0

for host in $PERIPHERY_HOSTS; do
  # Parse host and optional port (format: user@host:port)
  ssh_host="$host"
  ssh_port=""
  if [[ "$host" == *:* ]]; then
    ssh_host="${host%:*}"
    ssh_port="${host##*:}"
  fi
  
  ssh_opts="-o BatchMode=yes -o ConnectTimeout=10"
  if [[ -n "$ssh_port" ]]; then
    ssh_opts="$ssh_opts -p $ssh_port"
    echo "---- Host: $ssh_host (port $ssh_port) ----"
  else
    echo "---- Host: $ssh_host ----"
  fi

  remote_arch="$(ssh $ssh_opts "$ssh_host" 'uname -m' 2>/dev/null || true)"

  if [[ -z "$remote_arch" ]]; then
    echo "Could not probe host $host"
    all_ok=0
    continue
  fi

  case "$remote_arch" in
    x86_64|amd64) asset_url="$amd64_url" ;;
    aarch64|arm64) asset_url="$arm64_url" ;;
    *)
      echo "Unsupported arch: $remote_arch"
      all_ok=0
      continue
      ;;
  esac

  echo "Arch: $remote_arch; checking version..."

  # Check current version on remote host
  remote_version="$(ssh $ssh_opts "$ssh_host" "$PERIPHERY_BIN_PATH --version 2>/dev/null || true" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?' | head -1 || echo "unknown")"
  
  # Normalize versions by removing 'v' prefix for comparison
  remote_version_normalized="${remote_version#v}"
  latest_tag_normalized="${latest_tag#v}"
  
  if [[ "$remote_version_normalized" == "$latest_tag_normalized" ]]; then
    echo "Already up-to-date ($remote_version), skipping."
    continue
  fi
  
  echo "Version mismatch: remote=$remote_version, latest=$latest_tag; updating..."

  if ssh $ssh_opts "$ssh_host" \
      URL="$asset_url" \
      BIN="$PERIPHERY_BIN_PATH" \
      SERVICE="$PERIPHERY_SERVICE" \
      SUDO_CMD="$REMOTE_SUDO" \
      'bash -s' <<'EOF'
set -euo pipefail
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fL --retry 3 --connect-timeout 15 "$URL" -o "$tmp"
chmod +x "$tmp"

if [[ -n "${SUDO_CMD:-}" ]]; then
  $SUDO_CMD install -m 0755 "$tmp" "$BIN"
  $SUDO_CMD systemctl restart "$SERVICE"
  $SUDO_CMD systemctl is-active --quiet "$SERVICE"
else
  install -m 0755 "$tmp" "$BIN"
  systemctl restart "$SERVICE"
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
