# agents-swf

Implementación de una *software factory* basada en orquestación de agentes de IA que
cubre el ciclo de desarrollo completo, pensada para correr con **modelos open-weight
self-hosted**: primero en GPU arrendada y luego en hardware propio.

> **Estado (2026-11-14):** análisis de viabilidad y arquitectura cerrados. La
> infraestructura de inferencia de la Fase 1 (GPU arrendada) está implementada en
> [`infra/`](infra/) y probada contra un entorno simulado. **Falta la primera corrida
> sobre una GPU real** y la orquestación de los agentes.

---

## Índice

1. [Objetivo](#1-objetivo)
2. [Estado del proyecto](#2-estado-del-proyecto)
3. [Arquitectura de la fábrica](#3-arquitectura-de-la-fábrica)
4. [Viabilidad con modelos locales](#4-viabilidad-con-modelos-locales)
5. [Hardware](#5-hardware)
6. [Ruta de migración: GPU arrendada → local](#6-ruta-de-migración-gpu-arrendada--local)
7. [Implementación actual (`infra/`)](#7-implementación-actual-infra)
8. [Registro de decisiones](#8-registro-de-decisiones)
9. [Riesgos conocidos](#9-riesgos-conocidos)
10. [Próximos pasos](#10-próximos-pasos)
11. [Referencias](#11-referencias)

---

## 1. Objetivo

Construir una fábrica de agentes donde cada rol del desarrollo de software lo cumple un
agente especializado:

| Rol | Responsabilidad |
|---|---|
| **Requerimientos** | Convierte el pedido del usuario en historias con criterios de aceptación identificables (`AC-xxx`). |
| **Arquitecto** | Decide stack, infraestructura y diseño técnico, y registra cada decisión como ADR. |
| **Líder de desarrollo** | Une requerimientos y arquitectura en *specs* pequeños y verificables, cada uno con su *Definition of Done* trazable a los AC. |
| **Desarrollador** | Implementa un spec a la vez dentro de un sandbox. |
| **QA** | Verifica que lo implementado cumpla el spec **y** el requerimiento original, con tests ejecutables. |

Restricciones del proyecto:
- Modelos **open-weight** servidos por nosotros (sin depender de APIs de terceros en el flujo normal).
- Partir arrendando GPU para validar y medir, y pasar a hardware propio solo cuando los datos lo justifiquen.

---

## 2. Estado del proyecto

| Área | Estado | Detalle |
|---|---|---|
| Análisis de viabilidad | ✅ Cerrado | [§4](#4-viabilidad-con-modelos-locales) |
| Arquitectura de roles y flujo | ✅ Cerrado | [§3](#3-arquitectura-de-la-fábrica) y whiteboard |
| Dimensionamiento de hardware | ✅ Cerrado | [§5](#5-hardware) |
| Estrategia arriendo → local | ✅ Cerrado | [§6](#6-ruta-de-migración-gpu-arrendada--local) |
| Inferencia Fase 1 (RunPod + vLLM + gateway) | 🟡 Implementado, sin validar en GPU real | [`infra/`](infra/) |
| Benchmark propio (4 tareas verificables) | 🟡 Implementado, sin datos reales | [`infra/bench/`](infra/bench/) |
| Orquestación de agentes (BMAD / Spec Kit) | ⏳ Pendiente | [§10](#10-próximos-pasos) |
| Sandbox de ejecución (OpenHands) | ⏳ Pendiente | |
| CI determinista como *Definition of Done* | ⏳ Pendiente | |
| Fase 2/3 (híbrido / local) | ⏳ Pendiente (scripts listos) | `infra/scripts/use-local.sh` |

El diagrama de arquitectura vive en un whiteboard de Claude (privado del autor):
<https://claude.ai/artifact/56cFdmqj36mjwujiB65oFJ>

---

## 3. Arquitectura de la fábrica

### 3.1 Flujo

```
                     Gate humano                                         Gate humano
                (aprueba req + arquitectura)                         (revisión del merge)
                            │                                                 │
Pedido ──▶ Requerimientos ──▶ Arquitecto ──▶ Líder de desarrollo ──▶ Desarrollador ──▶ QA ──▶ Merge / Done
                                                                         ▲            │
                                                                         └────────────┘
                                                        falla → corrige (máx. 3), luego escala a humano
```

### 3.2 Artefactos: el contrato entre roles

Los agentes **no conversan entre sí**: cada rol lee y escribe archivos versionados en git
y arranca con un contexto limpio que contiene solo lo que necesita. Esto es clave con modelos
locales, que pierden calidad con historiales largos.

| Rol | Produce |
|---|---|
| Requerimientos | `requirements.md` con `AC-001 … AC-n` |
| Arquitecto | `docs/adr/*.md` (stack + infraestructura) |
| Líder de desarrollo | `specs/*.md` con DoD y los AC que cubre |
| Desarrollador | `src/` + PR por spec |
| QA | `tests/` + reporte de CI; cada test referencia su `AC-xxx` |

### 3.3 Principios

- **QA determinista, no de opinión.** El QA escribe tests a partir de los criterios de aceptación *antes* de la implementación; "Done" significa CI en verde (tests, lint, tipos), no un LLM diciendo que se ve bien.
- **Trazabilidad requerimiento → spec → test** por ID de AC, para verificar a la vez el spec y el requerimiento.
- **Specs pequeños** (pocos archivos y criterios claros): es lo que hace viable el rol de desarrollador con modelos locales.
- **Reintentos acotados**: máximo 3 ciclos QA → Dev; después se escala a una persona (o a un modelo en la nube como respaldo).
- **Dos puntos de aprobación humana**: después de requerimientos + arquitectura, y en el merge.
- **Modelo por rol**: uno de razonamiento para Requerimientos, Arquitecto y Líder, y uno de código para Dev y QA.

---

## 4. Viabilidad con modelos locales

**Conclusión:** es viable, pero no como un sistema autónomo de punta a punta. Funciona con
validación automática entre etapas y aprobación humana en los puntos clave.

| Rol | Viabilidad local | Comentario |
|---|---|---|
| Requerimientos | Alta | Redacción estructurada; un modelo de 27–35B lo hace bien. |
| Arquitecto | Media‑alta | Bien con stacks conocidos; flojo en *trade-offs* nuevos → aprobación humana. |
| Líder de desarrollo | Alta | Es el rol que más influye en la calidad del resto. |
| Desarrollador | Media | El punto más débil: requiere specs acotados y el ciclo de QA. |
| QA | Alta (si es determinista) | Escribir y ejecutar tests, linters y verificaciones de tipos. |

Hallazgos que motivaron la arquitectura:

- **Brecha frente a modelos en la nube en tareas agénticas.** En OpenHands, un modelo frontier ronda 72% en SWE-bench, contra ~47% de Devstral Small 2 (24B) local, según reportes de junio de 2026. Modelos más nuevos como Qwen3.6-35B-A3B reportan ~73% en SWE-bench Verified, pero las cifras varían mucho según el entorno de medición.
- **Los frameworks de "empresa simulada" son frágiles en local.** En pruebas de mayo de 2026, solo Cline + Ollama y Continue.dev completaron tareas reales de forma confiable; MetaGPT, LangGraph y OpenInterpreter fallaron cada uno a su manera.
- **El contexto es el cuello de botella.** Los loops agénticos consumen 20K–50K tokens por tarea, y Ollama trunca el contexto sin avisar si no se configura.
- **El prefill pesa más que la velocidad de generación**, porque cada rol relee specs, ADRs y código en cada turno.

Enfoques evaluados:

| Enfoque | Uso en el proyecto |
|---|---|
| **BMAD Method** | Más cercano al diseño (Analyst → PM → Architect → SM → Dev → QA). Candidato para planificación y specs. |
| **GitHub Spec Kit** | Flujo spec-driven (spec → plan → tareas → implementación). Alternativa o complemento a BMAD. |
| **OpenHands** | Ejecutor con sandbox Docker para Dev y QA. |
| **MetaGPT / ChatDev** | Referencia conceptual; frágiles con modelos locales. |
| **LangGraph propio** | Destino final de la orquestación, para controlar puntos de aprobación y reintentos. |

---

## 5. Hardware

| Nivel | Hardware | Qué permite |
|---|---|---|
| 0 — No vale la pena | < 16 GB VRAM | Solo modelos de 7–14B; el rol de Desarrollador falla casi siempre. |
| **1 — Mínimo POC** | 1× GPU 24 GB (RTX 3090/4090) | Flujo completo con un solo modelo y roles secuenciales; contexto 32–64K. |
| **2 — Desarrollo** | 32–48 GB (RTX 5090 o 2× RTX 3090) | Un modelo por rol, más contexto y algo de paralelismo. |
| Memoria unificada | Mac Studio / DGX Spark / Ryzen AI Max (128 GB) | Modelos más grandes, pero loops más lentos por el prefill. |

Referencias de velocidad para Qwen3.6-35B-A3B (MoE, 3B activos, ~21 GB en Q4): ~100 tok/s
en RTX 3090 y ~165 tok/s en RTX 5090 con contexto corto, según reportes de la comunidad.
En equipos con memoria unificada de ~256–273 GB/s el problema es el prefill: un prompt de
20K tokens puede tardar más de 40 s antes de la primera palabra.

**Decisión:** no comprar todavía. Arrendar GPU, medir con el benchmark propio y decidir con datos ([§6](#6-ruta-de-migración-gpu-arrendada--local)).

---

## 6. Ruta de migración: GPU arrendada → local

Los agentes **nunca saben dónde corre el modelo**: piden un nombre lógico (`razonamiento`
o `codigo`) a un gateway. Pasar de la GPU arrendada a la local significa cambiar una
variable de entorno.

```
Agentes  ──▶  Gateway LiteLLM (localhost:4000)  ──▶  Fase 1: vLLM en GPU arrendada (vía Tailscale)
                                                └──▶  Fase 2/3: vLLM en GPU propia
```

| Fase | Qué se hace |
|---|---|
| **1 · GPU arrendada** | vLLM en RunPod. Iterar prompts y flujo; medir VRAM, contexto real, prefill y horas de GPU. |
| **2 · Híbrido** | El mismo compose en una GPU propia. Pasar solo `codigo` a local y comparar con el benchmark. |
| **3 · Local** | Ambos roles en local. Arriendo o nube solo como respaldo para escalamientos de QA. |

**Lo que no cambia entre fases:** mismo runtime (vLLM, mismo modelo, cuantización y parser),
inferencia definida como código, túnel privado sin puertos públicos y el mismo benchmark.

**Qué medir en la Fase 1 para decidir la compra:** VRAM máxima por modelo, contexto real
por rol, tiempo de prefill frente a generación, concurrencia y horas de GPU al mes.

---

## 7. Implementación actual (`infra/`)

Infraestructura de inferencia para la Fase 1, preparada para la Fase 2/3. Guía completa en
[`infra/README.md`](infra/README.md).

```
infra/
├── inference/
│   ├── serve.sh                      # arranca vLLM; el MISMO script en el pod y en local
│   ├── docker-compose.inference.yml  # vLLM local (Fase 2/3)
│   └── profiles/                     # poc-48gb · poc-24gb · dev-2x24gb
├── gateway/                          # LiteLLM con nombres lógicos razonamiento / codigo
├── scripts/
│   ├── runpod-up.sh / runpod-down.sh # crea / termina el pod y apunta el gateway
│   ├── auto-stop.sh                  # corte automático (evita pods olvidados)
│   ├── smoke-test.sh                 # roles + tool calls estructuradas
│   ├── collect-metrics.sh            # KV cache, tokens y VRAM real
│   └── use-local.sh                  # cambia el gateway a vLLM local
└── bench/                            # benchmark propio con resultado verificable
```

### Uso rápido (Fase 1)

```bash
cd infra
cp .env.example .env                 # RUNPOD_API_KEY, NETWORK_VOLUME_ID, TS_AUTHKEY, claves
docker network create fabrica
./scripts/runpod-up.sh inference/profiles/poc-48gb.env
docker compose -f gateway/docker-compose.gateway.yml up -d --force-recreate
./scripts/smoke-test.sh
python3 bench/run_bench.py --label poc-48gb
./scripts/runpod-down.sh
```

### Perfiles de hardware

| Perfil | GPU | Modelo(s) | Propósito |
|---|---|---|---|
| `poc-48gb` | 1× L40S / A6000 / A40 | Qwen3.6-35B-A3B **FP8 oficial**, ambos roles | Validar el flujo con las menores sorpresas. **Empezar aquí.** |
| `poc-24gb` | 1× RTX 4090 / 3090 | Qwen3.6-35B-A3B AWQ 4-bit (comunidad) | Medir si 24 GB alcanzan. |
| `dev-2x24gb` | 2× RTX 4090 / 3090 | Qwen3.6 (razonamiento) + Qwen3-Coder-30B (código), AWQ | Un modelo por GPU. |

### Benchmark propio

| Tarea | Rol | Qué valida |
|---|---|---|
| `tool_call_basico` | Desarrollador | Que la tool call llegue **estructurada** (falla silenciosa sin `--tool-call-parser`). |
| `spec_desde_requerimiento` | Líder de desarrollo | Spec en JSON válido con AC, cambios de BD, endpoints y DoD. |
| `codigo_validar_rut` | Desarrollador + QA | Código Python que pasa tests reales (ejecutado en Docker sin red). |
| `contexto_largo_prefill` | QA | Recuperar un dato en ~20K tokens de ADRs; mide el prefill. |

Cada tarea se repite N veces (por defecto 3) y se guardan éxito, latencia y tokens en `bench/results/`.

### Cómo se probó

Se probó el flujo completo contra un servidor simulado de RunPod, vLLM y el gateway: creación
del pod, payload enviado a la API, resolución de endpoints, espera de salud, generación de
`gateway/.env`, smoke test, benchmark (4/4 tareas), muestreo de métricas, apagado con
registro de horas y cambio a local. **No se ha ejecutado todavía contra RunPod ni con una GPU real.**

---

## 8. Registro de decisiones

| # | Decisión | Motivo |
|---|---|---|
| D-01 | Artefactos versionados en git como contrato entre roles, sin conversación entre agentes | Contexto limpio por rol; los modelos locales se degradan con historiales largos. |
| D-02 | QA basado en tests ejecutables y CI como *Definition of Done* | Una verificación determinista es más confiable que el juicio de un LLM. |
| D-03 | Dos modelos lógicos: `razonamiento` y `codigo` | Especialización por rol sin acoplar los agentes a un modelo concreto. |
| D-04 | Gateway LiteLLM con nombres lógicos | Cambiar entre arriendo, local y nube es solo configuración; además da logs y respaldo. |
| D-05 | vLLM en todas las fases, con versión e imagen fijadas | Evita que cambien el formato de pesos, el parser de tool calls o el contexto al migrar. |
| D-06 | Tailscale en modo userspace como túnel | Los pods no tienen `/dev/net/tun`; vLLM no queda expuesto a internet. |
| D-07 | Empezar con `poc-48gb` (FP8 oficial) antes de 4-bit | Menos variables en la primera validación. |
| D-08 | RunPod Secure Cloud por defecto + network volume para los pesos | El código pasa por la máquina arrendada; no se re-descargan ~35 GB por sesión. |
| D-09 | BMAD / Spec Kit primero; LangGraph propio después | Validar el flujo con herramientas existentes antes de construir un orquestador. |
| D-10 | No comprar hardware hasta tener métricas de la Fase 1 | Decidir entre 24 GB, 48 GB o seguir arrendando con datos reales. |

---

## 9. Riesgos conocidos

- **Calidad del rol Desarrollador** en tareas de varios archivos: se mitiga con specs pequeños y el ciclo de QA.
- **Repos AWQ de la comunidad** (`poc-24gb`, `dev-2x24gb`): verificar en Hugging Face que existan y que funcionen con la versión de vLLM fijada.
- **Tailscale en modo userspace**: si no acepta conexiones entrantes en el pod, usar temporalmente `TUNNEL_MODE=public` (protegido solo por la API key).
- **Privacidad en la Fase 1**: el código y los prompts pasan por infraestructura de un tercero → usar repos de prueba o datos sintéticos.
- **Precios de GPU volátiles**: los scripts registran el costo real por hora que informa RunPod en `metrics/sesiones.csv`.

---

## 10. Próximos pasos

1. **Primera corrida real con `poc-48gb`**: validar flags, fijar la versión de la imagen de vLLM y registrar VRAM y latencias.
2. Correr el benchmark con `poc-24gb` y comparar → decidir si 24 GB alcanzan.
3. Integrar la orquestación: BMAD o Spec Kit apuntando al gateway (`razonamiento` / `codigo`).
4. Conectar OpenHands como sandbox de Dev/QA.
5. Definir el pipeline de CI determinista (tests, lint, tipos) como *Definition of Done*.
6. Ampliar el benchmark a 10–20 tareas reales de la fábrica (incluyendo un CRUD con PostgreSQL como piloto).
7. Con las métricas: decidir la compra de hardware o seguir arrendando.

---

## 11. Referencias

- [MetaGPT](https://github.com/FoundationAgents/MetaGPT) · [ChatDev](https://github.com/OpenBMB/ChatDev) · [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD) · [GitHub Spec Kit](https://github.com/github/spec-kit)
- [OpenHands – Local LLMs](https://docs.openhands.dev/openhands/usage/llms/local-llms)
- [PromptQuorum – Local AI Agents in 2026: What Actually Works](https://www.promptquorum.com/power-local-llm/autonomous-local-agents-actually-work)
- [OpenHands + Ollama in 2026 (DEV)](https://dev.to/jovan_chan_9500711396d4e6/openhands-170-ollama-in-2026-complete-local-setup-the-docker-networking-trap-and-which-mhc)
- [vLLM recipe – Qwen3.6-35B-A3B](https://recipes.vllm.ai/Qwen/Qwen3.6-35B-A3B.md)
- [Qwen models local inference hardware guide 2026](https://vibecodehq.pages.dev/blog/qwen-models-local-inference-hardware-guide-2026)
- [ComputingForGeeks – 128GB local LLM boxes](https://computingforgeeks.com/?p=173981)
- [RunPod API – Create a Pod](https://docs.runpod.io/api-reference/pods/POST/pods)
