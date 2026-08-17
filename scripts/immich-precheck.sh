#!/usr/bin/env bash
# ==============================================================================
# Immich Pre-Flight Safety & Mount Check Script
# ==============================================================================
# Verifies all mount, filesystem, permission, and container prerequisites
# before Docker Compose is allowed to start.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${BASE_DIR}/.env}"

# ------------------------------------------------------------------------------
# 1. Load Environment Configuration
# ------------------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[ERROR] .env file not found at: ${ENV_FILE}" >&2
    exit 1
fi

# Load variables from .env ignoring comments and empty lines
set -a
# shellcheck disable=SC1090
source <(grep -v '^\s*#' "${ENV_FILE}" | grep -E '^\s*[A-Za-z_][A-Za-z0-9_]*=')
set +a

# Construct Mount Point and Defaults
EXTERNAL_MOUNT_PARENT="${EXTERNAL_MOUNT_PARENT:-/mnt}"
EXTERNAL_MOUNT_NAME="${EXTERNAL_MOUNT_NAME:-my-external-drive}"
MOUNT_PATH="${EXTERNAL_MOUNT_PARENT%/}/${EXTERNAL_MOUNT_NAME#/}"

UPLOAD_LOCATION="${UPLOAD_LOCATION:-${MOUNT_PATH}/immich/uploads}"
DB_DATA_LOCATION="${DB_DATA_LOCATION:-${HOME}/immich/db}"
MARKER_FILENAME="${MARKER_FILENAME:-.mount_verified}"
MIN_FREE_MOUNT_MB="${MIN_FREE_MOUNT_MB:-1024}"   # 1 GB minimum
MIN_FREE_DB_MB="${MIN_FREE_DB_MB:-512}"          # 512 MB minimum

# Helper to dispatch native desktop notifications via D-Bus
send_desktop_notification() {
    local title="$1"
    local message="$2"
    local icon="${3:-folder-pictures}"
    local timeout_ms="${4:-5000}"

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
                kdialog --passivepopup "${message}" 5 --title "${title}" --icon "${icon}" >/dev/null 2>&1 || true
        fi
    fi
}

fail_precheck() {
    local err_msg="$1"
    echo "[ERROR] ${err_msg}" >&2
    echo "[FATAL] Aborting start to protect data and storage." >&2
    send_desktop_notification "Immich Mount Check" "❌ ${err_msg}" "dialog-error" 8000
    exit 1
}

echo "=== [Immich Pre-Check] Starting validation ==="
echo "Target Mount: ${MOUNT_PATH}"
echo "Upload Path:  ${UPLOAD_LOCATION}"
echo "DB Path:      ${DB_DATA_LOCATION}"

# ------------------------------------------------------------------------------
# 2. Verify Docker Daemon Status
# ------------------------------------------------------------------------------
if ! docker info >/dev/null 2>&1; then
    fail_precheck "Docker daemon is not accessible or not running!"
fi
echo "✔ Docker daemon is running."

# ------------------------------------------------------------------------------
# 3. Kernel Mount Table Check
# ------------------------------------------------------------------------------
if ! mountpoint -q "${MOUNT_PATH}"; then
    fail_precheck "'${MOUNT_PATH}' is NOT an active mountpoint! Drive is unplugged."
fi
echo "✔ Kernel mount verified at ${MOUNT_PATH}."

# ------------------------------------------------------------------------------
# 4. Marker File Verification
# ------------------------------------------------------------------------------
MARKER_PATH="${MOUNT_PATH}/${MARKER_FILENAME}"
if [[ ! -f "${MARKER_PATH}" ]]; then
    fail_precheck "Marker file missing (${MARKER_FILENAME}) on ${MOUNT_PATH}. Wrong drive attached."
fi
echo "✔ Identity marker file verified (${MARKER_FILENAME})."

# ------------------------------------------------------------------------------
# 5. Read-Write Capability Probe (Catches dirty/RO remounts)
# ------------------------------------------------------------------------------
PROBE_FILE="${MOUNT_PATH}/.rw_probe_$RANDOM"
if ! touch "${PROBE_FILE}" 2>/dev/null; then
    fail_precheck "Mount filesystem is READ-ONLY or corrupted! Cannot write to ${MOUNT_PATH}."
fi
rm -f "${PROBE_FILE}"
echo "✔ Read-Write capability confirmed on target mount."

# ------------------------------------------------------------------------------
# 6. Database Storage Verification
# ------------------------------------------------------------------------------
if [[ -e "${DB_DATA_LOCATION}" ]]; then
    if [[ ! -d "${DB_DATA_LOCATION}" ]]; then
        fail_precheck "DB path (${DB_DATA_LOCATION}) exists but is not a directory!"
    fi
else
    PARENT_DIR="$(dirname "${DB_DATA_LOCATION}")"
    if [[ ! -d "${PARENT_DIR}" ]] || [[ ! -w "${PARENT_DIR}" ]]; then
        fail_precheck "Cannot create DB directory (${DB_DATA_LOCATION}); parent is not writable!"
    fi
    mkdir -p "${DB_DATA_LOCATION}" 2>/dev/null || true
fi
echo "✔ Database directory verified (${DB_DATA_LOCATION})."

# ------------------------------------------------------------------------------
# 7. Upload Storage Verification
# ------------------------------------------------------------------------------
if [[ -e "${UPLOAD_LOCATION}" ]]; then
    if [[ ! -d "${UPLOAD_LOCATION}" ]]; then
        fail_precheck "Upload path (${UPLOAD_LOCATION}) exists but is not a directory!"
    fi
else
    PARENT_DIR="$(dirname "${UPLOAD_LOCATION}")"
    if [[ ! -d "${PARENT_DIR}" ]] || [[ ! -w "${PARENT_DIR}" ]]; then
        fail_precheck "Cannot create upload directory (${UPLOAD_LOCATION}); parent is not writable!"
    fi
    mkdir -p "${UPLOAD_LOCATION}" 2>/dev/null || true
fi
echo "✔ Upload directory verified (${UPLOAD_LOCATION})."

# ------------------------------------------------------------------------------
# 8. Free Disk Space Sanity Check
# ------------------------------------------------------------------------------
AVAIL_MOUNT_MB=$(df -P -B 1M "${MOUNT_PATH}" | awk 'NR==2 {print $4}')
if [[ "${AVAIL_MOUNT_MB}" -lt "${MIN_FREE_MOUNT_MB}" ]]; then
    fail_precheck "Low disk space on mount: ${AVAIL_MOUNT_MB}MB free (need ${MIN_FREE_MOUNT_MB}MB)."
fi

AVAIL_DB_MB=$(df -P -B 1M "${DB_DATA_LOCATION}" | awk 'NR==2 {print $4}')
if [[ "${AVAIL_DB_MB}" -lt "${MIN_FREE_DB_MB}" ]]; then
    fail_precheck "Low disk space on DB volume: ${AVAIL_DB_MB}MB free (need ${MIN_FREE_DB_MB}MB)."
fi
echo "✔ Disk space adequate (${AVAIL_MOUNT_MB}MB free on external drive, ${AVAIL_DB_MB}MB free on DB volume)."

echo "=== [Immich Pre-Check] All safety checks passed successfully ==="
send_desktop_notification "Immich Auto-Mount" "✔ Mount verified: All safety checks passed. Immich is starting..." "folder-pictures" 5
exit 0
