#!/usr/bin/env bash
# =============================================================================
# runpod-down.sh — Termina el pod (deja de cobrar GPU y disco del pod).
# Los pesos del modelo quedan en el network volume, así que el próximo
# runpod-up.sh no los vuelve a descargar.
# =============================================================================
source "$(dirname "$0")/lib.sh"
need curl jq
load_env
[[ -f "$STATE_DIR/pod.env" ]] || die "No hay pod registrado en .state/pod.env"
# shellcheck disable=SC1091
source "$STATE_DIR/pod.env"

log "Terminando pod $POD_ID..."
if command -v runpodctl >/dev/null 2>&1; then
  runpodctl pod delete "$POD_ID"
else
  runpod DELETE "/pods/$POD_ID" >/dev/null
fi

# Registro simple de horas usadas (sirve para comparar arriendo vs compra)
mkdir -p "$ROOT/metrics"
START=$(date -d "$CREATED_AT" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S%z" "$CREATED_AT" +%s 2>/dev/null || echo "")
if [[ -n "$START" ]]; then
  HOURS=$(awk -v s="$START" -v e="$(date +%s)" 'BEGIN{printf "%.2f", (e-s)/3600}')
  [[ -f "$ROOT/metrics/sesiones.csv" ]] || echo "inicio,fin,perfil,horas,usd_hora" > "$ROOT/metrics/sesiones.csv"
  echo "$CREATED_AT,$(date -Iseconds),$(basename "$PROFILE_FILE" .env),$HOURS,$COST_PER_HR" >> "$ROOT/metrics/sesiones.csv"
  log "Sesión: $HOURS h a USD $COST_PER_HR/h (registrada en metrics/sesiones.csv)"
fi
rm -f "$STATE_DIR/pod.env"
log "Listo. Si usas Tailscale, borra el nodo viejo en el panel (o usa auth keys efímeras)."
