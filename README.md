# ssl-certbot

Lightweight SSL certificate manager for small VPS. Uses **acme.sh** and
**Let's Encrypt HTTP-01** to issue trusted certificates without Docker,
Certbot, Python, or Node.js.

## Supported Systems

- Debian 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04
- Alpine Linux 3.x

## Quick Start

```bash
# Clone and install
git clone https://github.com/yourname/ssl-certbot.git
cd ssl-certbot
bash install/install.sh

# Apply a certificate
w ssl example.com

# Or use the interactive menu
w ssl
```

## Commands

| Command              | Description                       |
|----------------------|-----------------------------------|
| `w ssl`              | Interactive menu                  |
| `w ssl <domain>`     | Apply or renew certificate        |
| `w ssl list`         | List managed certificates         |
| `w ssl status`       | Show certificate status           |
| `w ssl renew`        | Manually renew all certificates   |
| `w ssl renew <domain>` | Renew a specific certificate   |
| `w ssl logs`         | View recent logs                  |
| `w ssl help`         | Show help                         |

Commands are case-insensitive: `w ssl`, `W ssl`, `w SSL`, `W SSL` all work.

## How It Works

1. Validates the domain name and checks DNS resolution
2. Detects services listening on TCP 80 and 443
3. Pauses known services (Nginx, Caddy, x-ui, 3x-ui) and Docker containers
   that are actually occupying those ports
4. Runs `acme.sh --standalone` to complete HTTP-01 validation on port 80
5. Installs the certificate to `/root/cert/<domain>/`
6. Restores all paused services to their original state
7. Configures automatic renewal via cron

### Important Notes

- **TCP 80 is required** for HTTP-01 validation. Let's Encrypt must be
  able to reach port 80 on this server from the public internet.
- **TCP 443** is included in the service pause/restore scope, but it is
  **not** required for HTTP-01 validation itself.
- Services on 80/443 will be **briefly stopped** during certificate
  issuance and renewal, then **automatically restored**.
- **Unknown processes** occupying port 80 or 443 will **not** be killed.
  The tool will report the PID and process name and ask you to handle it
  manually.

## Certificate Paths

Certificates are stored per domain:

```
/root/cert/<domain>/fullchain.pem   (644)
/root/cert/<domain>/privkey.pem     (600)
```

Example:

```
/root/cert/hk.example.com/fullchain.pem
/root/cert/hk.example.com/privkey.pem
```

Each domain has its own directory. Certificates never overwrite each other.

## Auto-Renewal

A cron job runs daily at 2:30 AM (with random delay up to 1 hour) to
check and renew certificates expiring within 30 days. The renewal process
uses the same port-pause-restore logic as the initial issuance.

## Service Detection

The tool identifies and safely pauses these services when they actually
occupy TCP 80 or 443:

| Service        | Systemd Unit     | OpenRC Service |
|----------------|------------------|----------------|
| Nginx          | nginx.service    | nginx          |
| Caddy          | caddy.service    | caddy          |
| x-ui           | x-ui.service     | x-ui           |
| 3x-ui          | 3x-ui.service    | 3x-ui          |

Docker containers with host port mappings to 80 or 443 are also detected
and paused. The Docker daemon itself is never stopped.

## Dependencies

Minimal runtime dependencies (auto-installed if missing):

- Bash
- curl
- openssl
- socat
- acme.sh (installed automatically)
- cron/crond
- ss, netstat, or lsof (at least one)
- flock (for concurrency control)

**Not required:** Docker, Certbot, Python, Node.js, Cloudflare API.

## Limitations (v1)

- HTTP-01 only (no DNS-01)
- Single domains only (no wildcards, no SAN)
- No automatic service config modification (Nginx/Caddy/x-ui/3x-ui
  configs are not touched)
- No IP address certificates
- No self-signed certificates
- Debian/Ubuntu/Alpine only

## Security

- Runs as root (required for port 80 binding and service management)
- Uses `umask 077` for all file creation
- Private keys are always `chmod 600`
- No `fuser -k`, `killall`, or `kill -9` against unknown processes
- User input is validated and never interpolated into shell commands
- Sensitive data (keys, passwords) never written to logs
- All paused services are restored on success, failure, or interruption
  (Ctrl+C, TERM, HUP)

## Uninstall

```bash
bash install/uninstall.sh
```

This removes the tool but preserves your certificates and acme.sh.

## Project Structure

```
ssl-certbot/
  src/
    common.sh          Shared constants, logging, OS detection, deps
    port_service.sh    Port detection, service identification, pause/resume
    cert.sh            Certificate issue, renew, list, status
    cron.sh            Cron management for auto-renewal
    ssl-certbot.sh     Main entry point (w ssl dispatcher)
    w-entry.sh         /usr/local/bin/w wrapper
    renew-all.sh       Cron-invoked renewal script
  install/
    install.sh         Installer
    uninstall.sh       Uninstaller
  docs/
    requirements.md    Requirements specification
  README.md            This file
```

## License

MIT
