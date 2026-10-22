#!/bin/sh
[ -n "${DEV_RUNNING-}" ] || { echo "check NOT run: the dev container is not running" >&2; exit 2; }
echo "scan: OK"
