# Rediacc Elite - Core Services

Standalone deployment system for Rediacc's core services.

> **For GitHub Action usage**, see [action/](action/)

## Services

- **nginx** - Reverse proxy (port 80)
- **api** - .NET Middleware API server
- **sql** - SQL Server 2022 Express database

## Quick Start

```bash
cd cloud/elite
./go up
```

Services will be available at:
- Web UI: http://localhost
- SQL Server: localhost:1433 (if `SQL_PORT` is uncommented in `.env`)

## Management Commands

```bash
./go up           # Start all services
./go down         # Stop all services
./go status       # Show service status
./go health       # Check if services are healthy
./go logs nginx   # View logs for specific service
./go restart api  # Restart a service
./go exec api bash  # Shell into a container
```

## Configuration

### Environment Variables

All configuration is optional with sensible defaults in `.env`:

- `DOCKER_REGISTRY` - Docker registry URL (default: registry.rediacc.com)
- `TAG` - Image tag to use (default: latest)
- `HTTP_PORT` - Port for nginx (default: 80)
- `SQL_PORT` - Port for SQL Server (default: not exposed)
- `SYSTEM_DOMAIN` - System domain (default: rediacc.com)
- `SYSTEM_ADMIN_EMAIL` - Admin email (default: admin@rediacc.io)
- `SYSTEM_ADMIN_PASSWORD` - Admin password (default: admin)

### Configuration Files

- `.env` - System defaults (committed to git)
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

- `.env.secret` is auto-generated with 128-character passwords on first run
- Never commit `.env.secret` to git
- SQL Server uses isolated internal network

## Image Management

The `./go up` command will:
1. Check if required images exist locally
2. If missing, authenticate with Docker registry
3. Pull images from registry
4. Pre-pull Microsoft SQL Server base image for bandwidth efficiency

To pre-build images locally, see the main build system in `/go` at the repository root.
