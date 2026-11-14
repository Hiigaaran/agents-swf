#!/usr/bin/env bash
# =============================================================================
# use-local.sh — Fase 2/3: apunta el gateway a vLLM corriendo en tu máquina.
#
#   ./scripts/use-local.sh inference/local.env
#
# Para el modo híbrido (Fase 2), deja un rol en el arriendo editando
# gateway/.env a mano después de correr este script.
# =============================================================================
source "$(dirname "$0")/lib.sh"
load_env
load_profile "${1:-inference/local.env}"
BASE_A="http://fabrica-vllm:${PORT_A:-8000}"   # nombre del contenedor en la red fabrica
BASE_B=""
[[ -n "${MODEL_B:-}" ]] && BASE_B="http://fabrica-vllm:${PORT_B:-8001}"
write_gateway_env "$BASE_A" "$BASE_B"
