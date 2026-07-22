#!/bin/bash
# Sincroniza (clona o actualiza) todos los repositorios definidos en repositories.json
set -e

MANIFEST="repositories.json"

if [ ! -f "$MANIFEST" ]; then
    echo "❌ No se encuentra $MANIFEST"
    exit 1
fi

ORG=$(jq -r '.org' "$MANIFEST")
BASE_PATH=$(jq -r '.base_path' "$MANIFEST" | envsubst)

echo "=== 🌐 Sincronizando Flota de Repositorios Neuroon ==="
mkdir -p "$BASE_PATH"

# Leer cada proyecto del JSON e iterar
jq -c '.projects[]' "$MANIFEST" | while read -r project; do
    NAME=$(echo "$project" | jq -r '.name')
    ENABLED=$(echo "$project" | jq -r '.agent_enabled')
    
    echo "➡️ Procesando: $NAME"
    
    if [ ! -d "$BASE_PATH/$NAME" ]; then
        echo "   Clonando $ORG/$NAME..."
        (cd "$BASE_PATH" && gh repo clone "$ORG/$NAME")
    else
        echo "   Actualizando $NAME..."
        (cd "$BASE_PATH/$NAME" && git pull origin develop || git pull origin main)
    fi
    
    # Si tiene un worker Hermes asignado y activado, verificar si está corriendo
    if [ "$ENABLED" = "true" ]; then
        echo "   🤖 Agente habilitado para $NAME. (Usa ./deploy-worker.sh $NAME para arrancar el worker)."
    fi
done

echo "✅ Sincronización completa."
