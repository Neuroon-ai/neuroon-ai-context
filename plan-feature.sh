#!/bin/bash
# Arranca una sesión de PLANIFICACIÓN (Arquitecto/Product Owner) para un repositorio.
# A diferencia de deploy-worker.sh (que EJECUTA código), este script solo ABRE una
# conversación interactiva de solo-lectura para trocear una feature en Issues de GitHub.
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "❌ Error: Debes indicar el nombre del repositorio a planificar."
    echo "Uso: ./plan-feature.sh api-search-neuroon"
    exit 1
fi

REPO_NAME=$1
MATRIX_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Raíz de DATOS (workspaces/), distinta de la raíz de CÓDIGO. Sin esto, desde
# un git worktree secundario este script afirmaba que el repo "no está
# sincronizado todavía" (falso) y mandaba correr ./sync-fleet.sh, que en ese
# contexto duplicaba la flota entera dentro del worktree.
FLEET_ROOT="$MATRIX_ROOT"
if command -v git >/dev/null 2>&1; then
  _main_wt="$( { git -C "$MATRIX_ROOT" worktree list --porcelain 2>/dev/null || true; } \
               | sed -n '1s/^worktree //p' )"
  if [ -n "$_main_wt" ] && [ -d "$_main_wt" ] && [ -f "$_main_wt/repositories.json" ]; then
    FLEET_ROOT="$_main_wt"
  fi
  unset _main_wt
fi

MANIFEST="$MATRIX_ROOT/repositories.json"

# base_path viene de repositories.json (misma fuente que sync-fleet.sh y
# deploy-worker.sh) para que los tres scripts SIEMPRE coincidan en dónde
# vive la flota, aunque cambie.
RAW_BASE_PATH="./workspaces"
if command -v jq &> /dev/null && [ -f "$MANIFEST" ]; then
    RAW_BASE_PATH=$(jq -r '.base_path' "$MANIFEST")
fi
if command -v envsubst &> /dev/null; then
    BASE_PATH_EXPANDED=$(echo "$RAW_BASE_PATH" | envsubst)
else
    BASE_PATH_EXPANDED="$RAW_BASE_PATH"
fi
case "$BASE_PATH_EXPANDED" in
    /*) WORKSPACES_DIR="$BASE_PATH_EXPANDED" ;;
    *) WORKSPACES_DIR="$FLEET_ROOT/${BASE_PATH_EXPANDED#./}" ;;
esac
WORK_DIR="$WORKSPACES_DIR/$REPO_NAME"

if [ ! -d "$WORK_DIR" ]; then
    # La ruta buscada se imprime: un "no está" auditable vale mucho más que
    # una conclusión, sobre todo cuando la causa puede ser la raíz mal resuelta.
    echo "❌ No encuentro el repositorio $REPO_NAME en: $WORK_DIR"
    echo "   Ejecuta primero: ./sync-fleet.sh"
    exit 1
fi

if [ ! -f "$WORK_DIR/.claude/agents/planner.md" ]; then
    echo "❌ Este repositorio no tiene definido .claude/agents/planner.md."
    echo "   Cópialo desde api-search-neuroon o crea uno adaptado a este repo."
    exit 1
fi

echo "=== 🧠 Iniciando sesión de PLANIFICACIÓN para $REPO_NAME ==="
echo "Rol: Arquitecto / Product Owner (solo lectura de código, solo escritura en GitHub Issues)."
echo ""

cd "$WORK_DIR"

# Arrancamos Claude en modo INTERACTIVO (no -p) porque la planificación
# requiere ida y vuelta contigo antes de crear ninguna Issue.
# El primer mensaje le obliga a leer y adoptar su contrato de Planner
# antes de escuchar tu idea de feature.
claude "Lee completamente el archivo .claude/agents/planner.md y adopta ese rol para el resto de esta sesión. Cuando lo hayas entendido, confírmamelo brevemente y pregúntame qué funcionalidad quiero planificar."
