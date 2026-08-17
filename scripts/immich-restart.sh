#!/usr/bin/env bash
# ==============================================================================
# Immich Service Restart Utility
# ==============================================================================
# Restarts Immich safely via systemd if enabled, or falls back to direct Docker Compose.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if systemctl is-active --quiet immich.service 2>/dev/null; then
    echo "[INFO] Restarting immich.service via systemd..."
    if systemctl restart immich.service 2>/dev/null; then
        echo "✔ immich.service restarted successfully."
        exit 0
    fi
fi

if systemctl is-enabled --quiet immich.service 2>/dev/null; then
    echo "[INFO] Starting immich.service via systemd..."
    if systemctl start immich.service 2>/dev/null; then
        echo "✔ immich.service started successfully."
        exit 0
    fi
fi

echo "[INFO] Systemd unit not active/manageable; restarting via Docker Compose directly..."
"${SCRIPT_DIR}/immich-stop.sh"
"${SCRIPT_DIR}/immich-precheck.sh"
cd "${BASE_DIR}"
docker compose up -d --remove-orphans
echo "✔ Immich stack restarted via Docker Compose."
exit 0
