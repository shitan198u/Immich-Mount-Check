#!/usr/bin/env bash
# ==============================================================================
# Immich Safe Eject Utility (CLI + KDE Plasma GUI)
# ==============================================================================
# Gracefully shuts down the Immich stack, flushes all write caches to disk,
# unmounts the filesystem, and notifies the user when the drive is safe to remove.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${BASE_DIR}/.env}"

# Determine UI mode (GUI or CLI)
USE_GUI=false
if [[ "${1:-}" == "--gui" ]] || [[ ! -t 0 && -n "${DISPLAY:-${WAYLAND_DISPLAY:-}}" ]]; then
    if command -v kdialog >/dev/null 2>&1; then
        USE_GUI=true
    fi
fi

# Helper functions for UI feedback
notify_info() {
    local msg="$1"
    if [[ "${USE_GUI}" == true ]]; then
        kdialog --passivepopup "${msg}" 5 --title "Immich Safe Eject" --icon media-eject
    else
        echo "[INFO] ${msg}"
    fi
}

notify_error() {
    local msg="$1"
    if [[ "${USE_GUI}" == true ]]; then
        kdialog --error "${msg}" --title "Immich Eject Error"
    else
        echo "[ERROR] ${msg}" >&2
    fi
}

notify_success() {
    local msg="$1"
    if [[ "${USE_GUI}" == true ]]; then
        kdialog --msgbox "${msg}" --title "Safe to Disconnect" --icon media-eject
    else
        echo "============================================================"
        echo "${msg}"
        echo "============================================================"
    fi
}

# 1. Load Environment Configuration
if [[ ! -f "${ENV_FILE}" ]]; then
    notify_error ".env configuration file not found at: ${ENV_FILE}"
    exit 1
fi

# Helper to safely extract variables from .env without eval/source hazards
get_env_var() {
    local key="$1"
    local default_val="${2:-}"
    local val
    val=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "${ENV_FILE}" | tail -n1 | sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)
    val="${val%\"}"
    val="${val#\"}"
    val="${val%\'}"
    val="${val#\'}"
    if [[ -z "${val}" ]]; then
        printf '%s' "${default_val}"
    else
        printf '%s' "${val}"
    fi
}

EXTERNAL_MOUNT_PARENT="$(get_env_var EXTERNAL_MOUNT_PARENT "/mnt")"
EXTERNAL_MOUNT_NAME="$(get_env_var EXTERNAL_MOUNT_NAME "my-external-drive")"
MOUNT_PATH="${EXTERNAL_MOUNT_PARENT%/}/${EXTERNAL_MOUNT_NAME#/}"

# 2. Confirmation Dialog (if in GUI mode)
if [[ "${USE_GUI}" == true ]]; then
    if ! kdialog --warningyesno "Are you sure you want to safely stop Immich and unmount the external drive at:\n\n${MOUNT_PATH}?" \
        --title "Confirm Immich Safe Eject" \
        --yes-label "Stop & Eject" \
        --no-label "Cancel" \
        --icon media-eject; then
        exit 0
    fi
fi

notify_info "Stopping Immich containers and syncing filesystem..."

# 3. Stop Systemd Service or Docker Compose Stack
if systemctl is-active --quiet immich.service 2>/dev/null; then
    echo "[INFO] Stopping immich.service via systemctl..."
    if ! systemctl stop immich.service 2>/dev/null; then
        "${SCRIPT_DIR}/immich-stop.sh"
    fi
else
    "${SCRIPT_DIR}/immich-stop.sh"
fi

# 4. Flush all dirty filesystem buffers
echo "[INFO] Syncing data buffers..."
sync

# 5. Unmount the external filesystem and lock encrypted container
LOCKED=false
POWERED_OFF=false

if mountpoint -q "${MOUNT_PATH}"; then
    echo "[INFO] Detecting device topology for ${MOUNT_PATH}..."
    DEV_SOURCE=$(findmnt -n -o SOURCE "${MOUNT_PATH}" 2>/dev/null || true)

    echo "[INFO] Unmounting ${MOUNT_PATH}..."
    UNMOUNTED=false
    if command -v udisksctl >/dev/null 2>&1 && [[ -n "${DEV_SOURCE}" ]]; then
        if udisksctl unmount -b "${DEV_SOURCE}" --no-user-interaction 2>/dev/null; then
            UNMOUNTED=true
        fi
    fi

    if [[ "${UNMOUNTED}" == false ]]; then
        MOUNT_UNIT=$(systemd-escape -p "${MOUNT_PATH}").mount
        if systemctl stop "${MOUNT_UNIT}" 2>/dev/null; then
            UNMOUNTED=true
        elif command -v pkexec >/dev/null 2>&1; then
            pkexec umount "${MOUNT_PATH}" && UNMOUNTED=true || true
        elif sudo -n true 2>/dev/null; then
            sudo umount "${MOUNT_PATH}" && UNMOUNTED=true || true
        fi
    fi

    if mountpoint -q "${MOUNT_PATH}"; then
        notify_error "Failed to unmount ${MOUNT_PATH}. The filesystem may still be in use by another application."
        exit 1
    fi

    # Lock LUKS container if encrypted mapper device
    if [[ -n "${DEV_SOURCE}" ]]; then
        if [[ "${DEV_SOURCE}" == /dev/mapper/* || "${DEV_SOURCE}" == /dev/dm-* ]]; then
            echo "[INFO] Locking encrypted device ${DEV_SOURCE}..."
            if command -v udisksctl >/dev/null 2>&1; then
                if udisksctl lock -b "${DEV_SOURCE}" --no-user-interaction 2>/dev/null; then
                    LOCKED=true
                fi
            fi
        fi

        # Find top-level physical parent disk
        TOP_NAME=$(lsblk -s -no NAME "${DEV_SOURCE}" 2>/dev/null | tail -n1 | tr -d '[:space:]|`-' || true)
        if [[ -n "${TOP_NAME}" && -b "/dev/${TOP_NAME}" ]]; then
            echo "[INFO] Powering off physical drive /dev/${TOP_NAME}..."
            if command -v udisksctl >/dev/null 2>&1; then
                if udisksctl power-off -b "/dev/${TOP_NAME}" --no-user-interaction 2>/dev/null; then
                    POWERED_OFF=true
                fi
            fi
        fi
    fi
fi

# 6. Truthful success notification
if [[ "${LOCKED}" == true && "${POWERED_OFF}" == true ]]; then
    notify_success "✔ Immich stack stopped gracefully.\n✔ Filesystem buffers flushed.\n✔ Drive unmounted, locked, and powered off.\n\nIt is now safe to disconnect the drive."
elif [[ "${LOCKED}" == true ]]; then
    notify_success "✔ Immich stack stopped gracefully.\n✔ Filesystem buffers flushed.\n✔ Drive unmounted and encrypted container locked.\n\nIt is now safe to disconnect the drive."
elif [[ "${POWERED_OFF}" == true ]]; then
    notify_success "✔ Immich stack stopped gracefully.\n✔ Filesystem buffers flushed.\n✔ Drive unmounted and powered off.\n\nIt is now safe to disconnect the drive."
else
    notify_success "✔ Immich stack stopped gracefully.\n✔ Filesystem buffers flushed.\n✔ Drive (${MOUNT_PATH}) unmounted.\n\nIt is now safe to disconnect the drive."
fi
exit 0
