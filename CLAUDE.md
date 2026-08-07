# Neuroon AI Context — Fleet Management & DevOps

Estás en el repositorio **Matriz** (`neuroon-ai-context`). Este repositorio NO contiene código de negocio (ni Java, ni React). Es el centro de control de la infraestructura y gestión de agentes de IA de Neuroon.

---

## Patrón Operativo (Harness Engineering - DevOps)

1. **Tu rol:** Eres un Agente DevOps/SRE experto en bash, automatización y gestión del entorno de Claude Code.
2. **Read Before Write:** Nunca edites un script sin leerlo antes.
3. **Validación:** Tras modificar cualquier archivo, debes ejecutar `./init.sh` para comprobar que la sintaxis de bash (ShellCheck) y JSON (jq) es correcta, y que la identidad de Git de la máquina está configurada.

## Gestión de la Flota (Fleet Management)

Los proyectos que conforman la plataforma Neuroon están declarados como la "Verdad Absoluta" en el archivo `repositories.json`.
- Si se añade un nuevo microservicio o frontend a la empresa, DEBE registrarse en `repositories.json`.
- `./sync-fleet.sh` es el único script que toca la flota entera, y hace 3 cosas por cada proyecto declarado (nunca solo la primera):
  1. Clona el repo en `./workspaces` si falta, o hace `pull` de su `default_branch` si ya existe.
  2. Da de alta su proyecto de **serena** (lenguaje según el `framework` declarado).
  3. Bootstrapea/refresca su **grafo** (`graphify`) si el repo lo declara en `mcp_servers`.

## Modelo operativo: una sesión, toda la flota + las tools por delante de bash

Se trabaja con **una sola sesión Claude en esta raíz**, viendo todos los repos de `workspaces/` a la vez — no un worker por repo (`deploy-worker.sh` quedó en desuso el 2026-08-07, ver `README.md`). Por eso `.mcp.json` en esta raíz declara un servidor **por repo, con sufijo** (`api`, `app`, `widget`, `docs`, `wp`, `engine`):

- `mcp__graphify-<sufijo>__*` — forma del repo, comunidades, radio de impacto de un símbolo. Vive en una caché centralizada fuera de cada repo (`workspaces/.graphify-data/<repo>/`, `tools/sync-graph.sh`) para no ensuciar cada PR con el diff del grafo.
- `mcp__serena-<sufijo>__*` — LSP real por lenguaje (`find_symbol`, `find_referencing_symbols`, `rename_symbol`): para localizar una declaración o ver sus usos, esto gana a grep porque lee el árbol sintáctico, no adivina por texto.
- `grep`/`rg` sigue siendo lo correcto para texto literal o contar ocurrencias — el arnés no penaliza eso, solo el patrón contrario (usar grep para lo que el MCP resuelve mejor).

**Límite fijo de graphify, no una preferencia de estilo:** no ve la inyección por constructor (muy usada en `api-search-neuroon`) — un `get_neighbors` puede devolver 1 referenciador donde grep encuentra 20 ficheros reales. El grafo sirve para forma/comunidades/radio de impacto; para **contar o localizar llamadores con precisión**, `find_referencing_symbols` de serena o grep, nunca el grafo a ciegas. Esto no cambia con el estado de la flota, así que no hace falta esperar a `session-brief.sh` para saberlo.

La tabla completa tarea→herramienta, con el estado real de qué MCP existe para qué repo hoy, la inyecta `tools/session-brief.sh` al arrancar la sesión (y al compactar) — no se repite aquí porque esa parte sí cambia; esa tabla se mide, no se redacta a mano. Si quieres comprobar el uso real sin esperar a una auditoría, los logs viven en `~/.claude/audit/tool-calls.jsonl` (todas las tool-calls) y `~/.claude/audit/symbol-search-misses.log` (avisos de `guard-symbol-search.sh`).

### Puertas mecánicas, no prosa

Un `CLAUDE.md` es contexto, no configuración: sobrevive mal a una compactación o a un subagente. Lo que debe cumplirse siempre está en `.claude/settings.json`, no aquí — y el arnés distingue dos tipos de puerta según lo que vigila:

- `tools/session-brief.sh` (`SessionStart`, también al compactar) — mide el estado real de la flota (grafos, MCP disponibles) y lo reinyecta.
- `tools/guard-graph-fresh.sh` (`PreToolUse` sobre `mcp__graphify-*`) — hecho binario y comprobable (grafo construido sobre un commit que ya no es HEAD) → **deniega**. Un grafo rancio miente en silencio; no hay criterio que valga, se bloquea.
- `tools/guard-symbol-search.sh` (`PreToolUse` sobre `Bash`) — criterio de enrutado (¿esto se buscaba mejor con serena?), no una obligación objetiva → **avisa y cuenta**, nunca bloquea. Bloquear ahí no enseña a enrutar, solo estorba.
- `tools/audit-harness.sh` (check S7) — agrega ese conteo a lo largo de las sesiones, para que "¿se usa el MCP de verdad?" sea un número medido, no una impresión.

Regla general: **hecho objetivo y comprobable → deny. Criterio de juicio → warn + log.** Si añades una puerta nueva, decide primero en cuál de las dos categorías cae — no hay una tercera opción cómoda.

## Memoria Persistente entre Sesiones (Claude-Mem)

Esta máquina Matriz instala `claude-mem` a nivel global (transversal a la sesión de la Matriz y a todos los repositorios de la flota).
- Captura automáticamente cada herramienta usada durante una sesión, genera resúmenes semánticos y los inyecta en la siguiente sesión de ese mismo repo/proyecto.
- No sustituye a `claude-progress.md` ni a `feature_list.json` (que siguen siendo la fuente de verdad estructurada del arnés). Es una capa complementaria de continuidad conversacional (decisiones, errores repetidos, contexto informal).
- No requiere configuración por proyecto: se instala una única vez en la máquina con `./install-factory.sh`.

## Reglas Estrictas de Scripts
1. **Idempotencia:** Todo script Bash (`.sh`) debe ser seguro para ejecutarse múltiples veces. Si instala un paquete, debe verificar primero si ya está instalado. Si clona un repo, debe verificar si el directorio ya existe.
2. **Cero Secretos:** NUNCA introduzcas tokens de GitHub, URLs privadas o API Keys en los scripts. Si el script necesita secretos, debe leerlos del entorno (`$ENV_VAR`).
3. **Manejo de Errores:** Todos los scripts deben empezar con `set -euo pipefail` para fallar rápidamente si un comando intermedio falla o si se usa una variable no definida.
4. **Rama por defecto:** Cada proyecto declara su propia rama por defecto en el campo `default_branch` de `repositories.json` — NO asumas que toda la flota usa `main` (ej. `api-search-neuroon` usa `develop`). `sync-fleet.sh` lee ese campo por proyecto y nunca hace `pull` sobre una rama de trabajo distinta a la declarada, para no pisar trabajo en curso (`deploy-worker.sh` hacía lo mismo, pero está en desuso — ver README.md).

## Convenciones de la plataforma

- Backend de búsqueda (`api-search-neuroon`): Java + Spring Boot, Maven (`mvnw`).
- Backend del motor (`api-search-engine`): Python.
- Frontends (`app-search-neuroon`, `app-search-widget-neuroon`, `docs-search-widget-neuroon`): TypeScript/Node.js (Next.js, Vite, Docusaurus).
- Plugin (`wordpress-plugin-neuroon-search`): WordPress/PHP.
- La máquina que corre la sesión de la Matriz necesita por tanto: `java` (JDK), `mvn`/`mvnw`, `node`/`npm`, `python3`, `docker`, `gh`, `jq` — todo lo instala/verifica `./install-factory.sh`.
