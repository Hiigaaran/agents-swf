#!/usr/bin/env bash
# Funciones compartidas por los scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT/.state"
API="${RUNPOD_API_BASE:-https://rest.runpod.io/v1}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "Falta el comando '$c'"; done; }

load_env() {
  [[ -f "$ROOT/.env" ]] || die "No existe .env (copia .env.example a .env)"
  set -a; # shellcheck disable=SC1091
  source "$ROOT/.env"; set +a
}

load_profile() {
  local p="${1:?Indica un perfil, p. ej. inference/profiles/poc-48gb.env}"
  [[ -f "$p" ]] || p="$ROOT/$p"
  [[ -f "$p" ]] || die "No existe el perfil $1"
  set -a; # shellcheck disable=SC1090
  source "$p"; set +a
  PROFILE_FILE="$p"
}

runpod() {   # runpod METHOD PATH [JSON]
  local method="$1" path="$2" body="${3:-}"
  : "${RUNPOD_API_KEY:?Falta RUNPOD_API_KEY en .env}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" "$API$path" -H "Authorization: Bearer $RUNPOD_API_KEY" \
         -H "Content-Type: application/json" -d "$body"
  else
    curl -fsS -X "$method" "$API$path" -H "Authorization: Bearer $RUNPOD_API_KEY"
  fi
}

# Escribe gateway/.env apuntando cada nombre lógico a la instancia A o B.
write_gateway_env() {   # write_gateway_env BASE_A BASE_B
  local base_a="$1" base_b="${2:-}"
  pick() { if [[ "$1" == "B" ]]; then echo "$base_b"; else echo "$base_a"; fi; }
  local r c
  r="$(pick "${ROUTE_RAZONAMIENTO:-A}")"; c="$(pick "${ROUTE_CODIGO:-A}")"
  [[ -n "$r" && -n "$c" ]] || die "Ruta a instancia B sin MODEL_B definido en el perfil"
  cat > "$ROOT/gateway/.env" <<EOF
# Generado por $(basename "$0") — perfil ${PROFILE_NAME:-?} — $(date -Iseconds)
RAZONAMIENTO_BASE_URL=$r/v1
CODIGO_BASE_URL=$c/v1
VLLM_API_KEY=$VLLM_API_KEY
LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY
EOF
  log "gateway/.env → razonamiento: $r | codigo: $c"
  log "Reinicia el gateway para aplicar: docker compose -f gateway/docker-compose.gateway.yml up -d --force-recreate"
}
