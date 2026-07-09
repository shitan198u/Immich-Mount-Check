# Docker Compose Mount Check (for Immich)

A fail-safe Docker Compose utility to prevent containers from starting if an external hard drive (e.g., a media library disk) is not mounted on the host machine. 

![Mount Check Logs](mount_log.png)

This tool is designed to work seamlessly with GitOps workflows, Docker managers (like Portainer or Arcane), or standard Docker Compose deployments. It uses a **Docker Compose override file** so you can safely auto-update your main Immich configuration without losing your mount-checking logic.

---

## 🚀 Quick Start

### Step 1: Copy the Environment Template
Create your local environment file by copying the template:
```bash
cp .env.example .env
```

### Step 2: Configure Your Paths in `.env`
Open the `.env` file and set the paths according to where your drive is mounted:

```env
# 1. How your drive mounts on the host (e.g., /media/username/my-external-drive)
EXTERNAL_MOUNT_PARENT=/media/username
EXTERNAL_MOUNT_NAME=my-external-drive

# 2. Where your Immich data lives
UPLOAD_LOCATION=/media/username/my-drive/immich/upload    # External HDD
DB_DATA_LOCATION=/home/username/immich/postgres           # OS SSD (Recommended)
```

*(If you are hosting everything on your primary OS SSD and don't need a mount check, simply leave the mount check variables blank).*

### Step 3: Run the Stack
Start your stack normally:
```bash
docker compose up -d
```

---

## 🛠️ Technical Details & Architecture

### The Problem It Solves
When using standard Docker bind mounts, if a host path (like `/media/username/my-drive`) is missing because the drive is unplugged, Docker automatically creates an empty, root-owned folder at that path on your host SSD and starts the container anyway. 

This causes:
*   Your container to write data to your OS partition instead of the external drive.
*   Your primary storage drive to fill up and crash.
*   Database splitting/corruption once the drive is reconnected.

### How this Mount Check works
The validation process runs in two layers inside `docker-compose.override.yml`:

#### 1. The `wait-for-mount` Helper Container
A lightweight Alpine container bind-mounts your drive's parent directory (e.g., `/media/username`) into the container using `propagation: rslave` (recursive slave). 
* It runs `mountpoint -q /host_mnt/my-drive` in a loop.
* Because it queries the Linux kernel's **mount table** rather than checking if the directory has files, it is immune to "lingering files" (empty database folders or leftovers) that might remain on your SSD from previous failed boots.
* Once the drive is mounted on the host, the event propagates into the container, the health check passes, and the rest of the stack is allowed to boot.

#### 2. Strict Service Dependencies
All other services (`database`, `redis`, `immich-machine-learning`, and `immich-server`) are configured to depend on the `wait-for-mount` service being `healthy`. They remain paused in a `created` state and do not run until the disk is verified.

#### 3. Fail-Fast Volume Overrides
The volume mounts for the server and database are updated in the override file to set `create_host_path: false`. In the event of a system failure, Docker will crash immediately rather than auto-generating directories.

---

## 📄 License
This project is licensed under the [MIT License](LICENSE).
