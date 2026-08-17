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

# Helper to safely extract variables from .env without eval/source hazards
get_env_var() {
    local key="$1"
    local default_val="${2:-}"
    local val=""
    if [[ -f "${ENV_FILE}" ]]; then
        val=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "${ENV_FILE}" | tail -n1 | sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)
        val="${val%\"}"
        val="${val#\"}"
        val="${val%\'}"
        val="${val#\'}"
    fi
    if [[ -z "${val}" ]]; then
        printf '%s' "${default_val}"
    else
        printf '%s' "${val}"
    fi
}

NOTIFICATION_TIMEOUT_MS="${NOTIFICATION_TIMEOUT_MS:-$(get_env_var NOTIFICATION_TIMEOUT_MS "-1")}"

IS_POST_CLEANUP=false
if [[ "${1:-}" == "--post" ]]; then
    IS_POST_CLEANUP=true
fi

echo "=== [Immich Stop] Initiating container shutdown (post_cleanup=${IS_POST_CLEANUP}) ==="

cd "${BASE_DIR}"

# 1. Attempt graceful Docker Compose shutdown (or forced cleanup if in --post mode)
if [[ "${IS_POST_CLEANUP}" == false ]]; then
    if docker compose down -t 25 --remove-orphans 2>/dev/null; then
        echo "✔ Docker Compose stack stopped gracefully."
    else
        echo "[WARN] Standard docker compose down failed or timed out (possible drive disconnect)."
        echo "[INFO] Performing defensive cleanup for any lingering stack containers..."
        CONTAINERS=$(docker compose ps -aq --all 2>/dev/null || true)
        if [[ -n "${CONTAINERS}" ]]; then
            echo "[INFO] Forcing cleanup of project containers: ${CONTAINERS}"
            docker stop -t 5 ${CONTAINERS} 2>/dev/null || true
            docker rm -f ${CONTAINERS} 2>/dev/null || true
        fi
    fi
else
    # Quick sweep for any partially created or dangling containers in this compose project
    CONTAINERS=$(docker compose ps -aq --all 2>/dev/null || true)
    if [[ -n "${CONTAINERS}" ]]; then
        echo "[INFO] ExecStopPost: Cleaning up dangling project containers: ${CONTAINERS}"
        docker stop -t 3 ${CONTAINERS} 2>/dev/null || true
        docker rm -f ${CONTAINERS} 2>/dev/null || true
    fi
fi

# Helper to dispatch native desktop notifications via D-Bus (follows KDE default settings)
send_desktop_notification() {
    local title="$1"
    local message="$2"
    local icon="${3:-media-playback-stop}"
    local urgency="${4:-1}" # 1 = normal, 2 = critical
    local timeout_ms="${5:-${NOTIFICATION_TIMEOUT_MS:--1}}" # -1 = follow KDE system settings

    if [[ ! "${urgency}" =~ ^[012]$ ]]; then
        urgency=1
    fi

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
                -- "Immich" 0 "${icon}" "${title}" "${message}" [] "{\"urgency\": <byte ${urgency}>}" "${timeout_ms}" >/dev/null 2>&1 || true
        elif command -v kdialog >/dev/null 2>&1; then
            local timeout_sec=0
            if [[ "${timeout_ms}" -gt 0 ]]; then
                timeout_sec=$((timeout_ms / 1000))
            fi
            XDG_RUNTIME_DIR="/run/user/${target_uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" \
                kdialog --passivepopup "${message}" "${timeout_sec}" --title "${title}" --icon "${icon}" >/dev/null 2>&1 || true
        fi
    fi
}

# 2. Flush write buffers to disk
echo "[INFO] Flushing filesystem buffers..."
sync || true

echo "=== [Immich Stop] Shutdown completed successfully ==="
if [[ "${IS_POST_CLEANUP}" == false ]]; then
    send_desktop_notification "Immich Auto-Mount" "⏹ Immich stack stopped safely." "media-playback-stop" 1 "${NOTIFICATION_TIMEOUT_MS:--1}"
fi
exit 0
