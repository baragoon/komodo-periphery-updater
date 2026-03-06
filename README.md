# Komodo Periphery Auto-Updater

Automatically checks for new Komodo releases and updates periphery binaries on remote Linux hosts.

## Features

- Monitors [moghtech/komodo](https://github.com/moghtech/komodo/tags) for new releases
- Downloads and deploys periphery binaries to remote hosts
- Supports Linux `x86_64` (amd64) and `aarch64` (arm64) architectures
- Supports Synology DSM hosts (treated like standard Linux)
- Auto-installs missing dependencies (`bash`, `curl`, `jq`, `ssh`)
- Checks current version on each host before updating
- Skips hosts already running the latest version
- Restarts periphery systemd service after update
- Tracks last deployed version to avoid redundant checks

## Usage

### Basic

```bash
export PERIPHERY_HOSTS="user@host1 user@host2"
./periphery-updater.sh
```

### With Custom SSH Ports

Specify ports using `user@host:port` format:

```bash
export PERIPHERY_HOSTS="user@host1:22 user@host2:2222"
./periphery-updater.sh
```

### With sudo Password

If remote users require sudo password (not recommended for automation):

```bash
export PERIPHERY_HOSTS="user@host1 user@host2"
export REMOTE_SUDO_PASSWORD="password_here"
./periphery-updater.sh
```

The script uses `sudo -S` to read the password from stdin for each sudo command.

### With GitHub Token (Recommended)

Avoid API rate limits:

```bash
export PERIPHERY_HOSTS="user@host1 user@host2"
export GITHUB_TOKEN="ghp_your_token_here"
./periphery-updater.sh
```

### As Komodo Post-Deploy Script

Configure in Komodo Core to run after deployments.

## Configuration

All settings can be overridden via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PERIPHERY_HOSTS` | *(required)* | Space-separated SSH targets: `"user@host1 user@host2:2222"` (ports optional) |
| `GITHUB_TOKEN` | *(optional)* | GitHub personal access token (recommended) |
| `GITHUB_OWNER` | `moghtech` | GitHub repository owner |
| `GITHUB_REPO` | `komodo` | GitHub repository name |
| `STATE_FILE` | `~/.local/komodo/periphery-updater.last_tag` | Tracks last deployed version |
| `PERIPHERY_BIN_PATH` | `/usr/local/bin/periphery` | Remote binary install path |
| `PERIPHERY_SERVICE` | `periphery` | Remote systemd service name |
| `REMOTE_SUDO` | `sudo` | Command for privilege escalation (set `""` if root) |
| `REMOTE_SUDO_PASSWORD` | *(optional)* | Password for sudo (if required; uses `sudo -S`) |

## Requirements

### On Host (where script runs)

- `bash`
- `curl`
- `jq`
- `ssh` (with key-based auth to remote hosts)

> The script auto-installs missing dependencies using `apt-get`, `yum`, or `brew`.

### On Remote Hosts

- `bash`
- `curl`
- `systemctl`
- Permissions to install binaries and restart service (via sudo or root)

## SSH Setup

Ensure passwordless SSH key authentication:

```bash
# Generate key if needed
ssh-keygen -t ed25519 -C "komodo-updater"

# Copy to remote hosts
ssh-copy-id user@host1
ssh-copy-id -p 2222 user@host2  # with custom port

# Test
ssh -o BatchMode=yes user@host1 echo ok
ssh -o BatchMode=yes -p 2222 user@host2 echo ok  # with custom port
```

## Sudo Configuration

For non-root users, you have two options:

### Option 1: Passwordless Sudo (Recommended for Automation)

Configure on remote hosts:

```bash
# Unrestricted
sudo echo "username ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/periphery-updater

# Or more restrictive (recommended)
echo "username ALL=(ALL) NOPASSWD: /usr/bin/install, /bin/systemctl" | sudo tee /etc/sudoers.d/periphery-updater
```

Then run without `REMOTE_SUDO_PASSWORD`:

```bash
export PERIPHERY_HOSTS="user@host1 user@host2"
./periphery-updater.sh
```

### Option 2: Sudo with Password

If passwordless sudo is not an option, provide the password:

```bash
export PERIPHERY_HOSTS="user@host1 user@host2"
export REMOTE_SUDO_PASSWORD="your_password"
./periphery-updater.sh
```

> Note: Passing passwords via environment variables is less secure. Prefer passwordless sudo for automation.

## Example: Automated Schedule

### Cron (every 6 hours)

```bash
crontab -e
```

Add:

```
0 */6 * * * PERIPHERY_HOSTS="user@host1 user@host2:2222" GITHUB_TOKEN="ghp_..." /path/to/periphery-updater.sh >> /var/log/periphery-updater.log 2>&1
```

### Systemd Timer

**periphery-updater.service:**

```ini
[Unit]
Description=Komodo Periphery Updater

[Service]
Type=oneshot
Environment="PERIPHERY_HOSTS=user@host1 user@host2:2222"
Environment="GITHUB_TOKEN=ghp_..."
ExecStart=/usr/local/bin/periphery-updater.sh
StandardOutput=journal
StandardError=journal
```

**periphery-updater.timer:**

```ini
[Unit]
Description=Run Komodo Periphery Updater every 6 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h

[Install]
WantedBy=timers.target
```

Enable:

```bash
sudo systemctl enable --now periphery-updater.timer
```

## Synology DSM

Synology DSM hosts are fully supported and treated like any other Linux host. The script will:

1. Detect the architecture (x86_64 or aarch64)
2. Check the current periphery version
3. Download and install the binary if needed
4. Restart the periphery systemd service

Ensure your DSM host has systemd and the periphery service configured.

## Troubleshooting

### Check last deployed version

```bash
cat ~/.local/komodo/periphery-updater.last_tag
```

### Force re-check

```bash
rm ~/.local/komodo/periphery-updater.last_tag
./periphery-updater.sh
```

### Test SSH connectivity

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 user@host1 'uname -m'

# With custom port
ssh -o BatchMode=yes -o ConnectTimeout=10 -p 2222 user@host1 'uname -m'
```

### View remote periphery version

```bash
ssh user@host1 '/usr/local/bin/periphery --version'
```

### Skip version check (force update)

The script checks `periphery --version` on each host and skips updates if already current. To force an update, manually remove the binary or modify the version output.

## License

Use freely. Based on Komodo project requirements.
