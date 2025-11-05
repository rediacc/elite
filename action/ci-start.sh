#!/bin/bash
# CI Service Startup Script
# Starts Elite services and waits for health checks

set -e

echo "Starting Rediacc Elite services..."

# Source CI environment configuration
source action/ci-env.sh

# Start services
# Note: go script automatically creates mssql directory with correct permissions
# for SQL Server 2022+ which runs as non-root user (UID 10001)
./go up

# Wait for services to be healthy
echo "Waiting for services to be ready..."
timeout 120 bash -c 'until ./go health; do sleep 2; done' || {
  echo "Services failed to start within timeout"
  ./go logs
  exit 1
}

echo "Services are ready!"

# Add localhost as a machine for CI testing
echo ""
echo "Registering localhost as 'local' machine..."
action/ci-add-localhost-machine.sh || {
  echo "Warning: Could not register localhost machine. Tests requiring machine access may fail."
}

# Output service URLs for workflow use
echo "api-url=http://localhost" >> $GITHUB_OUTPUT
# Note: SQL connection string with password is available via environment variable MSSQL_SA_PASSWORD
# but we don't expose it in GITHUB_OUTPUT for security reasons
