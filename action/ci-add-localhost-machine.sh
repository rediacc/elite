#!/bin/bash
# CI Script: Add localhost as a machine named 'local' for GitHub Actions
# This enables the CI environment to execute tasks on itself via SSH

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ELITE_DIR/../.." && pwd)"

echo "============================================"
echo "Setting up localhost as 'local' machine"
echo "============================================"

# Source CI environment variables
if [ -f "$SCRIPT_DIR/ci-env.sh" ]; then
    source "$SCRIPT_DIR/ci-env.sh"
else
    echo "Error: ci-env.sh not found"
    exit 1
fi

# Configuration
MACHINE_NAME="local"
MACHINE_IP="127.0.0.1"
MACHINE_USER="${USER:-runner}"
MACHINE_DATASTORE="/tmp/rediacc-datastore"
SSH_DIR="$HOME/.ssh"
SSH_KEY_FILE="$SSH_DIR/id_rsa_rediacc_local"
SSH_PUB_KEY_FILE="${SSH_KEY_FILE}.pub"

# Helper function to run CLI command
_run_cli_command() {
    (cd "$PROJECT_ROOT/cli" && PYTHONPATH="$PROJECT_ROOT/cli/src" python3 -m cli.commands.cli_main "$@")
}

echo ""
echo "Step 1: Setting up SSH for localhost connection"
echo "------------------------------------------------"

# Ensure SSH directory exists with correct permissions
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Fix home directory permissions for SSH (must not be world-writable)
chmod 755 "$HOME" || {
    echo "Warning: Could not fix home directory permissions"
}

# Generate SSH key pair for localhost access (if not exists)
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "Generating SSH key pair for localhost..."
    ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_FILE" -q -N "" -C "rediacc-ci-local"
    echo "SSH key generated: $SSH_KEY_FILE"
else
    echo "SSH key already exists: $SSH_KEY_FILE"
fi

# Add public key to authorized_keys
echo "Adding public key to authorized_keys..."
touch "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"

# Remove old entry if exists and add new one
grep -v "rediacc-ci-local" "$SSH_DIR/authorized_keys" > "$SSH_DIR/authorized_keys.tmp" || true
cat "$SSH_PUB_KEY_FILE" >> "$SSH_DIR/authorized_keys.tmp"
mv "$SSH_DIR/authorized_keys.tmp" "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"

# Test SSH connection to localhost
echo "Testing SSH connection to localhost..."
if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$MACHINE_USER@$MACHINE_IP" "echo 'SSH connection successful'" 2>&1 | grep -q "successful"; then
    echo "✓ SSH connection to localhost works"
else
    echo "✗ SSH connection test failed"
    echo "Attempting to diagnose..."

    # Try to start SSH service if not running (on self-hosted runners)
    if ! pgrep -x sshd > /dev/null; then
        echo "SSH service not running. Attempting to start..."
        sudo service ssh start || sudo systemctl start sshd || {
            echo "Could not start SSH service. It may not be installed."
            echo "GitHub-hosted runners should have SSH pre-configured."
        }
    fi

    # Retry connection
    if ! ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$MACHINE_USER@$MACHINE_IP" "echo 'SSH connection successful'" 2>&1 | grep -q "successful"; then
        echo "Error: SSH connection still failing"
        exit 1
    fi
fi

echo ""
echo "Step 2: Creating machine datastore"
echo "-----------------------------------"

# Create datastore directory
mkdir -p "$MACHINE_DATASTORE"
chmod 755 "$MACHINE_DATASTORE"
echo "✓ Created datastore at: $MACHINE_DATASTORE"

echo ""
echo "Step 3: Extracting SSH host key"
echo "--------------------------------"

# Get localhost SSH host key
HOST_KEY=$(ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null | head -1)
if [ -z "$HOST_KEY" ]; then
    # Fallback to rsa if ed25519 not available
    HOST_KEY=$(ssh-keyscan -t rsa 127.0.0.1 2>/dev/null | head -1)
fi

if [ -z "$HOST_KEY" ]; then
    echo "Error: Could not extract SSH host key"
    exit 1
fi
echo "✓ Extracted host key: ${HOST_KEY:0:50}..."

echo ""
echo "Step 4: Reading SSH keys from team vault"
echo "-----------------------------------------"

# The SDK SSH keys should already be in the team vault from _post_up.sh
# We'll use those keys for consistency, but also include the local key we generated
SSH_PRIVATE_KEY=$(cat "$SSH_KEY_FILE")
SSH_PUBLIC_KEY=$(cat "$SSH_PUB_KEY_FILE")

echo "✓ Read SSH keys"

echo ""
echo "Step 5: Registering machine with middleware"
echo "--------------------------------------------"

# Set API URL for CLI
export SYSTEM_API_URL="http://${SYSTEM_DOMAIN:-localhost}:8080/api"

# Check if required environment variables are set
if [ -z "$SYSTEM_ADMIN_EMAIL" ] || [ -z "$SYSTEM_ADMIN_PASSWORD" ]; then
    echo "Error: SYSTEM_ADMIN_EMAIL or SYSTEM_ADMIN_PASSWORD not set"
    exit 1
fi

# Login to middleware
echo "Logging in to middleware..."
if ! _run_cli_command login --email "$SYSTEM_ADMIN_EMAIL" --password "$SYSTEM_ADMIN_PASSWORD"; then
    echo "Error: Could not login to middleware"
    exit 1
fi
echo "✓ Logged in successfully"

# Wait a moment for token to be saved
sleep 0.5

# Create machine vault JSON
MACHINE_VAULT_JSON=$(jq -n \
    --arg alias "$MACHINE_NAME" \
    --arg ip "$MACHINE_IP" \
    --arg user "$MACHINE_USER" \
    --arg datastore "$MACHINE_DATASTORE" \
    --arg host_entry "$HOST_KEY" \
    '{
        alias: $alias,
        ip: $ip,
        user: $user,
        datastore: $datastore,
        host_entry: $host_entry,
        ssh_password: ""
    }')

echo "Machine vault configuration:"
echo "$MACHINE_VAULT_JSON" | jq '.'

# Register machine with middleware
echo ""
echo "Creating machine '$MACHINE_NAME'..."
if _run_cli_command CreateMachine \
    --teamName "${SYSTEM_DEFAULT_TEAM_NAME}" \
    --bridgeName "${SYSTEM_DEFAULT_BRIDGE_NAME}" \
    --machineName "$MACHINE_NAME" \
    --machineVault "$MACHINE_VAULT_JSON"; then
    echo "✓ Machine '$MACHINE_NAME' registered successfully"
else
    echo "Note: Machine may already exist or there was an error"
fi

# Logout
_run_cli_command logout || true

echo ""
echo "============================================"
echo "✓ Localhost machine setup complete"
echo "============================================"
echo ""
echo "Machine Details:"
echo "  Name: $MACHINE_NAME"
echo "  IP: $MACHINE_IP"
echo "  User: $MACHINE_USER"
echo "  Datastore: $MACHINE_DATASTORE"
echo "  SSH Key: $SSH_KEY_FILE"
echo ""
