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

# 1. Provisiona la máquina (instala gh, claude-code, rtk, graphify, claude-mem,
#    el hook de auditoría de tool-calls…)
./install-factory.sh

# 2. Autentícate
gh auth login
claude login

# 3. Sincroniza toda la flota declarada en repositories.json
./sync-fleet.sh

# 4. Trabaja desde la raíz de la Matriz: UNA sola sesión Claude para toda la
#    flota (no una sesión por repo). .claude/settings.json ya trae los hooks
#    que miden el estado al arrancar y avisan/bloquean en tiempo real — ver
#    "Puertas mecánicas" abajo.
claude
```

> **Cambio de rumbo (2026-08-07):** `deploy-worker.sh` (un worker autónomo
> por repo, `cd` + `exec claude -p`) ya no es como se opera esta Matriz. Se
> deja el script en el repo por si se retoma ese modo más adelante, pero el
> flujo real hoy es una única sesión interactiva en la raíz, viendo toda la
> flota a la vez — el mismo modelo que `neuroon-audit-context`.

## Scripts

| Script | Rol |
|--------|-----|
| `install-factory.sh` | Aprovisiona la máquina Matriz (dependencias globales + hook de auditoría de tool-calls, una sola vez). |
| `sync-fleet.sh` | Clona/actualiza todos los repos declarados en `repositories.json`. |
| `plan-feature.sh <repo>` | Abre una sesión de planificación (Arquitecto/PO) de solo lectura: crea la Issue en GitHub y, si el repo tiene OpenSpec, el change correspondiente. |
| `deploy-worker.sh <repo> [--yes] [--issue <N>]` | ⚠️ **En desuso** (ver arriba) — desplegaba y arrancaba un worker autónomo escopado a un solo repo. Se conserva sin borrar, no se usa en el flujo actual. |
| `init.sh` | Valida la línea base del propio repo Matriz (bash + JSON) y la identidad de Git. |

## Herramientas (`tools/`)

| Script | Rol |
|--------|-----|
| `tools/audit-harness.sh [ruta]` | Audita el cumplimiento del arnés de un repo (PASS/WARN/FAIL por sección S1-S7); detecta el stack (Gradle, Maven, Node/Next, Python, WordPress/PHP). S7 mide el uso real de MCP vs. Bash de los últimos 14 días a partir del log de auditoría. |
| `tools/scaffold-harness.sh --target <dir> [--force] [--default-branch <rama>]` | Genera el esqueleto de arnés que falte en un repo (idempotente, nunca sobreescribe sin `--force`). |
| `tools/scaffold-mcp.sh <repo> --target <dir>` | Sincroniza el `.mcp.json` de un repo target contra `mcp_servers` declarados en `repositories.json`. Reliquia del modelo de un `.mcp.json` por repo (`deploy-worker.sh`); con el `.mcp.json` centralizado en la raíz, ya no hace falta para operar. |
| `tools/sync-graph.sh [ruta]` | (Re)construye el grafo de código (graphify) de un repo en la caché centralizada `workspaces/.graphify-data/<repo>/`, con sello `.built-at-commit`. Idempotente: si el grafo ya corresponde al HEAD actual, no hace nada. |
| `tools/session-brief.sh` | Hook `SessionStart` (también al compactar): mide y reinyecta el estado real de los grafos de toda la flota + la tabla de enrutado tarea→herramienta. |
| `tools/guard-graph-fresh.sh` | Hook `PreToolUse` sobre `mcp__graphify-*`: **deniega** la consulta si el grafo está construido sobre un commit con cambios de código respecto a HEAD. |
| `tools/guard-symbol-search.sh` | Hook `PreToolUse` sobre `Bash`: si el comando busca la declaración de un símbolo con grep/find en vez de serena, **avisa y cuenta** (nunca bloquea) — anota el caso en `~/.claude/audit/symbol-search-misses.log`. |

## Puertas mecánicas (`.claude/settings.json` + `.mcp.json`)

Un `CLAUDE.md` es contexto, no configuración: se cumple casi siempre y falla
justo tras compactar o dentro de un subagente. Lo que debe cumplirse
**siempre** va en un hook, no en prosa — y con un matiz importante: cuando lo
que hay que cumplir es un hecho objetivo y comprobable (un grafo construido
sobre un commit que ya no es HEAD), el hook **deniega**. Cuando es un
criterio de juicio (¿esto era mejor buscarlo con serena o con grep?), el hook
**avisa y cuenta** en vez de bloquear — bloquear ahí no enseña a enrutar,
solo estorba.

- `tools/session-brief.sh` — mide, nunca decide.
- `tools/guard-graph-fresh.sh` — hecho binario → **deny**.
- `tools/guard-symbol-search.sh` — criterio → **warn + log**, nunca deny.
- `tools/audit-harness.sh` (S7) — agrega ese log a lo largo del tiempo, para
  que "¿se está usando el MCP de verdad?" sea un número, no una impresión.

Solo `graphify-api` está declarado hoy en `.mcp.json` (único repo con grafo
bootstrapeado). `serena` no está configurado para ningún repo todavía — los
avisos de `guard-symbol-search.sh` son de cara a cuando se añada.

## Templates y documentación

- `templates/{maker,verifier,worker}-prompt.md` — prompts versionados del patrón Planner→Maker→Verifier, renderizados por `deploy-worker.sh`/`plan-feature.sh` (heredado del modelo en desuso).
- `templates/mcp/*.json` — plantillas de servidores MCP que `scaffold-mcp.sh` inyecta en el `.mcp.json` de un repo target.
- `docs/LOOP-ENGINEERING.md` — diseño del patrón Maker/Verifier y la escalera de madurez L1-L5 para automatización (documento de diseño; nada de esto se activa solo).

## Verdad absoluta

`repositories.json` es la fuente de verdad de qué proyectos componen la plataforma
Neuroon. Todo microservicio, frontend o herramienta nueva DEBE registrarse ahí.
