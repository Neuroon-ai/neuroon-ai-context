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
set -uo pipefail

MATRIX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

permitir() { echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'; exit 0; }

denegar() {
  python3 -c '
import json,sys
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":sys.argv[1]}}))
' "$1" 2>/dev/null || echo '{}'
  exit 0
}

ENTRADA="$(cat 2>/dev/null || echo '{}')"
TOOL="$(printf '%s' "$ENTRADA" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("tool_name",""))' 2>/dev/null || echo "")"

# Sufijo → repo, mismo mapeo que tools/guard-symbol-search.sh y
# tools/session-brief.sh. Solo graphify-api está declarado hoy en .mcp.json
# (repositories.json → mcp_servers); las demás ramas quedan listas para
# cuando se añada cada repo, sin tocar este fichero otra vez.
case "$TOOL" in
  mcp__graphify-api__*)    REPO="api-search-neuroon" ;;
  mcp__graphify-app__*)    REPO="app-search-neuroon" ;;
  mcp__graphify-widget__*) REPO="app-search-widget-neuroon" ;;
  mcp__graphify-docs__*)   REPO="docs-search-widget-neuroon" ;;
  mcp__graphify-wp__*)     REPO="wordpress-plugin-neuroon-search" ;;
  mcp__graphify-engine__*) REPO="api-search-engine" ;;
  *) permitir ;;
esac

RUTA="$MATRIX_ROOT/workspaces/$REPO"
SELLO_FILE="$MATRIX_ROOT/workspaces/.graphify-data/$REPO/graphify-out/.built-at-commit"

[ -d "$RUTA/.git" ] || permitir

HEAD_ACTUAL="$(git -C "$RUTA" rev-parse HEAD 2>/dev/null || echo "")"
[ -n "$HEAD_ACTUAL" ] || permitir

if [ ! -f "$SELLO_FILE" ]; then
  denegar "El grafo de $REPO no tiene sello de construcción, así que no se puede saber a qué commit corresponde y no medir no es verde. Construyelo con: ./tools/sync-graph.sh workspaces/$REPO"
fi

SELLO="$(cat "$SELLO_FILE" 2>/dev/null || echo "")"
[ "$SELLO" = "$HEAD_ACTUAL" ] && permitir

git -C "$RUTA" cat-file -e "${SELLO}^{commit}" 2>/dev/null || \
  denegar "El grafo de $REPO se construyó sobre el commit ${SELLO:0:7}, que ya no existe en este clon (rebase o fuerza). Reconstruyelo: ./tools/sync-graph.sh workspaces/$REPO"

# Extensiones de código de esta flota: Java (api-search-neuroon), Python
# (api-search-engine), PHP (wordpress-plugin-neuroon-search) y TS/JS (los
# tres frontends: app-search-neuroon, app-search-widget-neuroon,
# docs-search-widget-neuroon). Ningún repo usa Kotlin.
CODIGO="$(git -C "$RUTA" diff --name-only "$SELLO" "$HEAD_ACTUAL" -- '*.java' '*.py' '*.php' '*.ts' '*.tsx' '*.js' '*.jsx' 2>/dev/null | wc -l | tr -d ' ')"
DESFASE="$(git -C "$RUTA" rev-list --count "$SELLO".."$HEAD_ACTUAL" 2>/dev/null || echo "?")"

if [ "${CODIGO:-0}" -gt 0 ]; then
  denegar "El grafo de $REPO está construido sobre ${SELLO:0:7} y HEAD es ${HEAD_ACTUAL:0:7}: $DESFASE commit(s) por detrás, con $CODIGO fichero(s) de código cambiados. Razonar sobre esa foto vieja te llevará a conclusiones falsas. Reconstruyelo primero: ./tools/sync-graph.sh workspaces/$REPO"
fi

permitir
