#!/usr/bin/env bash
# =============================================================================
# serve.sh — Levanta vLLM con los MISMOS parámetros en GPU arrendada y en local.
#
# Se ejecuta:
#   - en el pod arrendado (runpod-up.sh lo inyecta como BOOT_B64), o
#   - en tu máquina (docker-compose.inference.yml lo monta en el contenedor).
#
# Todo se controla por variables de entorno (ver inference/profiles/*.env):
#   MODEL_A, NAMES_A, MAX_LEN_A, GPUS_A, PORT_A, EXTRA_ARGS_A   (obligatorio)
#   MODEL_B, NAMES_B, MAX_LEN_B, GPUS_B, PORT_B, EXTRA_ARGS_B   (opcional)
#   VLLM_API_KEY      clave que exigirá vLLM en /v1 (obligatoria)
#   GPU_MEM_UTIL      fracción de VRAM para vLLM (default 0.92)
#   TUNNEL_MODE       tailscale | public | none
#   TS_AUTHKEY, TS_HOSTNAME   (si TUNNEL_MODE=tailscale)
#   METRICS_DIR       dónde guardar métricas de GPU (default /workspace/metrics)
# =============================================================================
set -euo pipefail

log() { echo "[fabrica] $*"; }

: "${MODEL_A:?Falta MODEL_A}"
: "${VLLM_API_KEY:?Falta VLLM_API_KEY}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.92}"
TUNNEL_MODE="${TUNNEL_MODE:-none}"
METRICS_DIR="${METRICS_DIR:-/workspace/metrics}"
export HF_HOME="${HF_HOME:-/workspace/hf-cache}"   # en el network volume: no se re-descarga
mkdir -p "$HF_HOME" "$METRICS_DIR"

# ---------------------------------------------------------------------------
# 1) Túnel privado (solo en el arriendo). En local usar TUNNEL_MODE=none.
# ---------------------------------------------------------------------------
if [[ "$TUNNEL_MODE" == "tailscale" ]]; then
  : "${TS_AUTHKEY:?Falta TS_AUTHKEY para TUNNEL_MODE=tailscale}"
  TS_HOSTNAME="${TS_HOSTNAME:-fabrica-gpu}"
  if ! command -v tailscaled >/dev/null 2>&1; then
    log "Instalando Tailscale..."
    command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl >/dev/null; }
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
  fi
  mkdir -p /workspace/tailscale
  # Modo userspace: no requiere /dev/net/tun (los pods son contenedores sin TUN).
  tailscaled --tun=userspace-networking \
             --state=/workspace/tailscale/tailscaled.state \
             --socket=/tmp/tailscaled.sock >/tmp/tailscaled.log 2>&1 &
  sleep 3
  tailscale --socket=/tmp/tailscaled.sock up \
            --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" --accept-dns=false
  log "Tailscale arriba como '$TS_HOSTNAME'"
elif [[ "$TUNNEL_MODE" == "public" ]]; then
  log "ADVERTENCIA: modo public. vLLM queda expuesto a internet protegido solo por VLLM_API_KEY."
fi

# ---------------------------------------------------------------------------
# 2) Registro de uso de GPU (VRAM, utilización) para decidir qué hardware comprar
# ---------------------------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1; then
  (
    echo "timestamp,gpu,name,mem_used_mib,mem_total_mib,util_pct" > "$METRICS_DIR/gpu.csv"
    while true; do
      nvidia-smi --query-gpu=timestamp,index,name,memory.used,memory.total,utilization.gpu \
                 --format=csv,noheader,nounits >> "$METRICS_DIR/gpu.csv" 2>/dev/null || true
      sleep 15
    done
  ) &
  # En modo tailscale se sirve la carpeta de métricas SOLO por el túnel (puerto 9100),
  # para que scripts/collect-metrics.sh pueda bajar gpu.csv.
  if [[ "$TUNNEL_MODE" == "tailscale" ]]; then
    python3 -m http.server 9100 --directory "$METRICS_DIR" >/dev/null 2>&1 &
  fi
fi

# ---------------------------------------------------------------------------
# 3) Instancias de vLLM. A siempre; B si se definió MODEL_B (p. ej. 2 GPUs).
# ---------------------------------------------------------------------------
start_vllm() {
  local tag="$1" model="$2" names="$3" max_len="$4" gpus="$5" port="$6" extra="$7"
  local tp
  tp=$(awk -F, '{print NF}' <<<"$gpus")
  log "Instancia $tag: $model | nombres: $names | GPUs: $gpus (TP=$tp) | contexto: $max_len | puerto: $port"
  # shellcheck disable=SC2086
  CUDA_VISIBLE_DEVICES="$gpus" vllm serve "$model" \
      --host 0.0.0.0 --port "$port" \
      --served-model-name $names \
      --api-key "$VLLM_API_KEY" \
      --tensor-parallel-size "$tp" \
      --max-model-len "$max_len" \
      --gpu-memory-utilization "$GPU_MEM_UTIL" \
      --enable-prefix-caching \
      --enable-auto-tool-choice \
      $extra 2>&1 | sed -u "s/^/[vllm-$tag] /" &
}

start_vllm A "$MODEL_A" "${NAMES_A:-razonamiento codigo}" "${MAX_LEN_A:-32768}" \
           "${GPUS_A:-0}" "${PORT_A:-8000}" "${EXTRA_ARGS_A:-}"

if [[ -n "${MODEL_B:-}" ]]; then
  start_vllm B "$MODEL_B" "${NAMES_B:-codigo}" "${MAX_LEN_B:-32768}" \
             "${GPUS_B:-1}" "${PORT_B:-8001}" "${EXTRA_ARGS_B:-}"
fi

# Si cualquier instancia muere, el contenedor termina (y lo ves en los logs del pod).
wait -n
log "Una instancia de vLLM terminó; saliendo."
exit 1
