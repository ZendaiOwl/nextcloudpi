#!/usr/bin/env bash

set -e
export NCPCFG=/usr/local/etc/ncp.cfg
source /usr/local/etc/library.sh

# Reinstall auto snapshot script to apply fix
[[ -f "$BINDIR/BACKUPS/nc-snapshot-auto.sh" ]] || exit 0
runApp nc-snapshot-auto
