#!/bin/sh
# Daily consistent copy of the name registry, kept 14 days. Every row carries
# a card signed by its owner, so a restored copy with a forged row shows it.
set -eu
dir=/root/backups/cubechat-id
mkdir -p "$dir"
sqlite3 /opt/cubechat-id/names.db ".backup '$dir/names-$(date +%F).db'"
find "$dir" -name 'names-*.db' -mtime +14 -delete
