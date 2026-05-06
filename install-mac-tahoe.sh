#!/bin/bash
# install-mac-tahoe.sh — opinionated MeshAgent install for macOS Tahoe.
#
# What this does (in plain English, in this order):
#
#   1. Sanity-check we're on macOS arm64.
#   2. Find the meshagent binary (assumes it's in the same directory as
#      this script, named meshagent_osx-arm-64).
#   3. Run `meshagent -fullinstall` to:
#       - Copy the binary to /usr/local/mesh_services/meshagent/meshagent/
#       - Write the system LaunchDaemon plist
#       - Write the user LaunchAgent plist (parameters: ['-kvmagent'],
#         sessionTypes: ['LoginWindow', 'Aqua'])
#       - Bootstrap both into launchd
#   4. Pre-flight the user about the upcoming TCC prompts ("MeshAgent will
#      now ask for Screen Recording and Accessibility — please click Allow
#      on each prompt"), then trigger the prompts by sending a screen-
#      refresh + a synthetic mouse-move through the agent's Unix socket.
#   5. Wait for the user to confirm the prompts were handled.
#   6. Verify the daemon is connected to the MeshCentral server and the
#      LaunchAgent is running in gui/<console-uid>.
#
# Usage:  sudo bash install-mac-tahoe.sh [<msh-config-path>]
#         (msh-config = the .msh file MeshCentral generates for the
#          device-group registration. If omitted and ./meshagent.msh
#          exists alongside this script, that's used.)

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]] || [[ "$(uname -m)" != "arm64" ]]; then
    echo "ERROR: install-mac-tahoe.sh requires macOS arm64. Got $(uname -s) $(uname -m)."
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: must run with sudo (the install needs to write to /Library/ and /usr/local/)."
    echo "       sudo bash $0 ${@:-}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="$SCRIPT_DIR/meshagent_osx-arm-64"
MSH="${1:-$SCRIPT_DIR/meshagent.msh}"

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: meshagent binary not found at $BINARY"
    echo "       Build it first: ./build-tahoe.sh"
    exit 1
fi

if [[ ! -f "$MSH" ]]; then
    echo "ERROR: .msh config not found at $MSH"
    echo "       Generate one from MeshCentral (Add Agent → macOS) or pass the path as the first argument."
    exit 1
fi

CONSOLE_USER="$(stat -f '%Su' /dev/console)"
CONSOLE_UID="$(id -u "$CONSOLE_USER")"

echo
echo "================================================================"
echo " MeshAgent install — macOS Tahoe"
echo "================================================================"
echo " Binary    : $BINARY"
echo " MSH config: $MSH"
echo " User      : $CONSOLE_USER (uid $CONSOLE_UID)"
echo
echo " About to:"
echo "   1. Copy the agent to /usr/local/mesh_services/meshagent/meshagent/"
echo "   2. Install + start a system LaunchDaemon (root) and a per-user"
echo "      LaunchAgent (you). Both run the same binary."
echo "   3. Trigger macOS to prompt for the permissions MeshAgent needs:"
echo "        - Screen Recording (so MeshCentral can show your screen)"
echo "        - Accessibility (so MeshCentral can move your mouse / type)"
echo "      You'll see a system dialog for each — click Allow."
echo
read -p " Continue? [Y/n] " yn
case "${yn,,}" in
    n|no) echo "Aborted."; exit 0 ;;
esac

echo
echo "[1/4] Running meshagent -fullinstall..."
cd "$SCRIPT_DIR"
cp "$MSH" "$BINARY.msh"
"$BINARY" -fullinstall
echo "      [DONE]"

# At this point the LaunchDaemon and LaunchAgent should both be loaded.
# Wait briefly for the agent to come up and start listening.
echo
echo "[2/4] Waiting for user LaunchAgent to start listening..."
SOCKET="/tmp/meshagent-kvm-${CONSOLE_UID}.sock"
for i in {1..20}; do
    if [[ -S "$SOCKET" ]]; then break; fi
    sleep 0.5
done
if [[ ! -S "$SOCKET" ]]; then
    echo "      [WARN] no socket at $SOCKET after 10s — LaunchAgent may not have loaded."
    echo "             Check 'launchctl print gui/$CONSOLE_UID/$( basename /Library/LaunchAgents/*.plist .plist)'"
else
    echo "      [OK] $SOCKET"
fi

echo
echo "[3/4] Triggering Screen Recording + Accessibility prompts..."
echo "      *** Watch your screen for Allow prompts in the next 10 seconds. ***"
sleep 2
if [[ -S "$SOCKET" ]]; then
    /usr/bin/python3 - "$SOCKET" <<'PY'
import socket, struct, sys, time
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
# MNG_KVM_REFRESH = 6, payload-less, total 4 bytes
sock.sendall(struct.pack("!HH", 6, 4))
time.sleep(2)  # let SCK initialize and prompt for Screen Recording
# MNG_KVM_MOUSE = 2, size 10: type, size, pad, button=0 (move), x, y
sock.sendall(struct.pack("!HHBBHH", 2, 10, 0, 0, 500, 500))
time.sleep(1)  # let CGEventPost prompt for Accessibility
sock.close()
PY
fi
echo
read -p "      Have you clicked Allow on both prompts? [Y/n] " allowed
echo

echo "[4/4] Verifying install..."
DAEMON_PID="$(pgrep -f 'meshagent --installedByUser' || true)"
AGENT_PID="$(pgrep -fu "$CONSOLE_UID" 'meshagent.* -kvmagent' || true)"
if [[ -n "$DAEMON_PID" ]]; then echo "      [OK] daemon running (pid $DAEMON_PID)"; else echo "      [WARN] daemon not found"; fi
if [[ -n "$AGENT_PID"  ]]; then echo "      [OK] agent running (pid $AGENT_PID)"; else echo "      [WARN] agent not found"; fi

echo
echo "Install complete. Connect to MeshCentral and try the Desktop tab."
echo "If video is wallpaper-only or input doesn't work, double-check:"
echo "  System Settings → Privacy & Security → Screen Recording / Accessibility"
echo "  → MeshAgent should be listed and toggled ON."
