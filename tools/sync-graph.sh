#!/bin/bash
# tools/sync-graph.sh — mantiene el grafo de código (graphify) de un repo de
# la flota sincronizado con su HEAD.
#
# Uso:
#   ./tools/sync-graph.sh [ruta]     # construye o refresca si HEAD avanzó
#
# La caché vive centralizada en workspaces/.graphify-data/<repo>/graphify-out
# (gitignored) — NO junto al repo. Motivo: desde que se trabaja con una única
# sesión Claude en la raíz de la Matriz viendo toda la flota a la vez (en vez
# de un worker por repo, cd'eado dentro de él), regenerar el grafo DENTRO de
# cada repo ensuciaría cada PR con diffs de +100k líneas, y unos hooks
# post-commit por repo no sirven para mantener sincronizados varios clones
# vistos desde fuera. La Matriz es la única guardiana: correr esto (o
# ./sync-fleet.sh, que lo hace por todos) es lo que mantiene el grafo al día,
# no un hook automático dentro del repo.
#
# Idempotente: si el grafo ya corresponde al HEAD actual, no hace nada.
#
# No falla duro para el LLAMANTE (sync-fleet.sh sigue con el resto de la
# flota), pero tampoco miente: cada ruta de fallo sale con un código distinto
# de 0 para que se pueda CONTAR. Antes las tres salían con 0 y sync-fleet.sh
# terminaba anunciando "✅ Sincronización completa" sin haber construido ni
# un grafo.
#   3 = no se pudo medir/construir (graphify ausente, o HEAD ilegible)
#   4 = graphify extract falló
#   5 = grafo vacío (sin código indexable)
set -euo pipefail

MATRIX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Raíz de DATOS (workspaces/), distinta de la raíz de CÓDIGO. Sin esto, desde
# un git worktree secundario este script construía una SEGUNDA caché de
# grafos dentro del worktree, que ningún .mcp.json lee.
FLEET_ROOT="$MATRIX_ROOT"
if command -v git >/dev/null 2>&1; then
  _main_wt="$( { git -C "$MATRIX_ROOT" worktree list --porcelain 2>/dev/null || true; } \
               | sed -n '1s/^worktree //p' )"
  if [ -n "$_main_wt" ] && [ -d "$_main_wt" ] && [ -f "$_main_wt/repositories.json" ]; then
    FLEET_ROOT="$_main_wt"
  fi
  unset _main_wt
fi

REPO="${1:-.}"
# Un argumento relativo que no exista en el cwd se resuelve contra la raíz de
# DATOS, para que el remedio que imprimen session-brief/guard-graph-fresh/
# audit-harness ("./tools/sync-graph.sh workspaces/<repo>") sea ejecutable
# desde cualquier sitio, incluido un worktree.
[ -d "$REPO" ] || REPO="$FLEET_ROOT/$REPO"
if [ ! -d "$REPO" ]; then
  echo "❌ No existe el directorio: $REPO"
  exit 1
fi
REPO="$(cd "$REPO" && pwd)"
REPO_NAME="$(basename "$REPO")"
cd "$REPO"

export GRAPHIFY_OUT="$FLEET_ROOT/workspaces/.graphify-data/$REPO_NAME/graphify-out"
mkdir -p "$GRAPHIFY_OUT"

echo "=== 🕸️  Sync Graph — $REPO_NAME ==="

if ! { command -v graphify &>/dev/null && graphify --version &>/dev/null; }; then
  echo "⚠️  graphify no está instalado/operativo — no se puede construir el grafo (correr ./install-factory.sh)."
  exit 3
fi

# Sin centinela: el "sin-git" de antes acababa escrito en .built-at-commit, y
# a partir de ahí todos los consumidores comparaban contra un commit que no
# existe. Ese diff fallido es justo lo que session-brief.sh convertía en
# "SIN cambios de código: sirve igual".
if ! ACTUAL="$(git rev-parse HEAD 2>/dev/null)"; then
  echo "⚠️  $REPO_NAME no tiene HEAD legible — no se construye ni se sella el grafo (no medir no es verde)."
  exit 3
fi

MARCA="$GRAPHIFY_OUT/.built-at-commit"
STATS="$GRAPHIFY_OUT/.graph-stats"

# Las cifras del grafo se miden del PROPIO grafo (formato node-link: las
# aristas van en .links, y cada nodo lleva su .community), no parseando la
# salida de graphify: así salen iguales tanto si acabamos de reconstruir como
# si el grafo ya estaba al día, y no dependen del formato de unos mensajes.
# ~0.6 s sobre el grafo mayor de la flota (49 MB). repositories.json apunta
# aquí en vez de llevar las cifras escritas a mano, que caducaban en cada
# rebuild sin que nadie las tocara.
escribir_stats() {
  local cifras
  command -v jq >/dev/null 2>&1 || { echo "⚠️  jq no está instalado — no se pueden medir las cifras del grafo (incógnita, no verde)."; return 1; }
  cifras="$(jq -r '"\(.nodes|length) nodes, \(.links|length) edges, \([.nodes[].community]|unique|length) communities"' "$GRAPHIFY_OUT/graph.json" 2>/dev/null)" || {
    echo "⚠️  No se pudieron medir las cifras del grafo de $REPO_NAME (incógnita, no verde)."; return 1; }
  [ -n "$cifras" ] || { echo "⚠️  Cifras del grafo de $REPO_NAME vacías (incógnita, no verde)."; return 1; }
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ACTUAL" "$cifras" > "$STATS"
  echo "📐 $cifras"
}

if [ -f "$GRAPHIFY_OUT/graph.json" ] && [ -f "$MARCA" ] && [ "$(cat "$MARCA")" = "$ACTUAL" ]; then
  echo "✅ Grafo de $REPO_NAME al día (HEAD $(echo "$ACTUAL" | cut -c1-7) ya construido)."
  # Idempotente pero no perezoso: si las cifras faltan (grafo construido por
  # una versión anterior de este script), se miden ahora sin reconstruir nada.
  [ -f "$STATS" ] || escribir_stats || true
  exit 0
fi

echo "🔧 (Re)construyendo el grafo de $REPO_NAME (AST local, sin LLM)..."
if ! graphify extract . --code-only; then
  echo "⚠️  extract falló; el grafo anterior (si existía) sigue sirviendo, pero NO se ha refrescado."
  exit 4
fi

if [ ! -f "$GRAPHIFY_OUT/graph.json" ]; then
  echo "⚠️  Grafo vacío: graphify no encontró código indexable en $REPO_NAME (extensiones de esta flota: .java .py .php .ts .tsx .js .jsx)."
  exit 5
fi

echo "$ACTUAL" > "$MARCA"
escribir_stats || true

echo "✅ Grafo de $REPO_NAME sincronizado con HEAD $(echo "$ACTUAL" | cut -c1-7) en $GRAPHIFY_OUT/graph.json"
