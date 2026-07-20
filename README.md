# MINECRAFT DOCKER BACKUP TOOL

## Overview

This is an automated backup script for Minecraft servers running in Docker containers. It gracefully stops the server, creates timestamped backups of your world data, and restarts the container—all while safely managing player sessions and maintaining a configurable history of backups.

## Requirements

- Docker (with `docker-compose` or `docker compose` command)
- Bash shell
- `rsync` for backup copying
- RCON enabled in your `server.properties`
- `rcon-cli` tool available in the container (for Minecraft Java Edition)


## Setup Instructions

1. Stop your server container `docker stop container-name`
2. Make a copy of your entire container directory before testing `cp -r /container/path/mc-container /container/path/mc-container.bkp`
3. Start the Container `cd /container/path/mc-container && docker-compose up -d`
4. Download backup.sh file `git clone https://github.com/franos-bash/minecraft-docker-backup-bash.git`
5. Place it on the same directory as your minecraft server's docker-compose.yml file
6. Make the script executable `sudo chmod +x backup.sh` or on GUI: right click on file > properties > execute as program
7. Check if server is running healthy`docker ps` 
8. run the script `./backup.sh`.
9. watch output to check for errors
10. If everything works as expected set up a cron job to run it on a schedule

!!! This will start a 5 min timer, kick all players and restart the server when it ends !!!

## How it works

This script works by reading a `docker-compose` file that is in the same directory as itself. For example:

```bash
mc-container/
├── backup.sh*
├── data/
└── docker-compose.yml

```
When executed, it will read the .yml file to gather info, such as container name and bind mount path.

After the script runs for the first time, it will create a directory for the backups and a log file:
(creates everything on the container directory by default)

```bash
mc-container/
├── autobkp/
├── autobkp.log
├── backup.sh*
├── data/
└── docker-compose.yml
```

### Setting up automatic backups with cron

The script will not automatically execute itself—you need to set up a cronjob:

```bash
user@server:~$ crontab -e

# Add this line:
0 4,16 * * * /path/to/minecraft-container/backup.sh
```

In this example, the script will run every day at **4:00 AM** and **4:00 PM** (16:00). The cron format is `minute hour day month weekday`.

Visit https://crontab.guru/ to check crontab syntax if not sure

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

## Troubleshooting

- **"docker-compose.yml not found"**: Ensure the script is in the same directory as your compose file
- **"RCON connection failed"**: Verify RCON is enabled and credentials are correct in `server.properties`
- **"Insufficient disk space"**: Increase `MIN_DISK_SPACE_MB` or free up disk space
- **"Container failed to start"**: Check Docker logs with `docker logs <container_name>`
- Check `autobkp.log` for detailed error messages and operation history
