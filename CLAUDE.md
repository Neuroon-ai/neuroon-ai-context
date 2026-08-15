# Neuroon AI Context — Fleet Management & DevOps

Estás en el repositorio **Matriz** (`neuroon-ai-context`). Este repositorio NO contiene código de negocio (ni Java, ni React). Es el centro de control de la infraestructura y gestión de agentes de IA de Neuroon.

---

## Patrón Operativo (Harness Engineering - DevOps)

1. **Tu rol:** Eres un Agente DevOps/SRE experto en bash, automatización y gestión del entorno de Claude Code.
2. **Read Before Write:** Nunca edites un script sin leerlo antes.
3. **Validación:** Tras modificar cualquier archivo, debes ejecutar `./init.sh` para comprobar que la sintaxis de bash (ShellCheck) y la de todos los JSON versionados (`repositories.json`, `.mcp.json`, `.claude/settings.json`, `tools/gcloud-mcp-allow.json`) es correcta, y que la identidad de Git de la máquina está configurada. `./init.sh` valida SIEMPRE el árbol donde vive, no el cwd, y sale con **2** si alguna comprobación no se pudo ejecutar por falta de herramientas: eso es una incógnita, no un verde.

## Gestión de la Flota (Fleet Management)

Los proyectos que conforman la plataforma Neuroon están declarados como la "Verdad Absoluta" en el archivo `repositories.json`.
- Si se añade un nuevo microservicio o frontend a la empresa, DEBE registrarse en `repositories.json`.
- `./sync-fleet.sh` es el único script que toca la flota entera, y hace 3 cosas por cada proyecto declarado (nunca solo la primera):
  1. Clona el repo en `./workspaces` si falta, o hace `pull` de su `default_branch` si ya existe.
  2. Da de alta su proyecto de **serena** (lenguaje según el `framework` declarado).
  3. Bootstrapea/refresca su **grafo** (`graphify`) si el repo lo declara en `mcp_servers`.

## Modelo operativo: una sesión, toda la flota + las tools por delante de bash

Se trabaja con **una sola sesión Claude en esta raíz**, viendo todos los repos de `workspaces/` a la vez — no un worker por repo (`deploy-worker.sh` quedó en desuso el 2026-08-07, ver `README.md`). Por eso `.mcp.json` en esta raíz declara un servidor **por repo, con sufijo** (`api`, `app`, `widget`, `docs`, `wp`, `engine`, `cdp`), más un `serena` **sin sufijo** que apunta al código de la propia Matriz (los scripts de este repo):

- `mcp__graphify-<sufijo>__*` — forma del repo, comunidades, radio de impacto de un símbolo. Vive en una caché centralizada fuera de cada repo (`workspaces/.graphify-data/<repo>/`, `tools/sync-graph.sh`) para no ensuciar cada PR con el diff del grafo.
- `mcp__serena-<sufijo>__*` — LSP real por lenguaje (`find_symbol`, `find_referencing_symbols`, `rename_symbol`): para localizar una declaración o ver sus usos, esto gana a grep porque lee el árbol sintáctico, no adivina por texto. **La primera llamada a un repo tarda** (arranque del language server — en `neuroon-audit-context` se mide ~100 s la primera vez, ~10-20 s después; no medido todavía en esta flota, pero es el mismo `serena` y el mismo mecanismo): no lo des por colgado. Sus `write_memory`/`read_memory` son memoria **por proyecto de serena**, un mecanismo distinto de Claude-Mem (ver más abajo) — no lo confundas con la memoria conversacional de la sesión.
- `grep`/`rg` sigue siendo lo correcto para texto literal o contar ocurrencias — el arnés no penaliza eso, solo el patrón contrario (usar grep para lo que el MCP resuelve mejor).
### MCPs de infraestructura (la plataforma vive en Coolify sobre Hetzner)

Decisión cerrada (2026-08-11): la infraestructura se gestiona **por MCP con tokens de mínimo privilegio, nunca por CLI ni SSH a pelo, ni por conectores de claude.ai** (se re-autorizan solos cuando quieren; un bearer propio no). Los servidores viven en `.mcp.json` y cada uno **carga su token del `.env` por sí mismo al arrancar** (wrapper `sh -c`; plantilla en `.env.example`, que SÍ se versiona porque es documentación — el `.env` real es el gitignorado; valores SIEMPRE entre comillas simples — los tokens de Coolify llevan `|` y sin comillas el shell los ejecuta). El `.env` se carga por ruta absoluta desde el worktree principal, así que sigue funcionando aunque la sesión arranque en un `git worktree` secundario. La excepción es `gcloud`, que no tiene token: usa las credenciales de la máquina. Cuántos hay y cuáles están vivos no se redacta aquí: lo mide `tools/session-brief.sh` en cada arranque:

- `mcp__coolify__*` — el MCP **oficial integrado en Coolify** (`colify.neuroon.ai/mcp`): visibilidad de apps/deploys/servidores. Solo lectura por diseño y nunca devuelve secretos — misma filosofía que "la BD de PRO es solo lectura". Requiere `COOLIFY_MCP_TOKEN` (permiso `read` únicamente, nunca el token de deploy de cloudbuild), instancia ≥4.1 y el toggle MCP activo (Settings → Advanced). Si sus tools no aparecen, comprueba esas tres cosas antes de concluir que está roto.
- `mcp__coolify-ops__*` — StuMason/coolify-mcp (comunidad, ~44 tools): **operar** la plataforma — restart, redeploy, logs, envs. El límite de daño lo pone el token (`COOLIFY_ACCESS_TOKEN`, separado del anterior): nace `read` y solo se sube a deploy/write por decisión del humano. Desde v4.1 Coolify audita todo lo hecho por API en su propio audit log.
- `mcp__hetzner__*` — lazyants/hetzner-mcp-server (comunidad): la máquina en sí — **snapshot antes de cada update de Coolify**, reboot, firewall. `HETZNER_API_TOKEN` read-only de la consola Cloud; en Hetzner el scope del token lo hace cumplir el servidor, no el MCP. Solo vale si la máquina es Hetzner Cloud (no Robot/dedicado).
- `mcp__stripe__*` — el MCP **oficial hosted de Stripe** (`mcp.stripe.com`) vía puente mcp-remote con **restricted key** en bearer (`STRIPE_RESTRICTED_KEY`, permisos read creados en el dashboard) — sin OAuth ni conector de claude.ai a propósito: los conectores se re-autorizan solos cuando quieren y el bearer no. El propio server capa las tools a los permisos de la key. Requiere el acceso MCP habilitado en dashboard.stripe.com/settings/mcp (separado live/sandbox).
- `mcp__gcloud__*` — **@google-cloud/gcloud-mcp** (repo googleapis, stdio local): el eslabón de Google Cloud del pipeline de deploys (merge → **Cloud Build** → webhook de Coolify). Sin token propio: usa las credenciales gcloud ya autenticadas de la máquina, y el límite lo pone la **allowlist versionada** en `tools/gcloud-mcp-allow.json` (solo `builds` y `artifacts` — su denylist de comandos peligrosos aplica siempre y no es anulable). Se eligió sobre el server remoto gestionado de Google (cloudcli.googleapis.com) porque aquel exige un bearer que caduca cada hora.
- **SSH al servidor = break-glass**, no gestión: solo si el SO está roto y ningún MCP llega, avisando antes al humano. No hay clave configurada a propósito.

`tools/session-brief.sh` mide en cada arranque qué servidores están declarados y qué tokens hay presentes (nunca su valor), para que cada sesión sepa qué tiene disponible sin adivinarlo.

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
4. **Dos raíces, no una.** Todo script que toque `workspaces/` o `.env` debe distinguirlas, y ninguna de las dos se puede deducir del `cwd`:
   - `MATRIX_ROOT` = raíz de **código/config versionada** (`repositories.json`, `tools/`, `.mcp.json`). Se ancla en `$0` — así un PR que edita config es testeable en su propio worktree.
   - `FLEET_ROOT` = raíz de **datos NO versionados** (`workspaces/`, `.graphify-data/`, `.env`, `.serena/`). Es SIEMPRE el worktree principal, que se obtiene con `git worktree list --porcelain | sed -n '1s/^worktree //p'` (la primera línea es el principal, en ruta absoluta), validando el candidato y cayendo a `MATRIX_ROOT` si no hay git.

   Por qué importa: `workspaces/` está gitignorado y **no viaja a un `git worktree` secundario**. Anclar los datos en `$0` hacía que el arnés midiera un árbol vacío y afirmara en positivo cosas falsas ("los 6 repos NO están clonados", "los 4 tokens están VACÍOS"), que `sync-fleet.sh` clonara la flota entera por segunda vez dentro del worktree, y que la única puerta `deny` del arnés se desactivara sola. Si escribes un script nuevo que lea datos de la flota, copia el bloque `FLEET_ROOT` de `tools/sync-graph.sh`.
5. **Rama por defecto:** Cada proyecto declara su propia rama por defecto en el campo `default_branch` de `repositories.json` — NO asumas que toda la flota usa `main` (ej. `api-search-neuroon` usa `develop`). `sync-fleet.sh` lee ese campo por proyecto y nunca hace `pull` sobre una rama de trabajo distinta a la declarada, para no pisar trabajo en curso (`deploy-worker.sh` hacía lo mismo, pero está en desuso — ver README.md).

## Convenciones de la plataforma

- Backend de búsqueda (`api-search-neuroon`): Java + Spring Boot, Maven (`mvnw`).
- Backend del CDP (`neuroon-customer-api`, sufijo `cdp`): Java + Spring Boot, Maven (`mvnw`) — mismo stack y mismas leyes que el monolito (hereda su `CLAUDE.md` y `docs/ENGINEERING_RULES.md`); rama por defecto `develop`.
- Backend del motor (`api-search-engine`): Python.
- Frontends (`app-search-neuroon`, `app-search-widget-neuroon`, `docs-search-widget-neuroon`): TypeScript/Node.js (Next.js, Vite, Docusaurus).
- Plugin (`wordpress-plugin-neuroon-search`): WordPress/PHP.
- La máquina que corre la sesión de la Matriz necesita por tanto: `java` (JDK), `node`/`npm`, `python3`, `docker`, `gh`, `jq` — eso es lo que instala o verifica `./install-factory.sh`. Maven NO se instala ni se comprueba: cada repo Java trae su propio `./mvnw`.
