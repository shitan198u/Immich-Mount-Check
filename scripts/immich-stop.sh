#!/usr/bin/env bash
# ==============================================================================
# Immich Defensive Graceful Stop Script
# ==============================================================================
# Gracefully stops Docker Compose containers on unmount, service stop, or
# hot-unplug events. Protects against hanging I/O and dangling container states.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
OVERRIDE_FILE="${BASE_DIR}/docker-compose.override.yml"
ENV_FILE="${ENV_FILE:-${BASE_DIR}/.env}"

echo "=== [Immich Stop] Initiating graceful container shutdown ==="

cd "${BASE_DIR}"

# 1. Attempt graceful Docker Compose shutdown with 15-second timeout
if docker compose down -t 15 --remove-orphans 2>/dev/null; then
    echo "✔ Docker Compose stack stopped gracefully."
else
    echo "[WARN] Standard docker compose down failed or timed out (possible drive disconnect)."
    echo "[INFO] Performing defensive cleanup for any lingering stack containers..."

    # Check for remaining stack containers
    CONTAINERS=$(docker ps -a -q --filter "name=immich_" --filter "name=wait-for-mount" 2>/dev/null || true)
    if [[ -n "${CONTAINERS}" ]]; then
        echo "[INFO] Forcing cleanup of containers: ${CONTAINERS}"
        docker stop -t 5 ${CONTAINERS} 2>/dev/null || true
        docker rm -f ${CONTAINERS} 2>/dev/null || true
    fi
fi

# Helper to dispatch native desktop notifications via D-Bus
send_desktop_notification() {
    local title="$1"
    local message="$2"
    local icon="${3:-media-playback-stop}"
    local timeout_ms="${4:-4000}"

    local target_uid="${UID:-1000}"
    if [[ "${target_uid}" -eq 0 ]]; then
        if [[ -n "${SUDO_UID:-}" ]]; then
            target_uid="${SUDO_UID}"
        else
            target_uid=$(ls -d /run/user/[0-9]* 2>/dev/null | head -n1 | grep -o '[0-9]*' || echo 1000)
        fi
    fi

    local user_bus="/run/user/${target_uid}/bus"
    if [[ -S "${user_bus}" ]]; then
        if command -v gdbus >/dev/null 2>&1; then
            gdbus call --address "unix:path=${user_bus}" \
                --dest org.freedesktop.Notifications \
                --object-path /org/freedesktop/Notifications \
                --method org.freedesktop.Notifications.Notify \
                "Immich" 0 "${icon}" "${title}" "${message}" [] {} "${timeout_ms}" >/dev/null 2>&1 || true
        elif command -v kdialog >/dev/null 2>&1; then
            XDG_RUNTIME_DIR="/run/user/${target_uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" \
                kdialog --passivepopup "${message}" 4 --title "${title}" --icon "${icon}" >/dev/null 2>&1 || true
        fi
    fi
}

# 2. Flush write buffers to disk
echo "[INFO] Flushing filesystem buffers..."
sync || true

echo "=== [Immich Stop] Shutdown completed successfully ==="
send_desktop_notification "Immich Auto-Mount" "⏹ Immich stack stopped safely." "media-playback-stop" 4
exit 0
