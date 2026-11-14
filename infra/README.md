# Fábrica de agentes IA: inferencia en GPU arrendada → local

Base para la **Fase 1 (GPU arrendada en RunPod)**, preparada para pasar a la
**Fase 2/3 (híbrido y local)** sin tocar los agentes.

```
Agentes (BMAD / Spec Kit / OpenHands)
   │  piden "razonamiento" o "codigo" a http://localhost:4000/v1
   ▼
Gateway LiteLLM (tu máquina)         ← lo único que cambia entre fases (gateway/.env)
   │  túnel privado (Tailscale)
   ▼
vLLM en pod RunPod  ──(Fase 2/3)──▶  vLLM en tu GPU
  mismo serve.sh · misma imagen · mismo modelo · mismos flags
```

## Estructura

| Ruta | Qué es |
|---|---|
| `inference/serve.sh` | Arranca vLLM. **El mismo script** corre en el pod y en local. |
| `inference/profiles/*.env` | Perfiles de hardware: `poc-48gb` (empezar aquí), `poc-24gb`, `dev-2x24gb`. |
| `inference/docker-compose.inference.yml` | vLLM en tu máquina (Fase 2/3). |
| `gateway/` | LiteLLM con los nombres lógicos `razonamiento` y `codigo`. |
| `scripts/runpod-up.sh` / `runpod-down.sh` | Crear / terminar el pod y apuntar el gateway. |
| `scripts/smoke-test.sh` | Verifica gateway, cada rol y que las tool calls lleguen estructuradas. |
| `scripts/collect-metrics.sh` | Mide KV cache, tokens y VRAM real → para decidir qué comprar. |
| `scripts/use-local.sh` | Cambia el gateway a vLLM local. |
| `bench/` | Benchmark propio con resultado verificable (tool call, spec JSON, código con tests, contexto largo). |

## Requisitos

- Cuenta en RunPod con saldo y una **API key**.
- Cuenta en Tailscale (gratis) con una **auth key efímera y reutilizable**, y Tailscale instalado en tu máquina.
- En tu máquina: `docker`, `jq`, `curl`, `python3`.
- (Opcional) Token de Hugging Face.

## Fase 1 — paso a paso

1. **Network volume (una sola vez).** En la consola de RunPod crea un network volume
   de ~100 GB en un datacenter que tenga la GPU del perfil. Ahí quedan los pesos:
   el primer arranque descarga ~35 GB; los siguientes no.
   Ojo: el pod debe crearse en el **mismo datacenter** que el volumen.

2. **Configuración.**
   ```bash
   cp .env.example .env
   # completa RUNPOD_API_KEY, NETWORK_VOLUME_ID, TS_AUTHKEY
   # genera claves:  openssl rand -hex 24   (VLLM_API_KEY y LITELLM_MASTER_KEY=sk-...)
   docker network create fabrica
   ```

3. **Levantar la GPU.**
   ```bash
   ./scripts/runpod-up.sh inference/profiles/poc-48gb.env
   nohup ./scripts/auto-stop.sh 3 > .state/auto-stop.log 2>&1 &   # corte a las 3 h, por si olvidas
   ```
   El script crea el pod, espera al túnel y a que vLLM cargue, y escribe `gateway/.env`.

4. **Gateway.**
   ```bash
   docker compose -f gateway/docker-compose.gateway.yml up -d --force-recreate
   ./scripts/smoke-test.sh
   ```

5. **Medir.** En una terminal: `./scripts/collect-metrics.sh`. En otra:
   ```bash
   python3 bench/run_bench.py --label poc-48gb
   ```
   Luego usa los agentes reales (ver abajo) con las métricas corriendo.

6. **Apagar.** `./scripts/runpod-down.sh` (termina el pod; los pesos quedan en el volumen
   y la sesión se anota en `metrics/sesiones.csv`).

### Conectar los agentes

Cualquier herramienta compatible con OpenAI:

| Parámetro | Valor |
|---|---|
| Base URL | `http://localhost:4000/v1` (desde Docker: `http://fabrica-gateway:4000/v1` en la red `fabrica`) |
| API key | tu `LITELLM_MASTER_KEY` |
| Modelo | `razonamiento` (Req, Arquitecto, Líder) · `codigo` (Dev, QA) |

En OpenHands el modelo se escribe con prefijo: `openai/codigo`.

## Qué perfil probar y en qué orden

1. **`poc-48gb`**: 1 GPU de 48 GB y pesos FP8 oficiales. Es el camino con menos sorpresas para validar el flujo completo.
2. **`poc-24gb`**: simula una RTX 3090/4090 con un modelo 4-bit. Corre el **mismo benchmark** y compara. Si los resultados se mantienen, 24 GB te alcanzan.
3. **`dev-2x24gb`**: un modelo por GPU (razonamiento y código separados), que simula 2× RTX 3090.

> Los repos AWQ de `poc-24gb` y `dev-2x24gb` son de la comunidad: confirma en Hugging Face que existan y que funcionen con tu versión de vLLM antes de usarlos.

## Fase 2/3 — pasar a local

```bash
cp inference/profiles/poc-24gb.env inference/local.env     # el perfil que validaste
docker compose -f inference/docker-compose.inference.yml --env-file .env up -d
./scripts/use-local.sh inference/local.env
docker compose -f gateway/docker-compose.gateway.yml up -d --force-recreate
./scripts/smoke-test.sh && python3 bench/run_bench.py --label local
```

Para el **modo híbrido**, después de `use-local.sh` edita `gateway/.env` y deja una de las
dos URLs apuntando al pod.

## Reglas para que la migración no rompa nada

- **Fija la versión de vLLM.** Cuando funcione, cambia `VLLM_IMAGE` de `latest` a una versión concreta (≥ 0.19 para Qwen3.6) y usa **la misma** en local.
- **No cambies de runtime sin el benchmark.** vLLM y Ollama difieren en el formato de pesos, el parser de tool calls y los límites de contexto.
- `--tool-call-parser` es obligatorio: sin él, el modelo genera la tool call como texto y los agentes fallan sin mostrar un error. `smoke-test.sh` lo detecta.

## Seguridad y costos

- `CLOUD_TYPE=SECURE` (por defecto): en Community Cloud los hosts son de terceros.
- Durante la Fase 1 el código y los prompts pasan por la máquina arrendada: usa repos de prueba o datos sintéticos.
- Las claves viajan como variables de entorno del pod (visibles en tu consola de RunPod). Rótalas si compartes la cuenta.
- `TUNNEL_MODE=public` expone vLLM a internet protegido solo por la API key: úsalo solo para una prueba rápida.
- Con `metrics/sesiones.csv` (horas × USD/h) puedes comparar el costo mensual de arrendar con el de comprar.
