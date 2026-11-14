#!/usr/bin/env bash
# =============================================================================
# runpod-up.sh — Crea un pod GPU en RunPod con vLLM + serve.sh, espera a que el
# modelo esté listo y apunta el gateway a él.
#
#   ./scripts/runpod-up.sh inference/profiles/poc-48gb.env
# =============================================================================
source "$(dirname "$0")/lib.sh"
need curl jq base64

load_env
load_profile "${1:-}"
mkdir -p "$STATE_DIR"
[[ -f "$STATE_DIR/pod.env" ]] && die "Ya hay un pod registrado en .state/pod.env. Bájalo primero con scripts/runpod-down.sh"
[[ -n "${VLLM_API_KEY:-}" && -n "${LITELLM_MASTER_KEY:-}" ]] || die "Define VLLM_API_KEY y LITELLM_MASTER_KEY en .env"
TUNNEL_MODE="${TUNNEL_MODE:-tailscale}"
[[ "$TUNNEL_MODE" != "tailscale" || -n "${TS_AUTHKEY:-}" ]] || die "TUNNEL_MODE=tailscale requiere TS_AUTHKEY"

BOOT_B64="$(base64 < "$ROOT/inference/serve.sh" | tr -d '\n')"
export BOOT_B64 TUNNEL_MODE

# Variables que viajan al pod (solo las definidas)
ENV_KEYS='["MODEL_A","NAMES_A","MAX_LEN_A","GPUS_A","PORT_A","EXTRA_ARGS_A",
           "MODEL_B","NAMES_B","MAX_LEN_B","GPUS_B","PORT_B","EXTRA_ARGS_B",
           "GPU_MEM_UTIL","VLLM_API_KEY","HF_TOKEN","TUNNEL_MODE","TS_AUTHKEY","TS_HOSTNAME","BOOT_B64"]'

if [[ "$TUNNEL_MODE" == "public" ]]; then PORTS='["8000/tcp","8001/tcp"]'; else PORTS='[]'; fi

BODY="$(jq -n \
  --arg name "${POD_NAME:-fabrica-gpu}-${PROFILE_NAME}" \
  --arg image "${VLLM_IMAGE:-vllm/vllm-openai:latest}" \
  --arg gpus "$GPU_TYPE_IDS" \
  --argjson count "${GPU_COUNT:-1}" \
  --arg cloud "${CLOUD_TYPE:-SECURE}" \
  --argjson disk "${CONTAINER_DISK_GB:-40}" \
  --arg vol "${NETWORK_VOLUME_ID:-}" \
  --argjson ports "$PORTS" \
  --argjson keys "$ENV_KEYS" \
  '{
     name: $name,
     imageName: $image,
     gpuTypeIds: ($gpus | split(",") | map(gsub("^\\s+|\\s+$"; ""))),
     gpuCount: $count,
     cloudType: $cloud,
     containerDiskInGb: $disk,
     volumeMountPath: "/workspace",
     ports: $ports,
     env: ([ $keys[] as $k | select((env[$k] // "") != "") | {($k): env[$k]} ] | add),
     dockerEntrypoint: ["bash", "-c"],
     dockerStartCmd: ["echo \"$BOOT_B64\" | base64 -d > /tmp/serve.sh && exec bash /tmp/serve.sh"]
   }
   + (if $vol != "" then {networkVolumeId: $vol} else {volumeInGb: 100} end)')"

log "Creando pod ($PROFILE_NAME, GPUs: $GPU_TYPE_IDS ×${GPU_COUNT:-1}, $CLOUD_TYPE)..."
RESP="$(runpod POST /pods "$BODY")" || die "RunPod rechazó la creación (¿sin stock de esa GPU o en ese datacenter?)"
POD_ID="$(jq -r '.id' <<<"$RESP")"
COST="$(jq -r '.costPerHr // "?"' <<<"$RESP")"
[[ -n "$POD_ID" && "$POD_ID" != "null" ]] || die "Respuesta inesperada: $RESP"

cat > "$STATE_DIR/pod.env" <<EOF
POD_ID=$POD_ID
PROFILE_FILE=$PROFILE_FILE
CREATED_AT=$(date -Iseconds)
COST_PER_HR=$COST
EOF
log "Pod $POD_ID creado — costo aprox. USD $COST/h. Esperando que inicie..."

# ---------------------------------------------------------------------------
# Resolver la URL de cada instancia según el modo de túnel
# ---------------------------------------------------------------------------
BASE_A=""; BASE_B=""
for _ in $(seq 1 90); do   # hasta ~15 min para que el pod arranque
  POD="$(runpod GET "/pods/$POD_ID" || echo '{}')"
  if [[ "$TUNNEL_MODE" == "public" ]]; then
    IP="$(jq -r '.publicIp // empty' <<<"$POD")"
    PA="$(jq -r --arg p "${PORT_A:-8000}" '.portMappings[$p] // empty' <<<"$POD")"
    if [[ -n "$IP" && -n "$PA" ]]; then
      BASE_A="http://$IP:$PA"
      [[ -n "${MODEL_B:-}" ]] && BASE_B="http://$IP:$(jq -r --arg p "${PORT_B:-8001}" '.portMappings[$p]' <<<"$POD")"
      break
    fi
  else
    if command -v tailscale >/dev/null 2>&1; then
      TSIP="$(tailscale ip -4 "${TS_HOSTNAME:-fabrica-gpu}" 2>/dev/null | head -n1 || true)"
    else
      TSIP="${TS_HOSTNAME:-fabrica-gpu}"   # depende de MagicDNS
    fi
    if [[ -n "${TSIP:-}" ]]; then
      BASE_A="http://$TSIP:${PORT_A:-8000}"
      [[ -n "${MODEL_B:-}" ]] && BASE_B="http://$TSIP:${PORT_B:-8001}"
      break
    fi
  fi
  sleep 10
done
[[ -n "$BASE_A" ]] || die "El pod no quedó accesible. Revisa los logs en la consola de RunPod."
{ echo "BASE_A=$BASE_A"; echo "BASE_B=$BASE_B"; } >> "$STATE_DIR/pod.env"

# ---------------------------------------------------------------------------
# Esperar a que vLLM cargue el modelo (la 1ª vez descarga los pesos: puede tardar)
# ---------------------------------------------------------------------------
wait_health() {
  local base="$1"
  log "Esperando a vLLM en $base (la primera vez descarga ~20–35 GB)..."
  for _ in $(seq 1 240); do   # hasta 40 min
    if curl -fsS -m 5 -H "Authorization: Bearer $VLLM_API_KEY" "$base/health" >/dev/null 2>&1; then
      log "Listo: $base"; return 0
    fi
    sleep 10
  done
  die "vLLM no respondió en $base. Revisa los logs del pod (líneas [vllm-A]/[vllm-B])."
}
wait_health "$BASE_A"
[[ -n "$BASE_B" ]] && wait_health "$BASE_B"

write_gateway_env "$BASE_A" "$BASE_B"
log "Pod listo. Recuerda bajarlo al terminar: ./scripts/runpod-down.sh"
log "Corte automático opcional: nohup ./scripts/auto-stop.sh 3 &   (3 horas)"
