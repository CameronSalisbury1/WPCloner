#!/bin/bash
set -e

LOCAL_DIR="/var/www/html/wwwroot-local"
BIND_TARGET="/var/www/html/wwwroot"
SOURCE="/home/site/wwwroot"

echo "[$(date)] Starting wwwroot local copy process..."

# Copy nginx config and reload
echo "[$(date)] Updating nginx config..."
cp /home/site/default /etc/nginx/sites-enabled/default
nginx -s reload

# Ensure rsync is installed
echo "[$(date)] Ensuring rsync is available..."
if ! ls /etc/apt/sources.list.d/*.bak 2>/dev/null | grep -q .; then
    for f in /etc/apt/sources.list.d/*; do
        cp "$f" "$f.bak"
        grep -q 'http://' "$f" && sed -i 's|http://|https://|g' "$f"
    done
fi
apt-get update -qq
apt-get install -y -qq rsync

if [ -f "$LOCAL_DIR/.sync-ready" ]; then
    echo "[$(date)] $LOCAL_DIR/.sync-ready exists, skipping rsync."
else
    mkdir -p "$LOCAL_DIR"

    # Sync from slow mounted drive to local fast storage
    # Exclude uploads since Azure Storage is mounted directly there
    echo "[$(date)] Rsyncing $SOURCE to $LOCAL_DIR..."
    rsync -a --delete \
        --exclude="wp-content/uploads" \
        "$SOURCE/" "$LOCAL_DIR/"

    echo "[$(date)] Rsync complete."
    touch "$LOCAL_DIR/.sync-ready"

    # Repoint the wwwroot symlink to the local copy
    echo "[$(date)] Relinking $BIND_TARGET -> $LOCAL_DIR..."
    unlink "$BIND_TARGET"
    ln -s "$LOCAL_DIR" "$BIND_TARGET"
fi

# Start background sync loop
nohup bash /home/site/sync.sh > /var/log/sync.log 2>&1 &

echo "[$(date)] Done. WordPress is now running from local storage.