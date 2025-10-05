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
CONNECTION_STRING="Server=sql,1433;Database=${DB_NAME};User Id=rediacc;Password=\"${RA_RANDOM_PASSWORD}\";TrustServerCertificate=True;Application Name=${DB_NAME};Max Pool Size=32;Min Pool Size=2;Connection Lifetime=120;Connection Timeout=15;Command Timeout=30;Pooling=true;MultipleActiveResultSets=false;Packet Size=32768"
EOF
    
    echo -e "\e[32m.env.secret file created with random passwords.\e[0m"
    echo -e "\e[31mIMPORTANT: Keep .env.secret secure and never commit it to git!\e[0m"
fi

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

# Function to check and login to Docker registry if needed
_ensure_registry_login() {
    # Skip if DOCKER_REGISTRY is not set
    if [ -z "$DOCKER_REGISTRY" ]; then
        return 0
    fi

    # Skip for local registries (localhost, 127.x.x.x, 192.168.x.x, 10.x.x.x, 172.16-31.x.x)
    if [[ "$DOCKER_REGISTRY" =~ ^(localhost|127\.|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.) ]]; then
        return 0
    fi

    # Extract registry host (remove port if present)
    local registry_host="${DOCKER_REGISTRY%%/*}"
    registry_host="${registry_host%%:*}"

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
        "${DOCKER_REGISTRY}/rediacc/nginx:${TAG}"
        "${DOCKER_REGISTRY}/rediacc/api:${TAG}"
        "${DOCKER_REGISTRY}/rediacc/sql-server:${TAG}"
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

        # Detect and pull base images for bandwidth optimization
        # This utilizes public CDNs (Docker Hub, Microsoft) for base layers
        echo "Detecting base images for optimized download..."

        if [ -f "./scripts/detect-base-image.sh" ]; then
            # Process each missing image to detect and prefetch its base image
            for image in "${missing_images[@]}"; do
                # Extract image name (nginx, api, sql-server)
                local image_name=$(echo "$image" | sed 's/.*rediacc\///' | sed 's/:.*//')

                # Build detection command with optional authentication
                local DETECT_CMD="./scripts/detect-base-image.sh --quiet"
                if [ -n "$DOCKER_REGISTRY_USERNAME" ] && [ -n "$DOCKER_REGISTRY_PASSWORD" ]; then
                    DETECT_CMD="$DETECT_CMD --username \"$DOCKER_REGISTRY_USERNAME\" --password \"$DOCKER_REGISTRY_PASSWORD\""
                fi
                DETECT_CMD="$DETECT_CMD \"$image\""

                # Try to detect base image (suppresses errors if registry unavailable)
                local BASE_IMAGE=$(eval $DETECT_CMD 2>/dev/null || true)

                # Pull base image if detected (always force fresh pull)
                if [ -n "$BASE_IMAGE" ]; then
                    echo "Pre-pulling base image for $image_name: $BASE_IMAGE"
                    # Remove local image to force fresh pull from upstream
                    docker rmi "$BASE_IMAGE" >/dev/null 2>&1 || true
                    docker pull "$BASE_IMAGE" || echo "Warning: Failed to pre-pull $BASE_IMAGE (will continue)"
                fi
            done
        fi

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

# Function to start services
up() {
    echo "Starting elite core services..."

    # Check if images exist, pull if missing
    _check_and_pull_images || return 1

    # Networks are managed differently based on mode:
    # - Standalone mode (no INSTANCE_NAME): docker-compose creates networks (external: false)
    # - Cloud mode (with INSTANCE_NAME): networks pre-created by cloud/go (external: true)

    # Start services using the helper function
    _docker_compose up -d "$@"
}

# Function to stop services
down() {
    echo "Stopping elite core services..."
    # Stop services using the helper function
    _docker_compose down "$@"
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
    echo "  build      - Build/rebuild services"
    echo "  exec       - Execute command in a container"
    echo "  restart    - Restart services"
    echo "  help       - Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./go up                  # Start all services"
    echo "  ./go down                # Stop all services"
    echo "  ./go logs nginx          # Show nginx logs"
    echo "  ./go health              # Check if services are healthy"
    echo "  ./go exec api bash       # Open bash in api container"
    echo "  ./go restart api         # Restart api service"
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