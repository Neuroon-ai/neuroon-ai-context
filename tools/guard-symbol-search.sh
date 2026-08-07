#!/bin/bash
# tools/guard-symbol-search.sh — hook PreToolUse sobre Bash.
#
# Por qué existe: en neuroon-audit-context (repo hermano de esta Matriz, con
# el mismo patrón de arnés) se midió el 2026-08-07 una sesión con 639
# llamadas Bash y CERO consultas a serena/graphify teniendo ambos servidores
# levantados. La causa no es desconocimiento de la tabla de enrutado: es que
# Bash está siempre a mano y las herramientas MCP están diferidas (hay que
# pedir su esquema con ToolSearch antes de poder llamarlas) — una llamada
# frente a dos. Y la propia documentación de Claude Code avisa de que un
# CLAUDE.md es CONTEXTO, no configuración: tras una compactación la prosa se
# relee pero el hábito vuelve. Así que esto se comprueba y se avisa, en vez
# de repetirlo en un fichero de texto.
#
# Qué NO hace: BLOQUEAR. Impedir no enseña a enrutar, y una pared mal
# calibrada estorba más de lo que arregla. Esta puerta AVISA y CUENTA: deja
# pasar el comando, dice qué herramienta habría sido mejor, y anota el caso
# en ~/.claude/audit/symbol-search-misses.log para que tools/audit-harness.sh
# pueda reportar con un número —no con una impresión— cuántas veces se fue
# por el camino peor. Medir, no prohibir.
#
# Tampoco toca lo que grep hace mejor: contar ocurrencias y buscar texto
# literal, ni nada fuera de workspaces/.
#
# ESTADO ACTUAL DE LA FLOTA (2026-08-07): serena-<sufijo> ya está declarado en
# .mcp.json para los 6 repos de código (ver tools/sync-fleet.sh, que da de
# alta el proyecto de serena de cada uno). El aviso de abajo ya apunta a una
# herramienta real.
set -uo pipefail

permitir() {
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
}

# Avisa sin bloquear: deja pasar el comando y devuelve el consejo de enrutado.
avisar() {
  python3 -c '
import json,sys
print(json.dumps({
  "systemMessage": sys.argv[1],
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": sys.argv[1],
  },
}))
' "$1" 2>/dev/null || echo '{}'
  exit 0
}

ENTRADA="$(cat 2>/dev/null || echo '{}')"

LOGICA="$(cat <<'PY'
import json, re, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("allow"); raise SystemExit

if data.get("tool_name") != "Bash":
    print("allow"); raise SystemExit

cmd = (data.get("tool_input") or {}).get("command", "")
if not cmd:
    print("allow"); raise SystemExit

if not re.search(r"(?:^|[|;&(\s])(?:rtk\s+)?(?:grep|rg|ugrep|find)\b", cmd):
    print("allow"); raise SystemExit

if re.search(r"grep[^|]*\s-\w*c\w*\b|\|\s*wc\b|--count", cmd):
    print("allow"); raise SystemExit

# Los 6 repos de código de la flota (repositories.json) — "status" queda
# fuera: es infraestructura Upptime sin código propio, fuera de alcance del
# arnés (ver harness_notes de "status" en repositories.json).
if not re.search(
    r"workspaces/(api-search-neuroon|app-search-neuroon|app-search-widget-neuroon"
    r"|docs-search-widget-neuroon|wordpress-plugin-neuroon-search|api-search-engine)"
    r"|(?:^|\s)src/(main|test)/",
    cmd,
):
    print("allow"); raise SystemExit

if re.search(r"\.(log|json|md|sql|xml|yml|yaml|txt|csv)\b", cmd):
    print("allow"); raise SystemExit

repo = "api"
if "app-search-widget-neuroon" in cmd:
    repo = "widget"
elif "app-search-neuroon" in cmd:
    repo = "app"
elif "docs-search-widget-neuroon" in cmd:
    repo = "docs"
elif "wordpress-plugin-neuroon-search" in cmd:
    repo = "wp"
elif "api-search-engine" in cmd:
    repo = "engine"

# class/interface/enum: Java, TS/JS. function/type: TS/JS, PHP. Sin "fun
# interface"/"object" (Kotlin-only, no hay Kotlin en esta flota).
declaracion = re.search(r"(class|interface|enum(?: class)?|function|type)\s+[A-Z]", cmd)
identificador = re.search(r"[\'\"]([A-Z][A-Za-z0-9]{3,})[\'\"]", cmd)
por_fichero = re.search(r"find\b[^|]*-name\s+[\'\"]?\*?[A-Z][A-Za-z0-9]*", cmd)
solo_ficheros = re.search(r"grep[^|]*\s-\w*l\w*\b", cmd)

if declaracion or por_fichero or (identificador and solo_ficheros):
    print("deny:" + repo)
else:
    print("allow")
PY
)"

VEREDICTO="$(printf '%s' "$ENTRADA" | python3 -c "$LOGICA" 2>/dev/null || echo "allow")"

case "$VEREDICTO" in
  deny:*)
    REPO="${VEREDICTO#deny:}"
    REGISTRO="$HOME/.claude/audit/symbol-search-misses.log"
    mkdir -p "$(dirname "$REGISTRO")" 2>/dev/null
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REPO" >> "$REGISTRO" 2>/dev/null
    avisar "Eso es localizar la declaración de un símbolo, y para eso está serena, que lee el árbol sintáctico en vez de adivinar por texto: usa mcp__serena-${REPO}__find_symbol (o find_referencing_symbols si lo que quieres es ver sus usos antes de tocarlo). Están diferidas: cárgalas con ToolSearch 'select:mcp__serena-${REPO}__find_symbol,mcp__serena-${REPO}__find_referencing_symbols'. El comando SE EJECUTA igual, esto no te bloquea: es un aviso de enrutado, y queda anotado para poder medir cuántas veces se elige el camino peor. Si serena todavía no está declarado para este repo en .mcp.json, este aviso es un recordatorio de que falta añadirlo — no de que exista ya. Si lo tuyo era contar o buscar texto literal, grep era lo correcto y este aviso sobra."
    ;;
  *) permitir ;;
esac
