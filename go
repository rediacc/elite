#!/bin/bash
# Docker Management Script for Elite Core Components

# Function to generate a complex password
_generate_complex_password() {
    # Ensure at least one of each: uppercase, lowercase, digit, special char
    local upper=$(< /dev/urandom tr -dc 'A-Z' | head -c 32)
    local lower=$(< /dev/urandom tr -dc 'a-z' | head -c 32)
    local digits=$(< /dev/urandom tr -dc '0-9' | head -c 32)
    local special=$(< /dev/urandom tr -dc '!@#%^&*()_+' | head -c 32)
    
    # Combine and shuffle
    echo "$upper$lower$digits$special" | fold -w1 | shuf | tr -d '\n'
}

# Check if .env.secret file exists
if [ ! -f ".env.secret" ]; then
    echo -e "\e[33m.env.secret file not found. Creating one with random passwords...\e[0m"
    
    # Generate random passwords with complex policy
    SA_RANDOM_PASSWORD=$(_generate_complex_password)
    RA_RANDOM_PASSWORD=$(_generate_complex_password)
    
    # Create .env.secret file with database passwords
    cat > .env.secret << EOF
# Database configuration - KEEP THIS FILE SECRET!
MSSQL_SA_PASSWORD="${SA_RANDOM_PASSWORD}"
MSSQL_RA_PASSWORD="${RA_RANDOM_PASSWORD}"
CONNECTION_STRING="Server=rediacc-sql,1433;Database=RediaccMiddleware;User Id=rediacc;Password=${RA_RANDOM_PASSWORD};TrustServerCertificate=True;Application Name=RediaccMiddleware;Max Pool Size=32;Min Pool Size=2;Connection Lifetime=120;Connection Timeout=15;Command Timeout=30;Pooling=true;MultipleActiveResultSets=false;Packet Size=32768"
EOF
    
    echo -e "\e[32m.env.secret file created with random passwords.\e[0m"
    echo -e "\e[31mIMPORTANT: Keep .env.secret secure and never commit it to git!\e[0m"
fi

# Source environment files and export for docker compose
set -a  # automatically export all variables

# First source .env to get base variables
if [ -f ".env" ]; then
    source .env
fi

# Source secret file
if [ -f ".env.secret" ]; then
    source .env.secret
fi

set +a  # stop auto-exporting

# Function to start services
up() {
    echo "Starting elite core services..."
    docker compose up -d "$@"
}

# Function to stop services
down() {
    echo "Stopping elite core services..."
    docker compose down "$@"
}

# Function to show logs
logs() {
    docker compose logs "$@"
}

# Function to show status
status() {
    docker compose ps
}

# Function to rebuild services
build() {
    echo "Building elite core services..."
    docker compose build "$@"
}

# Function to execute commands in containers
exec() {
    docker compose exec "$@"
}

# Function to restart services
restart() {
    echo "Restarting elite core services..."
    docker compose restart "$@"
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
    echo "  build      - Build/rebuild services"
    echo "  exec       - Execute command in a container"
    echo "  restart    - Restart services"
    echo "  help       - Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./go up                  # Start all services"
    echo "  ./go down                # Stop all services"
    echo "  ./go logs nginx          # Show nginx logs"
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