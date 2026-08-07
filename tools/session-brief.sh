#!/bin/bash
# tools/session-brief.sh — hook SessionStart de la Matriz.
#
# Por qué existe: la documentación oficial es explícita en que CLAUDE.md es
# CONTEXTO, no configuración, y en campo se mide que las sesiones vuelven a
# bash/grep sobre todo (a) tras una compactación y (b) en subagentes. Un
# fichero que se lee una vez al arrancar no sobrevive a eso; un hook
# SessionStart con matcher `compact` sí se vuelve a ejecutar.
#
# Qué hace: imprime el estado REAL de la flota (HEAD, frescura del grafo) y
# la tabla tarea→herramienta, y lo devuelve como additionalContext. Solo
# mide, no decide: si algo no se puede medir se dice, nunca se da por bueno.
#
# Nunca falla duro: un hook roto no puede impedir trabajar.
set -uo pipefail

MATRIX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACES="$MATRIX_ROOT/workspaces"

# Los 6 repos de código de la flota (repositories.json). "status" (Upptime)
# queda fuera: sin código propio, fuera de alcance del arnés.
estado_de_los_grafos() {
  local repo ruta head sello desfase codigo
  for repo in api-search-neuroon app-search-neuroon app-search-widget-neuroon \
              docs-search-widget-neuroon wordpress-plugin-neuroon-search api-search-engine; do
    ruta="$WORKSPACES/$repo"
    if [ ! -d "$ruta/.git" ]; then
      echo "  - $repo: NO CLONADO (corre ./sync-fleet.sh)"
      continue
    fi
    head="$(git -C "$ruta" rev-parse HEAD 2>/dev/null || echo "")"
    sello="$(cat "$WORKSPACES/.graphify-data/$repo/graphify-out/.built-at-commit" 2>/dev/null || echo "")"
    if [ -z "$head" ]; then
      echo "  - $repo: HEAD ilegible — INCÓGNITA, no asumas nada"
    elif [ -z "$sello" ]; then
      echo "  - $repo: HEAD ${head:0:7} · grafo SIN CONSTRUIR -> ./tools/sync-graph.sh workspaces/$repo"
    elif [ "$sello" = "$head" ]; then
      echo "  - $repo: HEAD ${head:0:7} · grafo al día"
    else
      desfase="$(git -C "$ruta" rev-list --count "$sello".."$head" 2>/dev/null || echo "?")"
      codigo="$(git -C "$ruta" diff --name-only "$sello" "$head" -- '*.java' '*.py' '*.php' '*.ts' '*.tsx' '*.js' '*.jsx' 2>/dev/null | wc -l | tr -d ' ')"
      if [ "${codigo:-0}" -gt 0 ]; then
        echo "  - $repo: HEAD ${head:0:7} · grafo ${sello:0:7}, $desfase commit(s) y $codigo fichero(s) de código por detrás -> RECONSTRUIR antes de fiarte"
      else
        echo "  - $repo: HEAD ${head:0:7} · grafo ${sello:0:7}, $desfase commit(s) por detrás pero SIN cambios de código: sirve igual"
      fi
    fi
  done
}

BRIEF="$(cat <<EOF
# Estado de la flota Neuroon (medido por tools/session-brief.sh)

$(estado_de_los_grafos)

# Enrutado obligatorio de tarea → herramienta

Tienes MCPs que rinden mucho más que grep/bash para estas tareas. Úsalos:

| Si la tarea es… | Usa | No uses |
|---|---|---|
| Entender la forma de un repo que no conoces | \`mcp__graphify-<repo>__graph_stats\`, \`god_nodes\` | leer ficheros al azar |
| Saber a qué afecta tocar un símbolo | \`mcp__graphify-<repo>__get_community\`, \`get_neighbors\` | grep a ciegas |
| Localizar/renombrar un símbolo, CONTAR sus usos | \`mcp__serena-<repo>__find_symbol\`, \`find_referencing_symbols\`, \`rename_symbol\` (ver nota de abajo) | sed, edición a mano |
| Verificar un cambio en api-search-neuroon | \`./mvnw verify\` dentro de workspaces/api-search-neuroon | dar por bueno que compila |
| Verificar un cambio en un frontend (Next.js/Vite/Docusaurus) | \`npm run build\`/\`npm test\` dentro de ese repo | dar por bueno que compila |
| Verificar api-search-engine (Python) | \`pytest\` dentro de workspaces/api-search-engine | dar por bueno que corre |
| Buscar texto literal, contar ocurrencias | grep / rg | el grafo (subreporta, ver abajo) |

**Sufijo por repo**: \`-api\` = api-search-neuroon · \`-app\` = app-search-neuroon ·
\`-widget\` = app-search-widget-neuroon · \`-docs\` = docs-search-widget-neuroon ·
\`-wp\` = wordpress-plugin-neuroon-search · \`-engine\` = api-search-engine.

**Estado real de los MCP (2026-08-07)**: \`graphify-<sufijo>\` y \`serena-<sufijo>\`
están declarados en \`.mcp.json\` para los 6 repos de código, más \`serena\` a
secas para la propia Matriz. \`./sync-fleet.sh\` mantiene esto — da de alta el
proyecto de serena de cada repo y refresca su grafo si ya estaba declarado en
\`mcp_servers\`.

**Si no ves un servidor que esta tabla nombra**, tu sesión es anterior a su
alta: los MCP se fijan al arrancar y no se aplican en caliente. Compruébalo
con ToolSearch antes de concluir que está roto, y si falta, reinicia la
sesión en vez de buscarte la vida con bash.

**El grafo tiene límites, no lo cites a ciegas**: sirve para forma,
comunidades y radio de impacto — no para CONTAR o localizar llamadores con
precisión (la inyección de dependencias vía constructor, muy usada en
api-search-neuroon, no siempre se ve en el grafo). Para eso, grep o
\`find_referencing_symbols\` de serena.

# Reglas que no se negocian

1. Toda afirmación sobre código existente lleva fichero:línea verificado en ESTA sesión.
2. \`feature_list.json\` solo admite \`verified\` si TÚ ejecutaste la verificación y la viste pasar.
3. "No pude medir" es una incógnita, nunca un verde.
4. Ante ambigüedad de producto, pregunta al humano en vez de elegir por él.
EOF
)"

printf '%s' "$BRIEF" | python3 -c '
import json,sys
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.stdin.read()}}))
' 2>/dev/null || echo '{}'
