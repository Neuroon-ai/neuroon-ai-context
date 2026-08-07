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
# Nunca falla duro — un grafo desactualizado se detecta aparte con
# tools/guard-graph-fresh.sh (hook PreToolUse) y tools/audit-harness.sh (S6).
set -euo pipefail

MATRIX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

REPO="${1:-.}"
if [ ! -d "$REPO" ]; then
  echo "❌ No existe el directorio: $REPO"
  exit 1
fi
REPO="$(cd "$REPO" && pwd)"
REPO_NAME="$(basename "$REPO")"
cd "$REPO"

export GRAPHIFY_OUT="$MATRIX_ROOT/workspaces/.graphify-data/$REPO_NAME/graphify-out"
mkdir -p "$GRAPHIFY_OUT"

echo "=== 🕸️  Sync Graph — $REPO_NAME ==="

if ! { command -v graphify &>/dev/null && graphify --version &>/dev/null; }; then
  echo "⚠️  graphify no está instalado/operativo — se omite (correr ./install-factory.sh)."
  exit 0
fi

ACTUAL="$(git rev-parse HEAD 2>/dev/null || echo "sin-git")"
MARCA="$GRAPHIFY_OUT/.built-at-commit"

if [ -f "$GRAPHIFY_OUT/graph.json" ] && [ -f "$MARCA" ] && [ "$(cat "$MARCA")" = "$ACTUAL" ]; then
  echo "✅ Grafo de $REPO_NAME al día (HEAD $(echo "$ACTUAL" | cut -c1-7) ya construido)."
  exit 0
fi

echo "🔧 (Re)construyendo el grafo de $REPO_NAME (AST local, sin LLM)..."
if ! graphify extract . --code-only; then
  echo "⚠️  extract falló; el grafo anterior (si existía) sigue sirviendo. Se omite esta ronda."
  exit 0
fi

if [ ! -f "$GRAPHIFY_OUT/graph.json" ]; then
  echo "⚠️  Grafo vacío (repo sin código soportado todavía, p.ej. wordpress-plugin-neuroon-search)."
  exit 0
fi

echo "$ACTUAL" > "$MARCA"
echo "✅ Grafo de $REPO_NAME sincronizado con HEAD $(echo "$ACTUAL" | cut -c1-7) en $GRAPHIFY_OUT/graph.json"
