#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh — Verifica el gateway: modelos visibles, respuesta de cada rol
# y que las tool calls lleguen ESTRUCTURADAS (el error silencioso más común).
# =============================================================================
source "$(dirname "$0")/lib.sh"
need curl jq
load_env
GW="${GATEWAY_URL:-http://localhost:4000/v1}"
AUTH="Authorization: Bearer $LITELLM_MASTER_KEY"
fail=0

log "Modelos en el gateway:"
curl -fsS "$GW/models" -H "$AUTH" | jq -r '.data[].id' || { echo "  gateway no responde"; exit 1; }

for m in razonamiento codigo; do
  log "Chat simple → $m"
  out="$(curl -fsS "$GW/chat/completions" -H "$AUTH" -H "Content-Type: application/json" \
        -d "$(jq -n --arg m "$m" '{model:$m, max_tokens:512,
              messages:[{role:"user",content:"Responde solo: OK"}]}')" || true)"
  if [[ -n "$out" ]]; then
    echo "  respuesta: $(jq -r '.choices[0].message.content // "" | .[0:80]' <<<"$out")"
    echo "  tokens:    $(jq -c '.usage' <<<"$out")"
  else
    echo "  FALLÓ"; fail=1
  fi
done

log "Tool calling → codigo"
out="$(curl -fsS "$GW/chat/completions" -H "$AUTH" -H "Content-Type: application/json" -d '{
  "model": "codigo", "max_tokens": 1024, "tool_choice": "auto",
  "messages": [{"role":"user","content":"Lee el archivo specs/AC-001.md"}],
  "tools": [{"type":"function","function":{"name":"leer_archivo",
    "description":"Lee un archivo del repositorio",
    "parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}]
}' || true)"
name="$(jq -r '.choices[0].message.tool_calls[0].function.name // empty' <<<"$out" 2>/dev/null)"
if [[ "$name" == "leer_archivo" ]]; then
  echo "  OK: $(jq -c '.choices[0].message.tool_calls[0].function' <<<"$out")"
else
  echo "  FALLÓ: no llegó tool_calls estructurado. Revisa --enable-auto-tool-choice y --tool-call-parser."
  fail=1
fi

[[ $fail -eq 0 ]] && log "Smoke test OK" || { log "Smoke test con fallas"; exit 1; }
