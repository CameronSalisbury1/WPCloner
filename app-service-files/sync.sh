#!/bin/bash

LOCAL_DIR="/var/www/html/wwwroot-local"
SOURCE="/home/site/wwwroot"
SENTINEL="$LOCAL_DIR/.sync-ready"

echo "[$(date)] Starting background sync loop..."
while true; do
    sleep 30

    if [ ! -f "$SENTINEL" ]; then
        echo "[$(date)] Sentinel $SENTINEL not found — initial sync not complete, skipping."
        continue
    fi

    rsync -a --delete \
        --exclude="wp-content/uploads" \
        "$LOCAL_DIR/" "$SOURCE/"

    if [ $? -ne 0 ]; then
        echo "[$(date)] rsync exited with error $? — skipping this cycle."
    fi
done