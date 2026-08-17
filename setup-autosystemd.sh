#!/usr/bin/env bash
# ==============================================================================
# Immich Auto-Systemd & KDE Integration Setup Script
# ==============================================================================
# Usage:
#   ./setup-autosystemd.sh             # Install and enable systemd + KDE integration
#   ./setup-autosystemd.sh --uninstall # Remove systemd unit and KDE integrations
#   ./setup-autosystemd.sh --check     # Run pre-flight checks only
# ==============================================================================

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${BASE_DIR}/scripts"
SYSTEMD_DIR="${BASE_DIR}/systemd"
DESKTOP_DIR="${BASE_DIR}/desktop"
ENV_FILE="${BASE_DIR}/.env"

# Target paths
SYSTEMD_SERVICE_DEST="/etc/systemd/system/immich.service"
USER_HOME="${HOME}"
ACTUAL_USER="$(whoami)"
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    ACTUAL_USER="${SUDO_USER}"
    USER_HOME=$(getent passwd "${ACTUAL_USER}" | cut -d: -f6)
fi

KDE_APPS_DIR="${USER_HOME}/.local/share/applications"
KDE_KIO_DIR="${USER_HOME}/.local/share/kio/servicemenus"
KDE_SOLID_DIR="${USER_HOME}/.local/share/solid/actions"

# ------------------------------------------------------------------------------
# 1. Check Configuration
# ------------------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[ERROR] .env file not found at: ${ENV_FILE}"
    echo "Please copy .env.example to .env and configure your paths first:"
    echo "  cp .env.example .env"
    exit 1
fi

set -a
# shellcheck disable=SC1090
source <(grep -v '^\s*#' "${ENV_FILE}" | grep -E '^\s*[A-Za-z_][A-Za-z0-9_]*=')
set +a

EXTERNAL_MOUNT_PARENT="${EXTERNAL_MOUNT_PARENT:-/mnt}"
EXTERNAL_MOUNT_NAME="${EXTERNAL_MOUNT_NAME:-my-external-drive}"
MOUNT_PATH="${EXTERNAL_MOUNT_PARENT%/}/${EXTERNAL_MOUNT_NAME#/}"
MOUNT_UNIT="$(systemd-escape -p "${MOUNT_PATH}").mount"
MARKER_FILENAME="${MARKER_FILENAME:-.mount_verified}"

# ------------------------------------------------------------------------------
# Action: Check Only
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "--check" ]]; then
    "${SCRIPT_DIR}/immich-precheck.sh"
    exit $?
fi

# ------------------------------------------------------------------------------
# Action: Uninstall
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=== [Uninstalling Immich Systemd & KDE Integrations] ==="

    if systemctl is-active --quiet immich.service 2>/dev/null; then
        echo "[INFO] Stopping immich.service..."
        sudo systemctl stop immich.service || true
    fi

    if systemctl is-enabled --quiet immich.service 2>/dev/null; then
        echo "[INFO] Disabling immich.service..."
        sudo systemctl disable immich.service || true
    fi

    if [[ -f "${SYSTEMD_SERVICE_DEST}" ]]; then
        echo "[INFO] Removing ${SYSTEMD_SERVICE_DEST}..."
        sudo rm -f "${SYSTEMD_SERVICE_DEST}"
        sudo systemctl daemon-reload
    fi

    echo "[INFO] Removing KDE desktop entries..."
    rm -f "${KDE_APPS_DIR}/immich-eject.desktop"
    rm -f "${KDE_KIO_DIR}/immich-dolphin-actions.desktop"
    rm -f "${KDE_SOLID_DIR}/immich-solid-actions.desktop"

    echo "✔ Uninstallation complete."
    exit 0
fi

# ------------------------------------------------------------------------------
# Action: Install
# ------------------------------------------------------------------------------
echo "=== [Immich Auto-Systemd & KDE Integration Setup] ==="
echo "Project Directory: ${BASE_DIR}"
echo "Running User:      ${ACTUAL_USER}"
echo "Mount Path:        ${MOUNT_PATH}"
echo "Systemd MountUnit: ${MOUNT_UNIT}"
echo ""

# Ensure scripts are executable
chmod +x "${SCRIPT_DIR}"/*.sh

# Step A: Marker File on External Drive
if mountpoint -q "${MOUNT_PATH}"; then
    MARKER_PATH="${MOUNT_PATH}/${MARKER_FILENAME}"
    if [[ ! -f "${MARKER_PATH}" ]]; then
        echo "[INFO] Creating identity marker file: ${MARKER_PATH}"
        touch "${MARKER_PATH}" 2>/dev/null || sudo touch "${MARKER_PATH}"
    else
        echo "✔ Identity marker file exists at: ${MARKER_PATH}"
    fi
else
    echo "[WARN] Drive is not currently mounted at ${MOUNT_PATH}."
    echo "       Please create the marker file after mounting: touch ${MOUNT_PATH}/${MARKER_FILENAME}"
fi

# Step B: Generate Systemd Unit from Template
echo "[INFO] Generating systemd unit for ${MOUNT_UNIT}..."
TMP_SERVICE="$(mktemp)"
sed \
    -e "s|@WORKING_DIR@|${BASE_DIR}|g" \
    -e "s|@SCRIPT_DIR@|${SCRIPT_DIR}|g" \
    -e "s|@USER@|${ACTUAL_USER}|g" \
    -e "s|@MOUNT_UNIT@|${MOUNT_UNIT}|g" \
    "${SYSTEMD_DIR}/immich.service.template" > "${TMP_SERVICE}"

echo "[INFO] Installing to ${SYSTEMD_SERVICE_DEST} (requires sudo)..."
sudo cp "${TMP_SERVICE}" "${SYSTEMD_SERVICE_DEST}"
sudo chmod 644 "${SYSTEMD_SERVICE_DEST}"
rm -f "${TMP_SERVICE}"

echo "[INFO] Reloading systemd daemon..."
sudo systemctl daemon-reload
echo "[INFO] Enabling immich.service..."
sudo systemctl enable immich.service

# Step C: Install KDE Desktop, Solid Device Actions & Dolphin Context Menus
echo "[INFO] Installing KDE Desktop, Solid Device Actions & Dolphin Context Menus..."
mkdir -p "${KDE_APPS_DIR}" "${KDE_KIO_DIR}" "${KDE_SOLID_DIR}"

sed \
    -e "s|@WORKING_DIR@|${BASE_DIR}|g" \
    -e "s|@SCRIPT_DIR@|${SCRIPT_DIR}|g" \
    "${DESKTOP_DIR}/immich-eject.desktop.template" > "${KDE_APPS_DIR}/immich-eject.desktop"
chmod +x "${KDE_APPS_DIR}/immich-eject.desktop"

sed \
    -e "s|@WORKING_DIR@|${BASE_DIR}|g" \
    -e "s|@SCRIPT_DIR@|${SCRIPT_DIR}|g" \
    "${DESKTOP_DIR}/immich-dolphin-actions.desktop.template" > "${KDE_KIO_DIR}/immich-dolphin-actions.desktop"

sed \
    -e "s|@WORKING_DIR@|${BASE_DIR}|g" \
    -e "s|@SCRIPT_DIR@|${SCRIPT_DIR}|g" \
    "${DESKTOP_DIR}/immich-solid-actions.desktop.template" > "${KDE_SOLID_DIR}/immich-solid-actions.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${KDE_APPS_DIR}" 2>/dev/null || true
fi

echo ""
echo "=== [Setup Completed Successfully] ==="
echo "1. Systemd Service : ${SYSTEMD_SERVICE_DEST}"
echo "   - Bound to      : ${MOUNT_UNIT}"
echo "   - Auto-starts on: Mount activation"
echo "   - Auto-stops on : Unmount or hot-unplug"
echo "2. KDE Integration :"
echo "   - Launcher App  : 'Safely Eject Immich Drive' in KRunner / App Menu"
echo "   - Dolphin Menu  : Right-click any directory/drive in Dolphin -> 'Immich Drive Actions'"
echo "3. CLI Commands    :"
echo "   - Safe Eject    : ${SCRIPT_DIR}/immich-eject.sh [--gui]"
echo "   - Pre-Check     : ${SCRIPT_DIR}/immich-precheck.sh"
echo "   - Stop Stack    : ${SCRIPT_DIR}/immich-stop.sh"
echo ""

# Run Pre-flight verification
echo "=== [Running Immediate Pre-Flight Check] ==="
"${SCRIPT_DIR}/immich-precheck.sh" || {
    echo "[WARN] Pre-flight check finished with warnings. Review above output."
}
