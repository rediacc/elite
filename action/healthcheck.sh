#!/bin/bash
# Health check script for Rediacc Elite services
# Returns 0 if all services are healthy, 1 otherwise

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get container prefix (default to 'rediacc' or use INSTANCE_NAME)
CONTAINER_PREFIX="${INSTANCE_NAME:-rediacc}"

# Function to check if a container is running
check_container() {
    local service=$1
    local container="${CONTAINER_PREFIX}-${service}"

    if docker ps --filter "name=${container}" --filter "status=running" --format '{{.Names}}' | grep -q "${container}"; then
        echo -e "${GREEN}✓${NC} ${service} container is running"
        return 0
    else
        echo -e "${RED}✗${NC} ${service} container is not running"
        return 1
    fi
}

# Function to check web server
check_web() {
    # Check if web server is proxying requests (use API endpoint since root may not be configured)
    if curl -s http://localhost/api/health > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} web is responding"
        return 0
    else
        echo -e "${RED}✗${NC} web is not responding"
        return 1
    fi
}

# Function to check API
check_api() {
    # Check if API container is healthy
    local container="${CONTAINER_PREFIX}-api"

    if docker inspect "${container}" --format='{{.State.Health.Status}}' 2>/dev/null | grep -q "healthy\|none"; then
        echo -e "${GREEN}✓${NC} API is healthy"
        return 0
    else
        echo -e "${YELLOW}⊙${NC} API health check not available, checking response..."
        # Fallback: check if API responds via nginx
        if curl -s -f http://localhost/api/health > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} API is responding"
            return 0
        else
            echo -e "${RED}✗${NC} API is not responding"
            return 1
        fi
    fi
}

# Function to check SQL Server
check_sql() {
    local container="${CONTAINER_PREFIX}-sql"

    # Check if container reports healthy
    if docker inspect "${container}" --format='{{.State.Health.Status}}' 2>/dev/null | grep -q "healthy"; then
        echo -e "${GREEN}✓${NC} SQL Server is healthy"
        return 0
    else
        echo -e "${RED}✗${NC} SQL Server is not healthy"
        return 1
    fi
}

# Main health check
echo "Checking Rediacc Elite services health..."
echo "Container prefix: ${CONTAINER_PREFIX}"
echo ""

FAILED=0

# Check all services
check_container "web" || FAILED=1
check_container "api" || FAILED=1
check_container "sql" || FAILED=1

echo ""

# Check service endpoints
check_web || FAILED=1
check_api || FAILED=1
check_sql || FAILED=1

echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All services are healthy!${NC}"
    exit 0
else
    echo -e "${RED}Some services are unhealthy${NC}"
    exit 1
fi
