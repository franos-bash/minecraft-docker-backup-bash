# MINECRAFT DOCKER BACKUP TOOL

## Overview

This is an automated backup script for Minecraft servers running in Docker containers. It gracefully stops the server, creates timestamped backups of your world data, and restarts the container—all while safely managing player sessions and maintaining a configurable history of backups.

## How it works

This script works by reading a `docker-compose` file that is in the same directory as itself. For example:

```bash
user@server:/path/to/minecraft-container$ ls
backup.sh*  data/  docker-compose.yml
```

After the script runs for the first time, it will create a directory for the backups and a log file:

```bash
user@server:/path/to/minecraft-container$ ls
autobkp/  autobkp.log  backup.sh*  data/  docker-compose.yml
```

### Setting up automatic backups with cron

The script will not automatically execute itself—you need to set up a cronjob:

```bash
user@server:~$ crontab -e

# Add this line:
0 4,16 * * * /path/to/minecraft-container/backup.sh
```

In this example, the script will run every day at **4:00 AM** and **4:00 PM** (16:00). The cron format is `minute hour day month weekday`.

## What it does

1. **Reads configuration** from `docker-compose.yaml`:
   - Extracts container name
   - Finds data directory path
   - Locates player data and `server.properties`

2. **Validates RCON connection**:
   - Reads RCON port and password from `server.properties`
   - Tests connectivity before proceeding

3. **Checks for player activity**:
   - Queries online player count
   - If players are online: sends 5-minute warning and countdown messages in chat
   - If no players: skips countdown and proceeds immediately

4. **Graceful server shutdown**:
   - Kicks all players
   - Saves all changes
   - Stops the server gracefully via RCON

5. **Backup management**:
   - Creates `autobkp` directory if it doesn't exist
   - Checks number of existing backups
   - Only backs up if changes detected (compares player data with previous backup)
   - Copies world directory with `rsync` using timestamped folder name
   - Automatically removes old backups when limit is exceeded

6. **Server restart**:
   - Starts the Docker container
   - Verifies successful startup with retries

## Features

- **Logging**: Keeps detailed logs in `autobkp.log` within the container directory
- **Process safety**: Creates a lock file to prevent simultaneous executions
- **Customizable settings**: Modify configuration variables at the top of the script:

```bash
# ====== CONFIGS ======
RCON_STOP_TIMEOUT=30      # Timeout for graceful server shutdown (seconds)
MAX_BACKUP_COPIES=10      # Maximum number of backup copies to keep
MIN_DISK_SPACE_MB=1000    # Minimum required disk space before backup (MB)
LOG_SIZE_LIMIT=10485760   # 10MB - Log rotation threshold
CONTAINER_CHECK_RETRIES=3 # Retry attempts to start container
```

- **Smart backups**: Only creates backups if player data has changed since last backup
- **Disk space aware**: Checks available disk space before proceeding
- **Log rotation**: Automatically rotates log files when they exceed size limit
- **Player-friendly**: Broadcasts warning messages to connected players before restart

## Requirements

- Docker (with `docker-compose` or `docker compose` command)
- Bash shell
- `rsync` for backup copying
- RCON enabled in your `server.properties`
- `rcon-cli` tool available in the container (for Minecraft Java Edition)

## Setup

1. Place `backup.sh` in the same directory as your `docker-compose.yml`
2. Make the script executable:
   ```bash
   chmod +x backup.sh
   ```
3. Ensure your `docker-compose.yml` includes:
   - A `container_name` field
   - A volume mapping for `/data` or `/minecraft/data` in the container
4. Enable RCON in your Minecraft server's `server.properties`:
   ```properties
   enable-rcon=true
   rcon.port=25575
   rcon.password=your-secure-password
   ```
5. Add a cronjob to run the script on your desired schedule (see "Setting up automatic backups with cron" above)

## Troubleshooting

- **"docker-compose.yml not found"**: Ensure the script is in the same directory as your compose file
- **"RCON connection failed"**: Verify RCON is enabled and credentials are correct in `server.properties`
- **"Insufficient disk space"**: Increase `MIN_DISK_SPACE_MB` or free up disk space
- **"Container failed to start"**: Check Docker logs with `docker logs <container_name>`
- Check `autobkp.log` for detailed error messages and operation history
