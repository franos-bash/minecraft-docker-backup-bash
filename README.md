# MINECRAFT DOCKER BACKUP TOOL

## How it works

This script works by reading a docker-compose file that is in the same directory as itself, for example:

'''user@server:/path/to/minecraft-container$ ls
'''backup.sh*  data/  docker-compose.yml

After the script runs for the first time, it will create a directory for the backups and a log file:

'''user@server:/path/to/minecraft-container$ ls
'''autobkp/  autobkp.log  backup.sh*  data/  docker-compose.yml

It will not automatically execute itself, needs a cronjob to be set:

'''user@server: crontab -e

'''# Add this line:
'''0 4,16 * * * /path/to/minecraft-container/backup.sh

In this example, the script will run every time the minute is 0, and the hour is 4 or 16, every day.
Meaning, every day at 4:00 and 16:00.

## What it does:

reads the .yaml file, check your container name, finds your data directory path, finds your player data directory, and the server.properties file.
checks server.properties file for rcon port and password
tests rcon connection, if it works:
checks if there are players online, sends a 5 minute warning in chat and starts the countdown (if there are no players online, skips countdown)
kicks all players, save all changes, and stops the server gracefully
creates directory autobkp if there isn't one
checks number of copies in the autobkp dir
compares last backup player data to current player data, if there are no changes, does not execute backup, else:
copies your world directory to autobkp in your docker container dir with rsync, with a timestamped name
starts the docker container.

## Features

Keeps a log on the container directory (autobkp.log)
Will create a lock file to make sure the script cannot be executed more than once simultaniously
Modify settings inside the script:

'''# ====== CONFIGS ======
'''RCON_STOP_TIMEOUT=30      # Timeout to gracefully stop the server
'''MAX_BACKUP_COPIES=10      # Set max number of copies to be kept
'''MIN_DISK_SPACE_MB=1000    # minimum disk space required in order to execute 
'''LOG_SIZE_LIMIT=10485760   # 10MB - Set the log file size limit
'''CONTAINER_CHECK_RETRIES=3 # Number of retries to start container
