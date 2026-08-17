# Docker Compose Mount Check & Auto-Systemd (for Immich)

A fail-safe Docker Compose utility and systemd lifecycle manager to **automatically start Immich whenever an external drive is mounted**, perform deep pre-flight safety checks, protect against hot unplugs, and integrate natively with Linux desktop environments (like KDE Plasma).

![Mount Check Logs](mount_log.png)

---

## 🌟 Key Features

1. **Auto-Start on Mount (`systemd`)**: Binds the Docker Compose stack to your drive's systemd mount unit (`BindsTo=`, `WantedBy=`). When you plug in or mount your drive, Immich starts automatically.
2. **Boot-Time Isolation (`ConditionPathIsMountPoint=`)**: Cleanly skips the unit if the drive is absent during system boot without producing failed service errors.
3. **Deep Pre-Flight Safety Checks**:
   * **Kernel Mountpoint Validation**: Verifies the path is an active kernel mountpoint (`mountpoint -q`), preventing silent data writes to empty host root folders.
   * **Read-Write Probe**: Tests write capabilities to catch read-only remounts caused by filesystem errors or unclean unplugs.
   * **Identity Marker & UUID Check**: Checks for `.mount_verified` and optional `EXPECTED_FS_UUID` to prevent starting against the wrong drive.
   * **Storage Space Sanity**: Enforces minimum free space on both external storage and host database volumes before container spin-up.
   * **Docker Readiness**: Confirms the Docker daemon and compose plugins are responsive.
4. **Hot-Unplug & Interrupted Startup Protection**:
   * If the drive is unmounted or disconnected, systemd triggers `immich-stop.sh`, stopping containers and cleaning up dead file handles.
   * `ExecStopPost=` guarantees cleanup even if an unmount occurs while containers are mid-boot.
   * `wait-for-mount` uses a fast one-shot completion pattern (`condition: service_completed_successfully`), ensuring instant container teardown.
5. **KDE Plasma & Desktop Integration**:
   * **Interactive Safe Eject GUI**: Search **"Safely Eject Immich Drive"** in KRunner (Alt+Space) or Application Launcher for native `kdialog` confirmation, LUKS locking, and power-off feedback.
   * **Disks & Devices System Tray**: Integrates custom device action for both encrypted volumes and decrypted filesystems.
   * **Dolphin File Manager Menu**: Right-click your mount directory in Dolphin to access **Immich Drive Actions** (Safe Eject, Restart Stack via Systemd, Check Status).
   * **Native Desktop Notifications**: D-Bus notifications that strictly follow your system's duration settings in KDE System Settings.
6. **100% Privacy & Generic Design**:
   * Zero personal usernames, paths, or device identifiers are tracked in Git.
   * Fully parameterized via `.env` and dynamic `systemd-escape` generation.

---

## 🚀 Quick Start

### Step 1: Configure Your Local `.env`
Copy the template and set your paths:
```bash
cp .env.example .env
```

Edit `.env`:
```env
# 1. How your drive mounts on the host
EXTERNAL_MOUNT_PARENT=/media/username
EXTERNAL_MOUNT_NAME=my-external-drive

# 2. Where your Immich data lives
UPLOAD_LOCATION=/media/username/my-external-drive/immich/uploads   # External HDD
DB_DATA_LOCATION=/home/username/immich/db                          # Host OS SSD (Recommended)

# 3. (Optional) Advanced Safety
# EXPECTED_FS_UUID=faedc8fe-b406-43e6-97fc-0dfaeba457cb          # Strict UUID check
# NOTIFICATION_TIMEOUT_MS=-1                                      # -1 = KDE System Default
```

---

### Step 2: Setup Automated Systemd & Desktop Integration
Run the universal installer script:
```bash
./setup-autosystemd.sh
```

This will automatically:
* Compute your systemd mount unit name via `systemd-escape`.
* Create the `.mount_verified` marker file on your external drive.
* Generate and install `/etc/systemd/system/immich.service` with mount condition and lifecycle bindings.
* Enable `immich.service` to auto-start on mount.
* Install the KDE Desktop launcher, Solid device tray actions, and Dolphin context menus.
* Run an immediate pre-flight safety verification as your regular user.

---

## 🛠️ CLI & Desktop Utilities

| Action | Command / Location | Description |
|---|---|---|
| **Safe Eject (GUI)** | KRunner / App Menu: *Safely Eject Immich Drive*<br>Or CLI: `./scripts/immich-eject.sh --gui` | Prompts with `kdialog`, stops Immich, flushes buffers (`sync`), unmounts disk, locks LUKS container, powers down USB, and provides truthful status. |
| **Safe Eject (CLI)** | `./scripts/immich-eject.sh` | Terminal version of the safe eject workflow. |
| **Restart Stack** | Dolphin Menu: *Restart Immich Stack*<br>Or CLI: `./scripts/immich-restart.sh` | Safely restarts Immich via systemd (or fallback to compose), preserving unit state. |
| **Run Safety Pre-Check** | `./scripts/immich-precheck.sh` | Runs all pre-flight safety checks and reports status. |
| **Graceful Stop** | `./scripts/immich-stop.sh` | Safely stops containers and flushes disk buffers with defensive timeouts. |
| **Uninstall Systemd** | `./setup-autosystemd.sh --uninstall` | Disables and removes the systemd service and desktop integrations. |

---

## 🏗️ Architecture & Dual-Layer Protection

```
┌────────────────────────────────────────────────────────┐
│                   USB Drive Plugged In                 │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│      Systemd Mount Unit (e.g. mnt-storage.mount)       │
└──────────────────────────┬─────────────────────────────┘
                           │ (Triggers WantedBy=)
                           ▼
┌────────────────────────────────────────────────────────┐
│             systemd unit: immich.service               │
│        (ConditionPathIsMountPoint, BindsTo & After)    │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ ExecStartPre: scripts/immich-precheck.sh               │
│  ✔ Kernel mount table check (mountpoint -q)            │
│  ✔ Read-Write probe (detects dirty / ro remounts)      │
│  ✔ Marker file (.mount_verified) & optional UUID       │
│  ✔ DB directory & storage space sanity checks          │
└──────────────────────────┬─────────────────────────────┘
                           │ (All checks pass)
                           ▼
┌────────────────────────────────────────────────────────┐
│ ExecStart: docker compose up -d                        │
│  ✔ One-shot wait-for-mount confirms mount propagation  │
│  ✔ Immich Server, ML, Postgres, Valkey start cleanly   │
└────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────┐
│               HOT UNPLUG / UNMOUNT EVENT               │
└──────────────────────────┬─────────────────────────────┘
                           │ (Mount deactivates)
                           ▼
┌────────────────────────────────────────────────────────┐
│ ExecStop / ExecStopPost: scripts/immich-stop.sh        │
│  ✔ Graceful docker compose down with timeout           │
│  ✔ Defensive cleanup for unresponsive hanging I/O      │
│  ✔ Stack stopped cleanly without hanging Docker daemon │
└────────────────────────────────────────────────────────┘
```

---

## 📄 License
This project is licensed under the [MIT License](LICENSE).
