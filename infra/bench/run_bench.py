#!/usr/bin/env python3
"""
Benchmark propio de la fábrica de agentes.

Corre las tareas de bench/tasks/*.json contra el gateway (http://localhost:4000/v1),
las repite N veces y guarda resultados en bench/results/<label>.csv.

Correlo con el MISMO set de tareas en cada fase (arriendo, híbrido, local) y en
cada perfil de hardware: así comparas manzanas con manzanas.

    python3 bench/run_bench.py --label poc-48gb
    python3 bench/run_bench.py --label poc-24gb --repeticiones 5

Solo usa la biblioteca estándar de Python.
El código generado por el modelo se ejecuta dentro de un contenedor Docker sin red
(--sandbox docker, por defecto). Usa --sandbox local solo si sabes lo que haces.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


# ----------------------------------------------------------------------------- utilidades
def leer_dotenv(path: Path) -> dict[str, str]:
    vals: dict[str, str] = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                vals[k.strip()] = v.strip().strip('"').strip("'")
    return vals


def llamar(gateway: str, key: str, payload: dict, timeout: int = 900) -> tuple[dict, float]:
    req = urllib.request.Request(
        f"{gateway.rstrip('/')}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
        method="POST",
    )
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data, time.perf_counter() - t0


def generar_relleno(tokens_aprox: int, needle: str) -> str:
    """ADRs sintéticos (~25 tokens c/u) con la 'aguja' escondida al ~60%."""
    modulos = ["facturación", "usuarios", "inventario", "reportes", "notificaciones", "auditoría"]
    techs = ["PostgreSQL", "Redis", "RabbitMQ", "FastAPI", "Celery", "MinIO"]
    fines = ["persistencia", "caché", "colas de trabajo", "API pública", "tareas programadas", "archivos"]
    n = max(10, tokens_aprox // 25)
    lineas = [
        f"ADR-{100 + i}: el módulo de {modulos[i % 6]} usa {techs[(i * 5) % 6]} para "
        f"{fines[(i * 7) % 6]}; responsable equipo {chr(65 + i % 8)}; revisión trimestral."
        for i in range(n)
    ]
    lineas.insert(int(n * 0.6), needle)
    return "\n".join(lineas)


def extraer_codigo(texto: str) -> str | None:
    bloques = re.findall(r"```(?:python|py)?\s*\n(.*?)```", texto, flags=re.S)
    return bloques[-1] if bloques else None


def extraer_json(texto: str):
    texto = re.sub(r"^```(?:json)?\s*|\s*```$", "", texto.strip(), flags=re.S)
    ini, fin = texto.find("{"), texto.rfind("}")
    if ini < 0 or fin < 0:
        raise ValueError("no hay objeto JSON")
    return json.loads(texto[ini : fin + 1])


def ejecutar_codigo(codigo: str, test: str, sandbox: str) -> tuple[bool, str]:
    with tempfile.TemporaryDirectory(prefix="bench-") as d:
        archivo = Path(d) / "prueba.py"
        archivo.write_text(codigo + "\n\n# ---- tests ----\n" + test + "\n", encoding="utf-8")
        if sandbox == "docker":
            cmd = ["docker", "run", "--rm", "--network", "none", "--memory", "256m",
                   "-v", f"{d}:/w:ro", "python:3.12-slim", "python", "-I", "/w/prueba.py"]
        else:
            cmd = [sys.executable, "-I", str(archivo)]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return False, "timeout"
        salida = (r.stdout + r.stderr).strip()
        return r.returncode == 0 and "TESTS OK" in r.stdout, salida[-300:]


# ----------------------------------------------------------------------------- evaluación
def evaluar(tarea: dict, resp: dict, sandbox: str) -> tuple[bool, str]:
    msg = resp["choices"][0]["message"]
    contenido = msg.get("content") or ""
    chk = tarea.get("check", {})
    tipo = tarea["tipo"]

    if tipo == "tool_call":
        calls = msg.get("tool_calls") or []
        if not calls:
            return False, "sin tool_calls estructurado"
        fn = calls[0]["function"]
        if fn["name"] != chk["tool"]:
            return False, f"herramienta {fn['name']}"
        try:
            args = json.loads(fn.get("arguments") or "{}")
        except json.JSONDecodeError:
            return False, "argumentos no son JSON"
        for k, sub in chk.get("arg_contains", {}).items():
            if sub not in str(args.get(k, "")):
                return False, f"arg {k}={args.get(k)!r}"
        return True, json.dumps(args, ensure_ascii=False)

    if tipo == "json":
        try:
            obj = extraer_json(contenido)
        except (ValueError, json.JSONDecodeError) as e:
            return False, f"JSON inválido: {e}"
        faltan = [k for k in chk.get("json_keys", []) if k not in obj]
        if faltan:
            return False, f"faltan claves {faltan}"
        for k, n in chk.get("min_items", {}).items():
            if len(obj.get(k) or []) < n:
                return False, f"{k} tiene menos de {n} elementos"
        return True, "ok"

    if tipo == "code":
        codigo = extraer_codigo(contenido)
        if not codigo:
            return False, "sin bloque ```python```"
        return ejecutar_codigo(codigo, chk["test"], sandbox)

    if tipo == "needle":
        ok = chk["contains"] in contenido
        return ok, contenido.strip()[:80]

    return False, f"tipo desconocido {tipo}"


def construir_payload(tarea: dict) -> dict:
    if tarea["tipo"] == "needle":
        contexto = generar_relleno(tarea.get("filler_tokens", 20000), tarea["needle"])
        messages = [
            {"role": "system", "content": "Eres el agente QA. Respondes con precisión usando solo el contexto."},
            {"role": "user", "content": f"Registro de decisiones de arquitectura:\n\n{contexto}\n\n{tarea['question']}"},
        ]
    else:
        messages = tarea["messages"]
    payload = {"model": tarea["model"], "messages": messages, "max_tokens": tarea.get("max_tokens", 2048)}
    if tarea.get("tools"):
        payload["tools"] = tarea["tools"]
        payload["tool_choice"] = "auto"
    return payload


# ----------------------------------------------------------------------------- main
def main() -> int:
    env = {**leer_dotenv(ROOT / ".env"), **os.environ}
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--label", required=True, help="nombre de la corrida, p. ej. poc-48gb o local-3090")
    ap.add_argument("--gateway", default=env.get("GATEWAY_URL", "http://localhost:4000/v1"))
    ap.add_argument("--tareas", default=str(ROOT / "bench" / "tasks"))
    ap.add_argument("--repeticiones", type=int, default=3, help="los modelos locales varían: repite cada tarea")
    ap.add_argument("--sandbox", choices=["docker", "local"], default="docker")
    args = ap.parse_args()

    key = env.get("LITELLM_MASTER_KEY")
    if not key:
        print("Falta LITELLM_MASTER_KEY (en .env o variable de entorno)", file=sys.stderr)
        return 2
    if args.sandbox == "docker" and not shutil.which("docker"):
        print("Docker no está disponible; instala Docker o usa --sandbox local bajo tu propio riesgo.", file=sys.stderr)
        return 2

    tareas = [json.loads(p.read_text(encoding="utf-8")) for p in sorted(Path(args.tareas).glob("*.json"))]
    if not tareas:
        print(f"No hay tareas en {args.tareas}", file=sys.stderr)
        return 2

    out_dir = ROOT / "bench" / "results"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{args.label}-{datetime.now():%Y%m%d-%H%M}.csv"
    campos = ["timestamp", "label", "tarea", "rol", "modelo", "rep", "ok", "latencia_s",
              "prompt_tokens", "completion_tokens", "tok_s_salida_aprox", "detalle"]

    resumen: dict[str, list] = {}
    with out.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=campos)
        w.writeheader()
        for t in tareas:
            for rep in range(1, args.repeticiones + 1):
                fila = {"timestamp": datetime.now().isoformat(timespec="seconds"), "label": args.label,
                        "tarea": t["id"], "rol": t.get("rol", ""), "modelo": t["model"], "rep": rep}
                try:
                    resp, lat = llamar(args.gateway, key, construir_payload(t))
                    ok, det = evaluar(t, resp, args.sandbox)
                    u = resp.get("usage") or {}
                    ct = u.get("completion_tokens") or 0
                    fila.update(ok=ok, latencia_s=round(lat, 2), prompt_tokens=u.get("prompt_tokens"),
                                completion_tokens=ct, tok_s_salida_aprox=round(ct / lat, 1) if lat else "",
                                detalle=det)
                except (urllib.error.URLError, TimeoutError, KeyError, json.JSONDecodeError) as e:
                    fila.update(ok=False, latencia_s="", detalle=f"error: {e}")
                w.writerow(fila)
                f.flush()
                resumen.setdefault(t["id"], []).append(fila)
                marca = "✔" if fila["ok"] else "✘"
                print(f"{marca} {t['id']:<28} rep {rep}  {fila.get('latencia_s', '')!s:>7}s  {str(fila['detalle'])[:70]}")

    print(f"\nResumen ({args.label}):")
    print(f"{'tarea':<28} {'éxito':>7} {'latencia prom.':>15}")
    for tid, filas in resumen.items():
        oks = sum(1 for r in filas if r["ok"])
        lats = [r["latencia_s"] for r in filas if isinstance(r.get("latencia_s"), float)]
        prom = f"{sum(lats) / len(lats):.1f}s" if lats else "-"
        print(f"{tid:<28} {oks}/{len(filas):<5} {prom:>15}")
    print(f"\nResultados en {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
