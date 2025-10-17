# Rediacc Elite GitHub Action

Add Rediacc services (nginx, API, SQL Server) to your CI/CD workflows for integration testing.

## Quick Start

```yaml
name: Integration Tests

on: [push]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - uses: your-org/monorepo/cloud/elite/action@main
        env:
          DOCKER_REGISTRY_USERNAME: ${{ secrets.DOCKER_REGISTRY_USERNAME }}
          DOCKER_REGISTRY_PASSWORD: ${{ secrets.DOCKER_REGISTRY_PASSWORD }}

      - run: |
          curl http://localhost/api/health
          npm test
```

That's it! Services auto-start and auto-cleanup.

## What You Get

- **API**: http://localhost
- **Auto-cleanup**: Services removed when workflow ends
- **Isolation**: Each workflow run uses unique instance names
- **Health checks**: Waits until services are ready before running tests

## Environment Variables

### Required

Set these as repository secrets:

- `DOCKER_REGISTRY_USERNAME` - Your Docker registry username
- `DOCKER_REGISTRY_PASSWORD` - Your Docker registry password

### Optional

All have sensible defaults:

- `DOCKER_REGISTRY` - Registry URL (default: registry.rediacc.com)
- `TAG` - Image tag (default: latest)
- `SYSTEM_ADMIN_EMAIL` - Admin email (default: admin@rediacc.io)
- `SYSTEM_ADMIN_PASSWORD` - Admin password (default: admin)

## Using Outputs

```yaml
- name: Start Rediacc
  id: rediacc
  uses: your-org/monorepo/cloud/elite/action@main
  env:
    DOCKER_REGISTRY_USERNAME: ${{ secrets.DOCKER_REGISTRY_USERNAME }}
    DOCKER_REGISTRY_PASSWORD: ${{ secrets.DOCKER_REGISTRY_PASSWORD }}

- name: Run Tests
  run: |
    echo "API: ${{ steps.rediacc.outputs.api-url }}"
    echo "SQL: ${{ steps.rediacc.outputs.sql-connection }}"
```

**Available Outputs**:
- `api-url` - API endpoint URL
- `sql-connection` - SQL Server connection string template

## Complete Example

See [example-workflow.yml](example-workflow.yml) for a full working example.

## Troubleshooting

### Services fail to start

The action automatically shows logs if startup fails. Check the workflow output.

### Need to debug locally?

Use [act](https://github.com/nektos/act):

```bash
act -j test -s DOCKER_REGISTRY_USERNAME -s DOCKER_REGISTRY_PASSWORD
```

### Images not found

Ensure your Docker registry credentials are correct and the images exist at:
- `${DOCKER_REGISTRY}/rediacc/nginx:${TAG}`
- `${DOCKER_REGISTRY}/rediacc/api:${TAG}`

Note: SQL Server uses standard Microsoft images from mcr.microsoft.com, not the custom registry.

## How It Works

1. Creates unique instance using GitHub run ID
2. Pulls required Docker images from registry
3. Starts services via docker-compose
4. Waits for health checks to pass (timeout: 120s)
5. Exposes services on localhost
6. **Auto-cleanup**: Stops and removes everything when workflow ends (even on failure)

## Path Reference

- **Same repo**: `uses: ./cloud/elite/action`
- **Different repo**: `uses: your-org/monorepo/cloud/elite/action@main`
- **Specific version**: `uses: your-org/monorepo/cloud/elite/action@v1.0.0`
