# Rediacc Elite - Core Services

Standalone deployment system for Rediacc's core services.

> **For GitHub Action usage**, see [action/](action/)

## Services

- **nginx** - Reverse proxy (port 80/HTTP, 443/HTTPS)
- **api** - .NET Middleware API server
- **sql** - SQL Server 2022 Express database

## Quick Start

```bash
cd cloud/elite
./go up
```

On first startup, self-signed SSL certificates will be auto-generated for HTTPS.

Services will be available at:
- Web UI (HTTPS): https://localhost (recommended)
- Web UI (HTTP): http://localhost
- SQL Server: localhost:1433 (if `SQL_PORT` is uncommented in `.env`)

> **Note:** HTTPS uses self-signed certificates which will show browser security warnings. This is normal for local development. See [HTTPS Configuration](#https-configuration) below.

## HTTPS Configuration

Elite uses HTTPS by default with auto-generated self-signed certificates. This provides a secure development environment and enables modern web features that require HTTPS (like the Web Crypto API).

### Auto-Generation

Certificates are automatically generated on first `./go up` if:
- `ENABLE_HTTPS=true` in `.env` (default)
- No certificates exist in `./certs/`

The certificates include Subject Alternative Names (SANs) for:
- localhost
- 127.0.0.1
- Your `SYSTEM_DOMAIN`
- Any domains in `SSL_EXTRA_DOMAINS`
- Auto-detected host IP address

### Manual Certificate Management

```bash
./go cert         # Generate new certificates
./go cert-info    # View certificate details and expiry
```

### Browser Security Warnings

Self-signed certificates will show security warnings in browsers. To accept the certificate:

- **Chrome/Edge**: Click "Advanced" → "Proceed to localhost (unsafe)"
- **Firefox**: Click "Advanced" → "Accept the Risk and Continue"
- **Safari**: Click "Show Details" → "visit this website"

This is expected and safe for local development.

### Disabling HTTPS

To disable HTTPS (e.g., when using a reverse proxy):

```bash
# In .env file:
ENABLE_HTTPS=false
```

Then restart services:
```bash
./go down
./go up
```

### Using with Reverse Proxy

If you're running Elite behind a reverse proxy (like Nginx or Traefik) that handles SSL termination:

1. Set `ENABLE_HTTPS=false` in `.env`
2. Configure your reverse proxy to handle HTTPS
3. Proxy to Elite's HTTP port (default: 80)

## Management Commands

```bash
./go up             # Start all services
./go down           # Stop all services
./go status         # Show service status
./go health         # Check if services are healthy
./go version        # Show current version information
./go versions       # List available versions from registry
./go switch 0.2.1   # Switch to a specific version
./go logs nginx     # View logs for specific service
./go restart api    # Restart a service
./go exec api bash  # Shell into a container
./go cert           # Generate SSL/TLS certificates
./go cert-info      # Show certificate information and expiry
```

## Configuration

### Environment Variables

All configuration is optional with sensible defaults in `.env.template`:

- `DOCKER_REGISTRY` - Docker registry URL (default: ghcr.io/rediacc/elite)
- `TAG` - Image tag to use (default: 0.2.2)
- `HTTP_PORT` - Port for HTTP (default: 80)
- `HTTPS_PORT` - Port for HTTPS (default: 443)
- `ENABLE_HTTPS` - Enable HTTPS with self-signed certs (default: true)
- `SSL_EXTRA_DOMAINS` - Additional domains for certificate SANs (default: empty)
- `SQL_PORT` - Port for SQL Server (default: not exposed)
- `SYSTEM_DOMAIN` - System domain (default: rediacc.com)
- `SYSTEM_ADMIN_EMAIL` - Admin email (default: admin@rediacc.io)
- `SYSTEM_ADMIN_PASSWORD` - Admin password (default: admin)

### Configuration Files

- `.env.template` - System defaults (committed to git)
- `.env` - Local configuration (auto-created from template, gitignored)
- `.env.secret` - Auto-generated passwords (gitignored, created on first run)

## Architecture

### Deployment Modes

**Standalone Mode** (default):
- Exposes ports to host
- Single instance
- Uses both `docker-compose.yml` + `docker-compose.standalone.yml`

**Cloud Mode** (with `INSTANCE_NAME` env var):
- No port exposure
- Multiple instances can coexist
- Managed by cloud orchestration

### Networks

- `{instance}_rediacc_internet` - External network for nginx
- `{instance}_rediacc_intranet` - Internal network for API ↔ SQL

## Troubleshooting

### Services not starting

Check logs:
```bash
./go logs
```

### Health check failing

Run manual health check:
```bash
./go health
```

## Security

- `.env` and `.env.secret` are both gitignored to prevent credential leaks
- `.env.secret` is auto-generated with 128-character passwords on first run
- `.env` is auto-created from `.env.template` on first run
- SQL Server uses isolated internal network
- HTTPS enabled by default with self-signed certificates
- Self-signed certificates in `./certs/` are gitignored and auto-generated
- **Important**: Self-signed certificates are for development only, not production

## Version Management

### Checking Current Version

```bash
./go version
```

Shows the configured version (TAG in `.env`) and the actual versions running in containers.

### Listing Available Versions

```bash
./go versions
```

Lists all available versions from the registry. The current configured version is marked with `*`.

Example output:
```
REDIACC ELITE VERSIONS
======================

VERSION      STATUS
------------------------
0.2.2
0.2.1        * (current)
0.2.0
0.1.67
```

**Note:** The `latest` tag is only shown in CI mode.

### Switching Versions

```bash
./go switch 0.2.1    # Switch to specific version
./go switch 0.2.0    # Switch to another version
```

The switch command will:
1. Validate the version format
2. Verify the version exists in the registry
3. Update the TAG in `.env`
4. Pull the new images
5. Restart services with the new version (if running)

**Note:**
- Version format is `X.Y.Z` (e.g., 0.2.1, 1.0.0) without the `v` prefix
- The `latest` tag is only available in CI mode for automated testing, not for standalone or cloud deployments

## Image Management

The `./go up` command will:
1. Check if required images exist locally
2. If missing, authenticate with Docker registry
3. Pull images from registry

To pre-build images locally, see the main build system in `/go` at the repository root.
