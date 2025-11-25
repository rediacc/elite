#!/bin/bash
# CI Desktop Environment Setup Script
# Installs and starts a lightweight desktop environment accessible via browser
#
# Architecture:
#   Runner: Xvfb + Xfce4 + x11vnc + websockify + noVNC
#   Access: http://localhost:6080/vnc.html → VNC → Xfce desktop
#
# This runs on the GitHub Actions runner (Ubuntu), not in a container.

set -e

# Cleanup function for graceful shutdown
cleanup() {
    echo "🧹 Cleaning up desktop processes..."
    if [ -f /tmp/desktop-pids.txt ]; then
        # Kill processes in reverse order of startup
        while IFS='=' read -r name pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                echo "  Stopping $name (PID: $pid)..."
                kill "$pid" 2>/dev/null || true
            fi
        done < <(tac /tmp/desktop-pids.txt)
        rm -f /tmp/desktop-pids.txt
    fi
}
trap cleanup EXIT

# Helper function to wait for a port to be ready
wait_for_port() {
    local port=$1
    local timeout=${2:-30}
    local elapsed=0

    while ! nc -z localhost "$port" 2>/dev/null; do
        if [ $elapsed -ge $timeout ]; then
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 0
}

DISPLAY_NUM="${DESKTOP_DISPLAY:-99}"
VNC_PORT="${DESKTOP_VNC_PORT:-5999}"
NOVNC_PORT="${DESKTOP_NOVNC_PORT:-6080}"
RESOLUTION="${DESKTOP_RESOLUTION:-1600x900}"
COLOR_DEPTH="${DESKTOP_COLOR_DEPTH:-24}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🖥️  Setting up Desktop Environment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Configuration:"
echo "  • Display: :${DISPLAY_NUM}"
echo "  • Resolution: ${RESOLUTION}x${COLOR_DEPTH}"
echo "  • VNC Port: ${VNC_PORT}"
echo "  • noVNC Port: ${NOVNC_PORT}"
echo ""

# Install required packages
echo "📦 Installing desktop packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    xvfb \
    xfce4 \
    xfce4-terminal \
    x11vnc \
    novnc \
    websockify \
    dbus-x11 \
    netcat-openbsd \
    gnome-keyring \
    libsecret-1-0

echo "✅ Desktop packages installed"

# Install VS Code (official Microsoft repository)
echo "📦 Installing VS Code..."
sudo apt-get install -y -qq wget gpg
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/packages.microsoft.gpg
sudo install -D -o root -g root -m 644 /tmp/packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
rm -f /tmp/packages.microsoft.gpg
sudo apt-get update -qq
sudo apt-get install -y -qq code

echo "✅ VS Code installed"

# Configure Chromium to skip first-run dialogs and disable telemetry
echo "🔧 Configuring Chromium policies..."
sudo mkdir -p /etc/chromium/policies/managed
sudo tee /etc/chromium/policies/managed/no-first-run.json > /dev/null << 'EOF'
{
    "BrowserSignin": 0,
    "SyncDisabled": true,
    "MetricsReportingEnabled": false,
    "DefaultBrowserSettingEnabled": false,
    "PromotionalTabsEnabled": false,
    "CommandLineFlagSecurityWarningsEnabled": false
}
EOF

# Also set user-level first run flag
mkdir -p ~/.config/chromium
touch ~/.config/chromium/First\ Run

echo "✅ Chromium configured"

# Create desktop shortcut for localhost
echo "🔗 Creating desktop shortcut..."
mkdir -p ~/Desktop
cat > ~/Desktop/localhost.desktop << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Rediacc (localhost)
Comment=Open Rediacc in Chromium
Exec=chromium-browser --no-sandbox http://localhost
Icon=chromium-browser
Terminal=false
Categories=Network;WebBrowser;
EOF
chmod +x ~/Desktop/localhost.desktop

# Mark desktop file as trusted (skip "untrusted" prompt in Xfce)
gio set ~/Desktop/localhost.desktop metadata::trusted true 2>/dev/null || true

echo "✅ Desktop shortcut created"

# Create directories
mkdir -p ~/.vnc
mkdir -p /tmp/.X11-unix

# Start virtual framebuffer
echo "🖼️  Starting virtual display :${DISPLAY_NUM}..."
Xvfb :${DISPLAY_NUM} -screen 0 ${RESOLUTION}x${COLOR_DEPTH} &
XVFB_PID=$!
sleep 2

# Verify Xvfb is running
if ! kill -0 $XVFB_PID 2>/dev/null; then
    echo "❌ Failed to start Xvfb"
    exit 1
fi
echo "✅ Virtual display started (PID: $XVFB_PID)"

# Set display environment
export DISPLAY=:${DISPLAY_NUM}

# Start D-Bus session (required for Xfce)
echo "🔌 Starting D-Bus session..."
eval $(dbus-launch --sh-syntax)
export DBUS_SESSION_BUS_ADDRESS

# Initialize gnome-keyring with empty password (prevents unlock prompts)
echo "🔐 Initializing keyring with empty password..."
mkdir -p ~/.local/share/keyrings
echo -n "" | gnome-keyring-daemon --unlock --components=secrets,pkcs11
eval $(echo -n "" | gnome-keyring-daemon --start --components=secrets,pkcs11)
export GNOME_KEYRING_CONTROL
export SSH_AUTH_SOCK

# Start Xfce4 session
echo "🖥️  Starting Xfce4 desktop..."
startxfce4 &
XFCE_PID=$!
sleep 3

# Verify Xfce is running
if ! kill -0 $XFCE_PID 2>/dev/null; then
    echo "❌ Failed to start Xfce desktop session."
    exit 1
fi
echo "✅ Xfce4 desktop started"

# Start x11vnc (VNC server that connects to existing X display)
echo "📡 Starting VNC server on port ${VNC_PORT}..."
x11vnc -display :${DISPLAY_NUM} \
    -rfbport ${VNC_PORT} \
    -nopw \
    -forever \
    -shared \
    -bg \
    -o /tmp/x11vnc.log

# Wait for VNC port to be ready
echo "  Waiting for VNC server to be ready..."
if ! wait_for_port ${VNC_PORT} 10; then
    echo "❌ Failed to start VNC server"
    cat /tmp/x11vnc.log 2>/dev/null || true
    exit 1
fi
echo "✅ VNC server started on port ${VNC_PORT}"

# Start noVNC (WebSocket proxy + web client)
echo "🌐 Starting noVNC on port ${NOVNC_PORT}..."

# Find noVNC web directory (varies by distro)
NOVNC_WEB="/usr/share/novnc"
if [ ! -d "$NOVNC_WEB" ]; then
    NOVNC_WEB="/usr/share/javascript/novnc"
fi

websockify --web=${NOVNC_WEB} ${NOVNC_PORT} localhost:${VNC_PORT} &
WEBSOCKIFY_PID=$!

# Wait for noVNC port to be ready
echo "  Waiting for noVNC to be ready..."
if ! wait_for_port ${NOVNC_PORT} 10; then
    echo "❌ Failed to start noVNC/websockify"
    exit 1
fi
echo "✅ noVNC started on port ${NOVNC_PORT}"

# Save PIDs for cleanup
cat > /tmp/desktop-pids.txt << EOF
XVFB_PID=$XVFB_PID
XFCE_PID=$XFCE_PID
WEBSOCKIFY_PID=$WEBSOCKIFY_PID
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Desktop environment ready!"
echo ""
echo "📍 Direct access (local): http://localhost:${NOVNC_PORT}/vnc.html"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Output for GitHub Actions
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "desktop-port=${NOVNC_PORT}" >> $GITHUB_OUTPUT
    echo "desktop-url=http://localhost:${NOVNC_PORT}/vnc.html" >> $GITHUB_OUTPUT
fi

# Clear the trap since we want processes to keep running
trap - EXIT
