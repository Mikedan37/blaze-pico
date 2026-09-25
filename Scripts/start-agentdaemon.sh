#!/bin/bash
# Start AgentDaemon cleanly

DAEMON_PATH="/Users/mdanylchuk/Developer/ProjectBlaze/AgentDaemon"
LOG_FILE="/tmp/agentdaemon.log"
SOCKET="/tmp/blaze_agent.sock"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STARTING AGENTDAEMON"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Kill any existing instances
echo "Stopping existing instances..."
killall AgentDaemon 2>/dev/null
sleep 2

# Remove lock file
rm -f /tmp/agentdaemon.lock

# Build if needed
if [ ! -f "$DAEMON_PATH/.build/debug/AgentDaemon" ]; then
    echo "Building AgentDaemon..."
    cd "$DAEMON_PATH"
    swift build -c debug
    cd -
fi

# Start daemon
echo "Starting AgentDaemon..."
cd "$DAEMON_PATH"
nohup .build/debug/AgentDaemon > "$LOG_FILE" 2>&1 &
DAEMON_PID=$!

sleep 3

# Check if it started
if ps -p $DAEMON_PID > /dev/null 2>&1; then
    echo "✅ AgentDaemon started (PID: $DAEMON_PID)"
else
    echo "❌ AgentDaemon failed to start"
    echo "Check logs: tail -f $LOG_FILE"
    exit 1
fi

# Check socket
if [ -S "$SOCKET" ]; then
    echo "✅ Socket ready: $SOCKET"
else
    echo "⚠️  Socket not found (may take a moment)"
fi

echo ""
echo "Logs: tail -f $LOG_FILE"
echo "Socket: $SOCKET"
echo ""
echo "✅ AgentDaemon is running!"
