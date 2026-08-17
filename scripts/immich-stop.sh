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

# Helper to dispatch native KDE desktop notifications
send_desktop_notification() {
    local title="$1"
    local message="$2"
    local icon="${3:-media-playback-stop}"
    local timeout="${4:-4}"

    local target_uid="${UID:-1000}"
    if [[ "${target_uid}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
        target_uid="${SUDO_UID}"
    fi

    local user_bus="/run/user/${target_uid}/bus"
    if [[ -S "${user_bus}" ]] && command -v kdialog >/dev/null 2>&1; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" kdialog --passivepopup "${message}" "${timeout}" --title "${title}" --icon "${icon}" 2>/dev/null || true
    fi
}

# 2. Flush write buffers to disk
echo "[INFO] Flushing filesystem buffers..."
sync || true

echo "=== [Immich Stop] Shutdown completed successfully ==="
send_desktop_notification "Immich Auto-Mount" "⏹ Immich stack stopped safely." "media-playback-stop" 4
exit 0
