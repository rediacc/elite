#!/bin/bash
# CI Service Startup Script
# Starts Elite services and waits for health checks

set -e

echo "Starting Rediacc Elite services..."

# Source CI environment configuration
source action/ci-env.sh

# Start services
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
echo "sql-connection=Server=localhost,1433;User Id=sa;Password=${MSSQL_SA_PASSWORD};TrustServerCertificate=True" >> $GITHUB_OUTPUT
