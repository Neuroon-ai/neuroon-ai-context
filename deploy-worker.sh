#!/bin/bash
# Despliega un repositorio y le arranca un agente Hermes atado a él
set -e

if [ -z "$1" ]; then
    echo "❌ Error: Debes indicar el nombre del repositorio a desplegar."
    echo "Uso: ./deploy-worker.sh api-search-neuroon"
    exit 1
fi

REPO_NAME=$1
ORG="Neuroon-ai"
WORK_DIR="./workspaces/$REPO_NAME"

echo "=== 🚀 Desplegando Worker para $REPO_NAME ==="

mkdir -p "./workspaces"
cd "./workspaces"

# Clonar si no existe, hacer pull si existe
if [ ! -d "$REPO_NAME" ]; then
    gh repo clone "$ORG/$REPO_NAME"
    cd "$REPO_NAME"
else
    cd "$REPO_NAME"
    git pull origin develop || git pull origin main
fi

# Inicializar configuración base si existe arnés
if [ -f "init.sh" ]; then
    echo "🔄 Ejecutando Arnés (Paso 0 - Configuración local)..."
    # Este init.sh creará el .mcp.json si no existe.
    bash ./init.sh || echo "⚠️ El init.sh falló (¿Faltan secrets en el .env?)"
else
    echo "⚠️ Este proyecto no tiene init.sh. No está adaptado para Harness Engineering."
fi

echo "🤖 Preparando agente Claude Code para $REPO_NAME..."
# Mostramos la instrucción para arrancar a trabajar en ese repo
echo "✅ Worker desplegado."
echo "Para arrancar el agente a trabajar, entra en la carpeta:"
echo "   cd $WORK_DIR"
echo "Y ejecuta:"
echo "   claude -p \"Lee claude-progress.md y feature_list.json. Si hay algo in_progress, ejecútalo siguiendo el arnés.\""
