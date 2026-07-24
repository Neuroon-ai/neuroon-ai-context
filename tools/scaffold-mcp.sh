#!/bin/bash
# tools/scaffold-mcp.sh — Genera/sincroniza el .mcp.json de un repo a partir
# de los servidores MCP declarados en repositories.json (fuente de verdad de
# la flota) + las plantillas en templates/mcp/<nombre>.json.
#
# Idempotente y aditivo: nunca borra ni toca un servidor que el .mcp.json
# destino ya tenga (aunque no venga de una plantilla nuestra), solo añade
# los que repositories.json declara y todavía faltan.
#
# Uso:
#   ./tools/scaffold-mcp.sh <nombre-repo> --target <ruta>
set -euo pipefail

REPO_NAME="${1:-}"
shift || true
TARGET="."
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$REPO_NAME" ]; then
  echo "Uso: ./tools/scaffold-mcp.sh <nombre-repo> --target <ruta>"
  exit 1
fi
if [ ! -d "$TARGET" ]; then
  echo "❌ No existe el directorio destino: $TARGET"
  exit 1
fi

MATRIX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$(cd "$TARGET" && pwd)"

if ! command -v jq &> /dev/null; then
  echo "⚠️  jq no disponible; se omite scaffold-mcp.sh."
  exit 0
fi

SERVERS=$(jq -r --arg n "$REPO_NAME" '(.projects[] | select(.name==$n) | .mcp_servers[]?)' "$MATRIX_ROOT/repositories.json" 2>/dev/null || true)
if [ -z "$SERVERS" ]; then
  echo "ℹ️  $REPO_NAME no declara servidores MCP en repositories.json — nada que hacer."
  exit 0
fi

TARGET_MCP="$TARGET/.mcp.json"
[ -f "$TARGET_MCP" ] || echo '{"mcpServers": {}}' > "$TARGET_MCP"

while IFS= read -r server; do
  [ -n "$server" ] || continue
  TEMPLATE="$MATRIX_ROOT/templates/mcp/$server.json"
  if [ ! -f "$TEMPLATE" ]; then
    echo "⚠️  No existe templates/mcp/$server.json — se omite ($server)."
    continue
  fi
  if jq -e --arg s "$server" '.mcpServers[$s]' "$TARGET_MCP" &> /dev/null; then
    echo "⏭️  $server ya presente en $TARGET_MCP"
    continue
  fi
  tmp=$(mktemp)
  jq --slurpfile tpl "$TEMPLATE" --arg s "$server" '.mcpServers[$s] = $tpl[0][$s]' "$TARGET_MCP" > "$tmp" && mv "$tmp" "$TARGET_MCP"
  echo "✅ Añadido $server a $TARGET_MCP"
done <<< "$SERVERS"
