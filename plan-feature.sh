#!/bin/bash
# Arranca una sesión de PLANIFICACIÓN (Arquitecto/Product Owner) para un repositorio.
# A diferencia de deploy-worker.sh (que EJECUTA código), este script solo ABRE una
# conversación interactiva de solo-lectura para trocear una feature en Issues de GitHub.
set -e

if [ -z "$1" ]; then
    echo "❌ Error: Debes indicar el nombre del repositorio a planificar."
    echo "Uso: ./plan-feature.sh api-search-neuroon"
    exit 1
fi

REPO_NAME=$1
WORK_DIR="./workspaces/$REPO_NAME"

if [ ! -d "$WORK_DIR" ]; then
    echo "❌ El repositorio $REPO_NAME no está sincronizado todavía."
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
