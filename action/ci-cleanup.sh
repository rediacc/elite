#!/bin/bash
# CI Service Cleanup Script
# Stops and removes Elite services

set -e

echo "Cleaning up Rediacc Elite services..."

# Source CI environment configuration
source action/ci-env.sh

# Stop services
./go down
