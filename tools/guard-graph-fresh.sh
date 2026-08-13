#!/bin/bash
# tools/guard-graph-fresh.sh — hook PreToolUse sobre mcp__graphify-*.
#
# Por qué existe: un grafo rancio no se delata. `graph_stats` no devuelve ni
# el commit ni la fecha con que se construyó, así que una sesión puede
# razonar durante horas sobre una foto vieja del código y no enterarse. Eso
# no es un consejo que se pueda dejar en prosa: es un hecho binario y
# comprobable, así que se comprueba y se bloquea.
#
# Qué NO hace: bloquear por bloquear. Si el desfase no toca código (commits
# de documentación, por ejemplo), el grafo sigue sirviendo y se deja pasar.
#
# Regla de esta puerta: cuando el hecho vigilado NO SE PUEDE MEDIR (no está
# el clon, no hay grafo, no se lee el HEAD, el sello es huérfano, el diff
# falla), se DENIEGA. "No pude medir" es una incógnita, y una incógnita no es
# verde — que es justo lo contrario de lo que hacía antes: cada uno de esos
# casos caía en un `permitir` silencioso, y la única puerta dura del arnés se
# desactivaba sola en el momento en que más falta hacía.
set -uo pipefail

MATRIX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Raíz de DATOS (workspaces/), distinta de la raíz de CÓDIGO. Sin esto, desde
# un git worktree secundario (donde workspaces/ está gitignorado y no existe)
# el guard no encontraba ningún clon y PERMITÍA todo en silencio.
FLEET_ROOT="$MATRIX_ROOT"
if command -v git >/dev/null 2>&1; then
  _main_wt="$( { git -C "$MATRIX_ROOT" worktree list --porcelain 2>/dev/null || true; } \
               | sed -n '1s/^worktree //p' )"
  if [ -n "$_main_wt" ] && [ -d "$_main_wt" ] && [ -f "$_main_wt/repositories.json" ]; then
    FLEET_ROOT="$_main_wt"
  fi
  unset _main_wt
fi

permitir() { printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'; exit 0; }

# Sin python3 a propósito: los mensajes de abajo no llevan comillas dobles ni
# barras invertidas, así que printf produce JSON válido. Antes toda la puerta
# dependía de python3, y sin él el nombre de la tool quedaba vacío, caía en
# el default del case y emitía un allow EXPLÍCITO para cualquier consulta al
# grafo. Un intérprete ausente no puede ser la llave que abre la puerta.
denegar() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

ENTRADA="$(cat 2>/dev/null || echo '{}')"

# Extraer tool_name: jq si está (parsea JSON de verdad y coge la clave de
# nivel superior), y si no, awk quedándose con la PRIMERA aparición.
#
# Lo que NO vale es un `sed 's/.*"tool_name"...'`: el `.*` inicial es goloso y
# se queda con la ÚLTIMA aparición del payload. Como `tool_input` viene
# DESPUÉS de `tool_name`, bastaba con una llamada cuyo input llevara una clave
# "tool_name" anidada para que el guard leyera esa, no reconociera el
# servidor, cayera en `*) permitir` y dejara pasar un grafo rancio. Un parser
# de JSON hecho con una regex golosa era, él mismo, un fallo en abierto.
TOOL=""
if command -v jq >/dev/null 2>&1; then
  TOOL="$(printf '%s' "$ENTRADA" | jq -r '.tool_name // empty' 2>/dev/null || true)"
fi
if [ -z "$TOOL" ]; then
  TOOL="$(printf '%s' "$ENTRADA" | tr -d '\n' \
    | awk -F'"tool_name"[[:space:]]*:[[:space:]]*"' 'NF>1{print $2; exit}' \
    | sed 's/".*//')"
fi
[ -n "$TOOL" ] || denegar "guard-graph-fresh no pudo leer el nombre de la tool del payload del hook, asi que no puede comprobar la frescura del grafo. No medir no es verde: arregla el arnes o reconstruye con ./tools/sync-graph.sh."

# Sufijo → repo, mismo mapeo que tools/guard-symbol-search.sh y
# tools/session-brief.sh. Los 6 servidores graphify-* están declarados en
# .mcp.json (ver repositories.json → mcp_servers); "status" (Upptime) queda
# fuera por no tener código propio.
case "$TOOL" in
  mcp__graphify-api__*)    REPO="api-search-neuroon" ;;
  mcp__graphify-app__*)    REPO="app-search-neuroon" ;;
  mcp__graphify-widget__*) REPO="app-search-widget-neuroon" ;;
  mcp__graphify-docs__*)   REPO="docs-search-widget-neuroon" ;;
  mcp__graphify-wp__*)     REPO="wordpress-plugin-neuroon-search" ;;
  mcp__graphify-engine__*) REPO="api-search-engine" ;;
  # Un graphify-* que este case no conozca es un repo nuevo sin vigilancia:
  # antes caía en el default y su grafo quedaba fuera de la puerta sin que
  # nada lo dijera.
  mcp__graphify-*) denegar "guard-graph-fresh no reconoce el servidor de esta llamada ($TOOL): no se que repo mirar, asi que no puedo comprobar la frescura de su grafo. No medir no es verde: anade el sufijo al case de tools/guard-graph-fresh.sh." ;;
  *) permitir ;;
esac

RUTA="$FLEET_ROOT/workspaces/$REPO"
SELLO_FILE="$FLEET_ROOT/workspaces/.graphify-data/$REPO/graphify-out/.built-at-commit"
GRAPH_FILE="$FLEET_ROOT/workspaces/.graphify-data/$REPO/graphify-out/graph.json"

# -e y no -d: en un git worktree, .git es un FICHERO, no un directorio.
[ -e "$RUTA/.git" ] || denegar "No encuentro el clon de $REPO en $RUTA, asi que no hay HEAD contra el que comparar el grafo. No medir no es verde: corre ./sync-fleet.sh desde la raiz principal de la Matriz."

# El guard nunca comprobó que el grafo EXISTA, solo su sello. Y graphify-mcp
# arranca igual sin grafo y devuelve el error con isError=false (medido), así
# que este es el único punto donde una ausencia se puede ver.
[ -f "$GRAPH_FILE" ] || denegar "No existe el grafo de $REPO ($GRAPH_FILE). Construyelo: ./tools/sync-graph.sh workspaces/$REPO"

HEAD_ACTUAL="$(git -C "$RUTA" rev-parse HEAD 2>/dev/null || echo "")"
[ -n "$HEAD_ACTUAL" ] || denegar "No se puede leer el HEAD de $REPO ($RUTA), asi que no hay con que comparar el sello del grafo. No medir no es verde: comprueba el clon y reconstruye con ./tools/sync-graph.sh workspaces/$REPO"

if [ ! -f "$SELLO_FILE" ]; then
  denegar "El grafo de $REPO no tiene sello de construccion, asi que no se puede saber a que commit corresponde y no medir no es verde. Construyelo con: ./tools/sync-graph.sh workspaces/$REPO"
fi

SELLO="$(cat "$SELLO_FILE" 2>/dev/null || echo "")"
[ "$SELLO" = "$HEAD_ACTUAL" ] && permitir

git -C "$RUTA" cat-file -e "${SELLO}^{commit}" 2>/dev/null || \
  denegar "El grafo de $REPO se construyo sobre el commit ${SELLO:0:7}, que ya no existe en este clon (rebase o fuerza). Reconstruyelo: ./tools/sync-graph.sh workspaces/$REPO"

# Extensiones de código de esta flota: Java (api-search-neuroon), Python
# (api-search-engine), PHP (wordpress-plugin-neuroon-search) y TS/JS (los
# tres frontends: app-search-neuroon, app-search-widget-neuroon,
# docs-search-widget-neuroon). Ningún repo usa Kotlin.
#
# El rc del pipeline SÍ se comprueba: `git diff | wc -l` devuelve 0 cuando el
# diff falla, y 0 significaba "sin cambios de código" -> permitir. Un fallo
# de medición no puede parecerse a una medición tranquilizadora.
if ! CODIGO="$(git -C "$RUTA" diff --name-only "$SELLO" "$HEAD_ACTUAL" -- '*.java' '*.py' '*.php' '*.ts' '*.tsx' '*.js' '*.jsx' 2>/dev/null | wc -l | tr -d ' ')"; then
  denegar "No se pudo comparar el sello ${SELLO:0:7} contra HEAD en $REPO: la frescura del grafo es una incognita, y no medir no es verde. Reconstruye: ./tools/sync-graph.sh workspaces/$REPO"
fi
DESFASE="$(git -C "$RUTA" rev-list --count "$SELLO".."$HEAD_ACTUAL" 2>/dev/null || echo "?")"

if [ "${CODIGO:-0}" -gt 0 ]; then
  denegar "El grafo de $REPO esta construido sobre ${SELLO:0:7} y HEAD es ${HEAD_ACTUAL:0:7}: $DESFASE commit(s) por detras, con $CODIGO fichero(s) de codigo cambiados. Razonar sobre esa foto vieja te llevara a conclusiones falsas. Reconstruyelo primero: ./tools/sync-graph.sh workspaces/$REPO"
fi

permitir
