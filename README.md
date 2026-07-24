# neuroon-ai-context

Matriz de infraestructura y configuración global para la flota de agentes IA de la
**plataforma Neuroon**.

Este repositorio es el **plano de control (control plane)** que permite convertir
cualquier VPS, portátil u ordenador en un **worker** capaz de operar los
repositorios de la plataforma siguiendo Harness Engineering.

## Puesta en marcha (nueva máquina)

```bash
git clone https://github.com/Neuroon-ai/neuroon-ai-context.git
cd neuroon-ai-context

# 1. Provisiona la máquina (instala gh, claude-code, rtk, graphify, claude-mem…)
./install-factory.sh

# 2. Autentícate
gh auth login
claude login

# 3. Sincroniza toda la flota declarada en repositories.json
./sync-fleet.sh

# 4. Planifica una feature (crea la Issue + el change de OpenSpec)
./plan-feature.sh api-search-neuroon

# 5. Despliega y ARRANCA el worker directamente sobre un repositorio
#    (autónomo: sin confirmación y/N, solo se frena si el arnés audita en rojo)
./deploy-worker.sh api-search-neuroon
# ...o atado a una Issue concreta ya planificada:
./deploy-worker.sh api-search-neuroon --issue 292
```

## Scripts

| Script | Rol |
|--------|-----|
| `install-factory.sh` | Aprovisiona la máquina Matriz (dependencias globales, una sola vez). |
| `sync-fleet.sh` | Clona/actualiza todos los repos declarados en `repositories.json`. |
| `deploy-worker.sh <repo> [--yes] [--issue <N>]` | Despliega un repo (arnés, grafo, MCP) y **arranca el worker directamente** (`exec claude -p ...`), sin pedir confirmación — autónomo. Solo no lanza si el arnés audita con CRITICAL en rojo (en ese caso imprime el comando para lanzarlo a mano tras revisar). Con `--issue <N>`, el worker queda asignado explícitamente a esa Issue en vez de elegir una él solo. |
| `plan-feature.sh <repo>` | Abre una sesión de planificación (Arquitecto/PO) de solo lectura: crea la Issue en GitHub y, si el repo tiene OpenSpec, el change correspondiente. |
| `init.sh` | Valida la línea base del propio repo Matriz (bash + JSON) y la identidad de Git. |

## Herramientas (`tools/`)

Scripts de soporte que `deploy-worker.sh` invoca automáticamente, pero también se pueden correr sueltos:

| Script | Rol |
|--------|-----|
| `tools/audit-harness.sh [ruta]` | Audita el cumplimiento del arnés de un repo (PASS/WARN/FAIL por sección); detecta el stack (Gradle, Maven, Node/Next, Python, WordPress/PHP). |
| `tools/scaffold-harness.sh --target <dir> [--force] [--default-branch <rama>]` | Genera el esqueleto de arnés que falte en un repo (idempotente, nunca sobreescribe sin `--force`). |
| `tools/scaffold-mcp.sh <repo> --target <dir>` | Sincroniza `.mcp.json` del repo target contra `mcp_servers` declarados en `repositories.json`. |
| `tools/sync-graph.sh [ruta]` | Bootstrap del grafo de código (graphify): primer `extract` + hooks de auto-actualización. |

## Templates y documentación

- `templates/{maker,verifier,worker}-prompt.md` — prompts versionados del patrón Planner→Maker→Verifier, renderizados por `deploy-worker.sh`/`plan-feature.sh`.
- `templates/mcp/*.json` — plantillas de servidores MCP que `scaffold-mcp.sh` inyecta en `.mcp.json`.
- `docs/LOOP-ENGINEERING.md` — diseño del patrón Maker/Verifier y la escalera de madurez L1-L5 para automatización (documento de diseño; nada de esto se activa solo).

## Verdad absoluta

`repositories.json` es la fuente de verdad de qué proyectos componen la plataforma
Neuroon. Todo microservicio, frontend o herramienta nueva DEBE registrarse ahí.
