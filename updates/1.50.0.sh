#!/usr/bin/env bash

set -e
export NCPCFG=/usr/local/etc/ncp.cfg

bash -c "sleep 6; source /usr/local/etc/library.sh; clearOpCache" &>/dev/null &
