#!/bin/bash
# Docker Management Script for Elite Core Components

# Helper function to run docker compose with appropriate files
_docker_compose() {
    local cmd="docker compose"

    # Base compose file
    cmd="$cmd -f docker-compose.yml"

    # Auto-detect standalone mode (no INSTANCE_NAME = standalone)
    if [ -z "$INSTANCE_NAME" ]; then
        # Standalone mode: add override file with port exposure
        cmd="$cmd -f docker-compose.standalone.yml"
    fi

    # Add project name if instance name is set (cloud mode)
    if [ -n "$INSTANCE_NAME" ]; then
        cmd="$cmd --project-name $INSTANCE_NAME"
    fi

    # Execute with all passed arguments
    $cmd "$@"
}

# Function to generate a complex password
_generate_complex_password() {
    # Generate a secure password with guaranteed character types
    # Use openssl for reliable random generation
    local length=128
    local password=""
    
    # Define safe character sets (avoiding shell/SQL special chars)
    local chars_all="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#%^*()_+-="
    
    # Generate base password using openssl
    while [ ${#password} -lt $length ]; do
        # Generate random bytes and convert to base64, then filter for our allowed chars
        local chunk=$(openssl rand -base64 48 | tr -d '/+=' | tr -cd "${chars_all}")
        password="${password}${chunk}"
    done
    
    # Trim to exact length
    password="${password:0:$length}"
    
    # Ensure we have at least one of each required character type
    local has_upper=$(echo "$password" | grep -q '[A-Z]' && echo 1 || echo 0)
    local has_lower=$(echo "$password" | grep -q '[a-z]' && echo 1 || echo 0)
    local has_digit=$(echo "$password" | grep -q '[0-9]' && echo 1 || echo 0)
    local has_special=$(echo "$password" | grep -q '[!@#%^*()_+-=]' && echo 1 || echo 0)
    
    # If missing any required type, add them
    if [ $has_upper -eq 0 ] || [ $has_lower -eq 0 ] || [ $has_digit -eq 0 ] || [ $has_special -eq 0 ]; then
        # Add one of each missing type at random positions
        local addon=""
        [ $has_upper -eq 0 ] && addon="${addon}$(echo 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' | fold -w1 | shuf | head -1)"
        [ $has_lower -eq 0 ] && addon="${addon}$(echo 'abcdefghijklmnopqrstuvwxyz' | fold -w1 | shuf | head -1)"
        [ $has_digit -eq 0 ] && addon="${addon}$(echo '0123456789' | fold -w1 | shuf | head -1)"
        [ $has_special -eq 0 ] && addon="${addon}$(echo '!@#%^*()_+-=' | fold -w1 | shuf | head -1)"
        
        # Replace random positions with the required characters
        local addon_len=${#addon}
        password="${addon}${password:$addon_len}"
    fi
    
    # Final shuffle for good measure
    echo "$password" | fold -w1 | shuf | tr -d '\n'
}

# Function to detect if running in CI mode
_is_ci_mode() {
    # Return 0 (true) if running in CI, 1 (false) otherwise
    if [ -n "$GITHUB_ACTIONS" ] || [ -n "$CI" ]; then
        return 0
    fi
    return 1
}

# Check if .env file exists, create from template if missing
if [ ! -f ".env" ]; then
    if [ -f ".env.template" ]; then
        echo -e "\e[33m.env file not found. Creating from .env.template...\e[0m"
        cp .env.template .env
        echo -e "\e[32m.env file created. You can customize it with your settings.\e[0m"
    else
        echo -e "\e[31mError: Neither .env nor .env.template found!\e[0m"
        exit 1
    fi
fi

# Check if .env.secret file exists
if [ ! -f ".env.secret" ]; then
    echo -e "\e[33m.env.secret file not found. Creating one with random passwords...\e[0m"
    
    # Generate random passwords with complex policy
    SA_RANDOM_PASSWORD=$(_generate_complex_password)
    RA_RANDOM_PASSWORD=$(_generate_complex_password)
    
    # Use REDIACC_DATABASE_NAME if set, otherwise default to RediaccMiddleware
    DB_NAME="${REDIACC_DATABASE_NAME:-RediaccMiddleware}"
    
    # Create .env.secret file with database passwords
    cat > .env.secret << EOF
# Database configuration - KEEP THIS FILE SECRET!
MSSQL_SA_PASSWORD="${SA_RANDOM_PASSWORD}"
MSSQL_RA_PASSWORD="${RA_RANDOM_PASSWORD}"
REDIACC_DATABASE_NAME="${DB_NAME}"
REDIACC_SQL_USERNAME="rediacc"
CONNECTION_STRING="Server=sql,1433;Database=${DB_NAME};User Id=rediacc;Password=\"${RA_RANDOM_PASSWORD}\";TrustServerCertificate=True;Application Name=${DB_NAME};Max Pool Size=32;Min Pool Size=2;Connection Lifetime=120;Connection Timeout=15;Command Timeout=30;Pooling=true;MultipleActiveResultSets=false;Packet Size=32768"
EOF
    
    echo -e "\e[32m.env.secret file created with random passwords.\e[0m"
    echo -e "\e[31mIMPORTANT: Keep .env.secret secure and never commit it to git!\e[0m"
fi

# Preserve Docker registry credentials from CI environment before sourcing .env
# (ci-env.sh sets these from GITHUB_TOKEN in GitHub Actions)
CI_REGISTRY_USERNAME="${DOCKER_REGISTRY_USERNAME}"
CI_REGISTRY_PASSWORD="${DOCKER_REGISTRY_PASSWORD}"

# Source environment files and export for docker compose
set -a  # automatically export all variables

# Only source local files if not running as an instance
if [ -z "$INSTANCE_NAME" ]; then
    # Source .env to get base variables
    if [ -f ".env" ]; then
        source .env
    fi

    # Source secret file
    if [ -f ".env.secret" ]; then
        source .env.secret
    fi
fi

set +a  # stop auto-exporting

# Restore CI credentials if they were set (don't let .env override them)
if [ -n "$CI_REGISTRY_USERNAME" ]; then
    export DOCKER_REGISTRY_USERNAME="$CI_REGISTRY_USERNAME"
    export DOCKER_REGISTRY_PASSWORD="$CI_REGISTRY_PASSWORD"
fi

# Function to check and login to Docker registry if needed
_ensure_registry_login() {
    # Skip if DOCKER_REGISTRY is not set
    if [ -z "$DOCKER_REGISTRY" ]; then
        return 0
    fi

    # Extract registry host (remove namespace if present, e.g., ghcr.io/rediacc -> ghcr.io)
    local registry_host="${DOCKER_REGISTRY%%/*}"
    registry_host="${registry_host%%:*}"

    # Skip for local registries (localhost, 127.x.x.x, 192.168.x.x, 10.x.x.x, 172.16-31.x.x)
    if [[ "$registry_host" =~ ^(localhost|127\.|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.) ]]; then
        return 0
    fi

    # Check if already logged in by attempting to access the registry
    if docker login "$registry_host" --username "$DOCKER_REGISTRY_USERNAME" --password-stdin <<<'' >/dev/null 2>&1; then
        return 0
    fi

    # Attempt login with credentials from environment
    echo "Authenticating with Docker registry: $registry_host..."

    # Use credentials from environment
    local username="${DOCKER_REGISTRY_USERNAME}"
    local password="${DOCKER_REGISTRY_PASSWORD}"

    if [ -z "$username" ] || [ -z "$password" ]; then
        echo "Warning: DOCKER_REGISTRY_USERNAME or DOCKER_REGISTRY_PASSWORD is not set"
        echo "Attempting to pull images without authentication..."
        return 0
    fi

    # Attempt login (suppress all output to avoid credential leaks in CI)
    if echo "$password" | docker login "$registry_host" --username "$username" --password-stdin 2>&1 | grep -q "Login Succeeded"; then
        echo "Successfully authenticated with $registry_host"
        return 0
    else
        echo "Warning: Failed to authenticate with $registry_host"
        echo "Images may fail to pull if authentication is required"
        return 1
    fi
}

# Function to check if required images exist locally
_check_and_pull_images() {
    local images=(
        "${DOCKER_REGISTRY}/nginx:${TAG}"
        "${DOCKER_REGISTRY}/api:${TAG}"
        "${DOCKER_BRIDGE_IMAGE}"
    )

    local missing_images=()

    # Check which images are missing
    for image in "${images[@]}"; do
        if ! docker image inspect "$image" >/dev/null 2>&1; then
            missing_images+=("$image")
        fi
    done

    # If images are missing, attempt to pull them
    if [ ${#missing_images[@]} -gt 0 ]; then
        echo "Missing images detected. Attempting to pull..."

        # Ensure we're logged in to the registry
        _ensure_registry_login

        # Pull each missing image
        for image in "${missing_images[@]}"; do
            echo "Pulling $image..."
            if ! docker pull "$image"; then
                echo "Error: Failed to pull $image"
                echo "Please ensure the image exists in the registry or build it locally"
                return 1
            fi
        done
    fi

    return 0
}

# Cleanup bridge containers matching SYSTEM_COMPANY_NAME
cleanup_bridge_containers() {
    # Only proceed if SYSTEM_COMPANY_NAME is set
    if [ -z "$SYSTEM_COMPANY_NAME" ]; then
        echo "SYSTEM_COMPANY_NAME not set, skipping bridge container cleanup"
        return 0
    fi

    echo "Cleaning up bridge containers for company: $SYSTEM_COMPANY_NAME"

    # Sanitize company name same way as C# code (lowercase, replace non-alphanumeric with underscore)
    local sanitized_name=$(echo "$SYSTEM_COMPANY_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
    local container_name_pattern="bridge_${sanitized_name}"

    # Find containers by label
    local containers_by_label=$(docker ps -a --filter "label=rediacc.company=$SYSTEM_COMPANY_NAME" --format "{{.ID}}\t{{.Names}}" 2>/dev/null)

    # Find containers by name pattern
    local containers_by_name=$(docker ps -a --filter "name=${container_name_pattern}" --format "{{.ID}}\t{{.Names}}" 2>/dev/null)

    # Combine and deduplicate container IDs
    local all_containers=$(echo -e "${containers_by_label}\n${containers_by_name}" | sort -u | grep -v '^$')

    if [ -z "$all_containers" ]; then
        echo "No bridge containers found for company: $SYSTEM_COMPANY_NAME"
        return 0
    fi

    # Remove each container
    local removed_count=0
    while IFS=$'\t' read -r container_id container_name; do
        if [ -n "$container_id" ]; then
            echo "  Removing container: $container_name ($container_id)"
            docker rm -f "$container_id" >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                ((removed_count++))
            else
                echo "  Warning: Failed to remove container $container_name"
            fi
        fi
    done <<< "$all_containers"

    if [ $removed_count -gt 0 ]; then
        echo "✓ Removed $removed_count bridge container(s) for company: $SYSTEM_COMPANY_NAME"
    fi
}

# Function to start services
up() {
    echo "Starting elite core services..."

    # Cleanup bridge containers before starting services
    cleanup_bridge_containers

    # Auto-generate SSL/TLS certificates if HTTPS is enabled and certs don't exist
    # Only in standalone mode (when INSTANCE_NAME is not set)
    if [ -z "$INSTANCE_NAME" ] && [ "${ENABLE_HTTPS:-true}" = "true" ]; then
        if [ ! -f "./certs/cert.pem" ] || [ ! -f "./certs/key.pem" ]; then
            echo ""
            echo "HTTPS is enabled but certificates not found."
            echo "Auto-generating self-signed SSL/TLS certificates..."
            echo ""

            # Source environment to get SYSTEM_DOMAIN and SSL_EXTRA_DOMAINS
            set -a
            if [ -f ".env" ]; then
                source .env
            fi
            set +a

            # Export variables for cert generation
            export SYSTEM_DOMAIN="${SYSTEM_DOMAIN:-localhost}"
            export SSL_EXTRA_DOMAINS="${SSL_EXTRA_DOMAINS:-}"

            # Check if generation script exists
            if [ -f "./scripts/generate-certs.sh" ]; then
                bash ./scripts/generate-certs.sh
                if [ $? -eq 0 ]; then
                    echo ""
                    echo -e "\e[32m✓ Certificates generated successfully!\e[0m"
                    echo ""
                else
                    echo -e "\e[31mError: Certificate generation failed!\e[0m"
                    echo "Services will start in HTTP-only mode."
                    echo "To manually generate certificates, run: ./go cert"
                    echo ""
                fi
            else
                echo -e "\e[33mWarning: Certificate generation script not found!\e[0m"
                echo "Expected: ./scripts/generate-certs.sh"
                echo "Services will start in HTTP-only mode."
                echo ""
            fi
        fi
    fi

    # Ensure SQL Server data directory exists with correct permissions
    # Needed in standalone mode and CI (not cloud instances) when using dedicated SQL
    if [ -z "$INSTANCE_NAME" ] && [ "${SQL_MODE}" != "shared" ]; then
        if [ ! -d "./mssql" ]; then
            echo "Creating SQL Server data directory..."
            mkdir -p ./mssql
            # SQL Server 2022+ runs as non-root user (UID 10001)
            # Set ownership to allow SQL Server to write to the directory
            if [ -n "$GITHUB_ACTIONS" ]; then
                # In CI, running with sudo permissions
                sudo chown 10001:10001 ./mssql
            elif command -v sudo >/dev/null 2>&1; then
                # Local development with sudo available
                sudo chown 10001:10001 ./mssql
            else
                # If sudo not available (e.g., running as root), use chown directly
                chown 10001:10001 ./mssql 2>/dev/null || echo "Warning: Could not set ownership on ./mssql directory"
            fi
        fi
    fi

    # Check if images exist, pull if missing (skip SQL image check if using shared SQL)
    if [ "${SQL_MODE}" = "shared" ]; then
        echo "SQL Mode: shared (using rediacc-shared-sql)"
        # Skip SQL image check for shared mode
        local temp_images=(
            "${DOCKER_REGISTRY}/nginx:${TAG}"
            "${DOCKER_REGISTRY}/api:${TAG}"
            "${DOCKER_BRIDGE_IMAGE}"
        )
        _check_and_pull_images_custom "${temp_images[@]}" || return 1
    else
        echo "SQL Mode: dedicated (using instance-specific SQL)"
        _check_and_pull_images || return 1
    fi

    # Networks are managed differently based on mode:
    # - Standalone mode (no INSTANCE_NAME): docker-compose creates networks (external: false)
    # - Cloud mode (with INSTANCE_NAME): networks pre-created by cloud/go (external: true)

    # Start services - exclude SQL service if in shared mode
    if [ "${SQL_MODE}" = "shared" ]; then
        echo "Skipping dedicated SQL service (using shared SQL Server)"
        # Use --no-deps to prevent docker-compose from starting the sql dependency
        _docker_compose up -d --no-deps nginx api "$@"
    else
        _docker_compose up -d "$@"
    fi
}

# Helper function for custom image checking (used in shared SQL mode)
_check_and_pull_images_custom() {
    local images=("$@")
    local missing_images=()

    # Check which images are missing
    for image in "${images[@]}"; do
        if ! docker image inspect "$image" >/dev/null 2>&1; then
            missing_images+=("$image")
        fi
    done

    # If images are missing, attempt to pull them
    if [ ${#missing_images[@]} -gt 0 ]; then
        echo "Missing images detected. Attempting to pull..."

        # Ensure we're logged in to the registry
        _ensure_registry_login

        # Pull each missing image
        for image in "${missing_images[@]}"; do
            echo "Pulling $image..."
            if ! docker pull "$image"; then
                echo "Error: Failed to pull $image"
                echo "Please ensure the image exists in the registry or build it locally"
                return 1
            fi
        done
    fi

    return 0
}

# Function to stop services
down() {
    echo "Stopping elite core services..."
    # Stop services using the helper function
    _docker_compose down "$@"

    # Cleanup bridge containers after stopping services
    cleanup_bridge_containers
}

# Function to show logs
logs() {
    # Use project name from INSTANCE_NAME if set
    _docker_compose logs "$@"
}

# Function to show status
status() {
    # Use project name from INSTANCE_NAME if set
    _docker_compose ps
}

# Function to rebuild services
build() {
    echo "Building elite core services..."
    # Use project name from INSTANCE_NAME if set
    _docker_compose build "$@"
}

# Function to execute commands in containers
exec() {
    # Use project name from INSTANCE_NAME if set
    _docker_compose exec "$@"
}

# Function to restart services
restart() {
    echo "Restarting elite core services..."
    # Use project name from INSTANCE_NAME if set
    _docker_compose restart "$@"
}

# Function to check health
health() {
    # Run the healthcheck script (check action folder first, then .github for backward compatibility)
    if [ -f "action/healthcheck.sh" ]; then
        ./action/healthcheck.sh
    elif [ -f ".github/healthcheck.sh" ]; then
        ./.github/healthcheck.sh
    else
        echo "Error: healthcheck.sh not found"
        exit 1
    fi
}

# Function to show current version
version() {
    echo "Elite Core Version Information"
    echo "=============================="
    echo ""

    # Show TAG from .env
    if [ -f ".env" ]; then
        local env_tag=$(grep "^TAG=" .env | cut -d'=' -f2)
        echo "Configured version (TAG): ${env_tag:-not set}"
    else
        echo "Configured version (TAG): .env not found"
    fi

    echo ""

    # Show running container versions
    echo "Running container versions:"
    local containers_running=false

    for service in nginx api; do
        local container_name="${INSTANCE_NAME:-rediacc}-${service}"
        if docker inspect "$container_name" >/dev/null 2>&1; then
            containers_running=true
            local image=$(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null)
            local tag=$(echo "$image" | cut -d':' -f2)
            echo "  ${service}: ${tag}"
        fi
    done

    if [ "$containers_running" = false ]; then
        echo "  No containers running (use './go up' to start services)"
    fi
}

# Function to list available versions from registry
versions() {
    local limit="${1:-20}"  # Default to 20 versions

    echo "REDIACC ELITE VERSIONS"
    echo "======================"
    echo ""

    # Get current configured version
    local current_tag=""
    if [ -f ".env" ]; then
        current_tag=$(grep "^TAG=" .env | cut -d'=' -f2)
    fi

    # Check if Docker config exists
    if [ ! -f ~/.docker/config.json ]; then
        echo "Error: Docker config not found at ~/.docker/config.json"
        echo "Please authenticate: docker login ghcr.io"
        exit 1
    fi

    # Extract auth from Docker config
    local auth=$(jq -r ".auths[\"ghcr.io\"].auth" ~/.docker/config.json 2>/dev/null)
    if [ -z "$auth" ] || [ "$auth" = "null" ]; then
        echo "Error: No authentication found for ghcr.io"
        echo "Please authenticate: docker login ghcr.io"
        exit 1
    fi

    # Decode credentials
    local creds=$(echo "$auth" | base64 -d)
    local username=$(echo "$creds" | cut -d: -f1)
    local password=$(echo "$creds" | cut -d: -f2-)

    # Get bearer token
    local token=$(curl -s -u "${username}:${password}" \
        "https://ghcr.io/token?scope=repository:rediacc/elite/nginx:pull" | jq -r .token)

    if [ -z "$token" ] || [ "$token" = "null" ]; then
        echo "Error: Failed to get authentication token from registry"
        exit 1
    fi

    # Get tags list
    local tags=$(curl -s -H "Authorization: Bearer ${token}" \
        "https://ghcr.io/v2/rediacc/elite/nginx/tags/list" | jq -r '.tags[]')

    # Filter and sort versions (no v prefix, no latest)
    local versions=$(echo "$tags" | grep -v "^v" | grep -v "^latest$" | sort -V -r | head -n "$limit")

    # Display header
    printf "%-12s %s\n" "VERSION" "STATUS"
    printf "%s\n" "------------------------"

    # Display versions
    for ver in $versions; do
        # Check if this is the current version
        local status=""
        if [ "$ver" = "$current_tag" ]; then
            status="* (current)"
        fi

        printf "%-12s %s\n" "$ver" "$status"
    done

    # Show latest tag separately (only in CI mode)
    if _is_ci_mode; then
        echo ""
        local latest_status=""
        if [ "$current_tag" = "latest" ]; then
            latest_status="* (current)"
        fi
        printf "%-12s %s\n" "latest" "$latest_status"
    fi
}

# Function to switch to a different version
switch() {
    local new_version="$1"

    # Check if version parameter is provided
    if [ -z "$new_version" ]; then
        echo "Error: Version parameter required"
        echo "Usage: ./go switch <version>"
        echo "Examples:"
        echo "  ./go switch 0.2.1"
        echo "  ./go switch 0.2.0"
        exit 1
    fi

    # Reject "latest" tag unless in CI mode
    if [ "$new_version" = "latest" ] && ! _is_ci_mode; then
        echo "Error: The 'latest' tag is only available in CI mode for testing purposes"
        echo ""
        echo "For standalone and cloud deployments, please use a specific version:"
        echo "  ./go versions           # List available versions"
        echo "  ./go switch 0.2.2       # Switch to a specific version"
        exit 1
    fi

    # Validate version format (alphanumeric, dots, hyphens only - no v prefix)
    if [[ ! "$new_version" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "Error: Invalid version format: $new_version"
        echo "Version must contain only alphanumeric characters, dots, hyphens, and underscores"
        echo "Examples: 0.2.1, 1.0.0"
        exit 1
    fi

    # Verify version exists in registry for nginx image (as reference)
    echo "Verifying version ${new_version} exists in registry..."
    local test_image="${DOCKER_REGISTRY}/nginx:${new_version}"
    if ! docker manifest inspect "$test_image" >/dev/null 2>&1; then
        echo "Error: Version ${new_version} not found in registry"
        echo "Image tested: ${test_image}"
        exit 1
    fi
    echo "✓ Version ${new_version} verified in registry"

    # Update TAG in .env file
    if [ ! -f ".env" ]; then
        echo "Error: .env file not found"
        exit 1
    fi

    echo "Updating .env with new version..."
    # Use a temporary file for atomic update
    if grep -q "^TAG=" .env; then
        sed "s/^TAG=.*/TAG=${new_version}/" .env > .env.tmp && mv .env.tmp .env
    else
        echo "TAG=${new_version}" >> .env
    fi
    echo "✓ Updated TAG to ${new_version} in .env"

    # Export new TAG for this session
    export TAG="$new_version"

    # Re-source .env to recompute DOCKER_BRIDGE_IMAGE with new TAG
    set -a
    source .env
    set +a

    # Check if services are running
    if docker ps --format '{{.Names}}' | grep -q "${INSTANCE_NAME:-rediacc}-"; then
        echo ""
        echo "Pulling new images..."
        # Force pull new images
        docker pull "${DOCKER_REGISTRY}/nginx:${new_version}"
        docker pull "${DOCKER_REGISTRY}/api:${new_version}"
        docker pull "${DOCKER_REGISTRY}/bridge:${new_version}"

        echo ""
        echo "Restarting services with new version..."
        up
        echo ""
        echo "✓ Successfully switched to version ${new_version}"
    else
        echo ""
        echo "✓ Version updated to ${new_version}"
        echo "Run './go up' to start services with the new version"
    fi
}

# Function to generate SSL/TLS certificates
cert() {
    echo "Generating self-signed SSL/TLS certificates..."
    echo ""

    # Check if generation script exists
    if [ ! -f "./scripts/generate-certs.sh" ]; then
        echo -e "\e[31mError: Certificate generation script not found!\e[0m"
        echo "Expected: ./scripts/generate-certs.sh"
        exit 1
    fi

    # Source environment files to get SYSTEM_DOMAIN and SSL_EXTRA_DOMAINS
    set -a
    if [ -f ".env" ]; then
        source .env
    fi
    set +a

    # Export variables for the certificate generation script
    export SYSTEM_DOMAIN="${SYSTEM_DOMAIN:-localhost}"
    export SSL_EXTRA_DOMAINS="${SSL_EXTRA_DOMAINS:-}"

    # Run the generation script
    bash ./scripts/generate-certs.sh

    if [ $? -eq 0 ]; then
        echo ""
        echo -e "\e[32m✓ Certificates generated successfully!\e[0m"
        echo ""
        echo "To use HTTPS, ensure ENABLE_HTTPS=true in your .env file (default)"
        echo "Then restart the services:"
        echo "  ./go down"
        echo "  ./go up"
    else
        echo -e "\e[31mError: Certificate generation failed!\e[0m"
        exit 1
    fi
}

# Function to show certificate information
cert_info() {
    local CERT_FILE="./certs/cert.pem"

    if [ ! -f "$CERT_FILE" ]; then
        echo -e "\e[33mNo certificate found at $CERT_FILE\e[0m"
        echo ""
        echo "Generate certificates with: ./go cert"
        exit 1
    fi

    echo "Certificate Information"
    echo "======================"
    echo ""

    # Display certificate details
    echo "Subject:"
    openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null || echo "(Unable to read subject)"
    echo ""

    echo "Issuer:"
    openssl x509 -in "$CERT_FILE" -noout -issuer 2>/dev/null || echo "(Unable to read issuer)"
    echo ""

    echo "Validity:"
    openssl x509 -in "$CERT_FILE" -noout -dates 2>/dev/null || echo "(Unable to read dates)"
    echo ""

    echo "Subject Alternative Names:"
    openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null || echo "(No SANs found)"
    echo ""

    # Check expiration
    local expiry_date=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$expiry_date" ]; then
        local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null)
        local current_epoch=$(date +%s)
        local days_until_expiry=$(( ($expiry_epoch - $current_epoch) / 86400 ))

        if [ $days_until_expiry -lt 0 ]; then
            echo -e "\e[31m⚠ Certificate has EXPIRED!\e[0m"
            echo "Run './go cert' to generate a new certificate"
        elif [ $days_until_expiry -lt 30 ]; then
            echo -e "\e[33m⚠ Certificate expires in $days_until_expiry days\e[0m"
            echo "Consider regenerating with './go cert'"
        else
            echo -e "\e[32m✓ Certificate is valid (expires in $days_until_expiry days)\e[0m"
        fi
    fi

    echo ""
    echo "Certificate files:"
    echo "  - Certificate: ./certs/cert.pem"
    echo "  - Private Key: ./certs/key.pem"
    echo "  - CA Bundle:   ./certs/ca.pem"
}

# Function to show help
help() {
    echo "Elite Core Docker Management Script"
    echo ""
    echo "Usage: ./go [command] [options]"
    echo ""
    echo "Commands:"
    echo "  up         - Start all services"
    echo "  down       - Stop all services"
    echo "  logs       - Show service logs"
    echo "  status     - Show service status"
    echo "  health     - Check service health"
    echo "  version    - Show current version information"
    echo "  versions   - List available versions from registry"
    echo "  switch     - Switch to a different version"
    echo "  build      - Build/rebuild services"
    echo "  exec       - Execute command in a container"
    echo "  restart    - Restart services"
    echo "  cert       - Generate self-signed SSL/TLS certificates"
    echo "  cert-info  - Show certificate information"
    echo "  help       - Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./go up                  # Start all services"
    echo "  ./go down                # Stop all services"
    echo "  ./go version             # Show version information"
    echo "  ./go versions            # List available versions"
    echo "  ./go switch 0.2.1        # Switch to version 0.2.1"
    echo "  ./go logs nginx          # Show nginx logs"
    echo "  ./go health              # Check if services are healthy"
    echo "  ./go exec api bash       # Open bash in api container"
    echo "  ./go restart api         # Restart api service"
    echo "  ./go cert                # Generate SSL certificates for HTTPS"
    echo "  ./go cert-info           # View certificate details and expiry"
}

# Main script logic
case "$1" in
    up)
        shift
        up "$@"
        ;;
    down)
        shift
        down "$@"
        ;;
    logs)
        shift
        logs "$@"
        ;;
    status)
        shift
        status "$@"
        ;;
    health)
        shift
        health "$@"
        ;;
    version)
        shift
        version "$@"
        ;;
    versions)
        shift
        versions "$@"
        ;;
    switch)
        shift
        switch "$@"
        ;;
    build)
        shift
        build "$@"
        ;;
    exec)
        shift
        exec "$@"
        ;;
    restart)
        shift
        restart "$@"
        ;;
    cert)
        shift
        cert "$@"
        ;;
    cert-info)
        shift
        cert_info "$@"
        ;;
    help|--help|-h)
        help
        ;;
    *)
        if [ -z "$1" ]; then
            help
        else
            echo "Unknown command: $1"
            echo "Run './go help' for usage information"
            exit 1
        fi
        ;;
esac