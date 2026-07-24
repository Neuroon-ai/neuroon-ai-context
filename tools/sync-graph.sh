#!/bin/bash
# tools/sync-graph.sh — Bootstrap del grafo de código (graphify) para un repo
# de la flota Neuroon.
#
# Uso:
#   ./tools/sync-graph.sh [ruta]
#
# Es un bootstrap DE UNA VEZ, no un chequeo de staleness recurrente: tras
# correr esto, `graphify hook install` deja hooks post-commit/post-checkout
# locales que mantienen graphify-out/graph.json actualizado solo (AST local,
# sin LLM), sin CI y sin que nadie tenga que acordarse — patrón oficial
# documentado en el README de graphify ("Team setup"). Nunca falla duro.
set -euo pipefail

REPO="${1:-.}"
if [ ! -d "$REPO" ]; then
  echo "❌ No existe el directorio: $REPO"
  exit 1
fi
REPO="$(cd "$REPO" && pwd)"
cd "$REPO"

echo "=== 🕸️  Sync Graph — $REPO ==="

if ! { command -v graphify &>/dev/null && graphify --version &>/dev/null; }; then
  echo "⚠️  graphify no está instalado/operativo en esta máquina — se omite (correr ./install-factory.sh)."
  exit 0
fi

if [ ! -f "graphify-out/graph.json" ]; then
  echo "🔧 Primer build local: graphify extract . --code-only (AST local, sin LLM)"
  graphify extract . --code-only || { echo "⚠️  extract falló; se omite esta ronda."; exit 0; }
fi

if [ ! -f "graphify-out/graph.json" ]; then
  echo "⚠️  Grafo vacío (repo sin código soportado todavía) — se omite el resto."
  exit 0
fi

# Si el repo usa .githooks/ (convención de esta flota) pero core.hooksPath
# todavía no apunta ahí, los hooks de graphify caerían en .git/hooks/ (no
# versionado, no compartido con el equipo) en vez de .githooks/ (versionado).
if [ -d ".githooks" ] && [ "$(git config core.hooksPath 2>/dev/null || true)" != ".githooks" ]; then
  echo "⚠️  core.hooksPath no apunta a .githooks/ todavía — corre ./init.sh antes de esto para que los hooks de graphify se compartan con el equipo vía git."
fi

# Exclusiones de graphify en .gitignore (idempotente, también cuando el
# .gitignore ya existía y el scaffold no lo tocó): graphify-out/ SE COMMITEA,
# solo se ignora lo local/regenerable.
if ! grep -qxF "/graphify-out/cache/" .gitignore 2>/dev/null; then
  cat >> .gitignore <<'IGNORE'

# graphify (grafo de código de la fábrica): solo se ignora lo local/regenerable.
# graphify-out/ SE COMMITEA (patrón oficial de graphify, "Team setup").
/graphify-out/cost.json
/graphify-out/cache/
/graphify-out/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/
IGNORE
  echo "🔧 Exclusiones de graphify añadidas a .gitignore."
fi

echo "🔧 Instalando hooks de auto-actualización (post-commit/post-checkout) + merge driver..."
graphify hook install || echo "⚠️  No se pudieron instalar los hooks de graphify; el grafo no se auto-actualizará."

echo "✅ Grafo listo en graphify-out/graph.json — a partir de aquí se mantiene solo (git hooks locales)."
