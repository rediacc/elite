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
    > /dev/null 2>&1

echo "✅ Packages installed"

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

# Start Xfce4 session
echo "🖥️  Starting Xfce4 desktop..."
startxfce4 &
XFCE_PID=$!
sleep 3

# Verify Xfce is running
if ! kill -0 $XFCE_PID 2>/dev/null; then
    echo "⚠️  Xfce may have issues, continuing anyway..."
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
    -o /tmp/x11vnc.log \
    > /dev/null 2>&1

sleep 2

# Verify VNC is running
if ! pgrep -f "x11vnc.*${VNC_PORT}" > /dev/null; then
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
sleep 2

# Verify websockify is running
if ! kill -0 $WEBSOCKIFY_PID 2>/dev/null; then
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
