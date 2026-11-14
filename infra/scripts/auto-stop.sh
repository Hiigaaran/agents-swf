#!/usr/bin/env bash
# auto-stop.sh HORAS — termina el pod después de N horas (protección contra olvidos).
#   nohup ./scripts/auto-stop.sh 3 > .state/auto-stop.log 2>&1 &
set -euo pipefail
HOURS="${1:?uso: auto-stop.sh HORAS}"
sleep "$(awk -v h="$HOURS" 'BEGIN{printf "%d", h*3600}')"
exec "$(dirname "$0")/runpod-down.sh"
