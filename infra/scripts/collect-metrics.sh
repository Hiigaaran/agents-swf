#!/usr/bin/env bash
# =============================================================================
# collect-metrics.sh — Muestrea métricas de vLLM cada N segundos mientras corres
# los agentes o el benchmark. Sirve para decidir qué hardware comprar.
#
#   ./scripts/collect-metrics.sh        # Ctrl+C para terminar
#
# Al terminar baja gpu.csv (VRAM real usada) si el pod usa Tailscale.
# =============================================================================
source "$(dirname "$0")/lib.sh"
need curl awk
load_env
[[ -f "$STATE_DIR/pod.env" ]] || die "No hay pod registrado (.state/pod.env)"
# shellcheck disable=SC1091
source "$STATE_DIR/pod.env"
INTERVAL="${INTERVAL:-10}"
PROFILE="$(basename "$PROFILE_FILE" .env)"
mkdir -p "$ROOT/metrics"
OUT="$ROOT/metrics/vllm-$PROFILE-$(date +%Y%m%d-%H%M).csv"
echo "timestamp,instancia,requests_running,requests_waiting,kv_cache_pct,prompt_tokens_total,generation_tokens_total" > "$OUT"

sample() {   # sample TAG BASE
  curl -fsS -m 5 -H "Authorization: Bearer $VLLM_API_KEY" "$2/metrics" 2>/dev/null | awk -v ts="$(date -Iseconds)" -v tag="$1" '
    /^vllm:num_requests_running/                         { run += $NF }
    /^vllm:num_requests_waiting/                         { wait += $NF }
    /^vllm:(kv_cache_usage_perc|gpu_cache_usage_perc)/   { kv = $NF * 100 }
    /^vllm:prompt_tokens_total/                          { pt += $NF }
    /^vllm:generation_tokens_total/                      { gt += $NF }
    END { printf "%s,%s,%d,%d,%.1f,%d,%d\n", ts, tag, run, wait, kv, pt, gt }'
}

finish() {
  if [[ "${TUNNEL_MODE:-tailscale}" == "tailscale" ]]; then
    HOST="$(sed -E 's#https?://([^:/]+).*#\1#' <<<"$BASE_A")"
    if curl -fsS -m 10 "http://$HOST:9100/gpu.csv" -o "$ROOT/metrics/gpu-$PROFILE-$(date +%Y%m%d-%H%M).csv" 2>/dev/null; then
      log "VRAM/uso de GPU guardado en metrics/gpu-$PROFILE-*.csv"
      awk -F, 'NR>1 && $4>m {m=$4} END {if (m) printf "    VRAM máxima observada: %d MiB\n", m}' \
          "$(ls -t "$ROOT"/metrics/gpu-"$PROFILE"-*.csv | head -n1)"
    fi
  fi
  log "Métricas de vLLM en $OUT"
  exit 0
}
trap finish INT TERM

log "Muestreando cada ${INTERVAL}s → $OUT (Ctrl+C para terminar)"
while true; do
  sample A "$BASE_A" >> "$OUT" || true
  [[ -n "${BASE_B:-}" ]] && { sample B "$BASE_B" >> "$OUT" || true; }
  sleep "$INTERVAL"
done
