#!/bin/bash
# Sincroniza (clona o actualiza) todos los repositorios definidos en repositories.json
set -euo pipefail

MANIFEST="repositories.json"

if [ ! -f "$MANIFEST" ]; then
    echo "❌ No se encuentra $MANIFEST"
    exit 1
fi

ORG=$(jq -r '.org' "$MANIFEST")
RAW_BASE_PATH=$(jq -r '.base_path' "$MANIFEST")
if command -v envsubst &> /dev/null; then
    BASE_PATH=$(echo "$RAW_BASE_PATH" | envsubst)
else
    echo "⚠️  envsubst no está instalado (correr ./install-factory.sh) — usando base_path tal cual, sin expandir variables."
    BASE_PATH="$RAW_BASE_PATH"
fi

echo "=== 🌐 Sincronizando Flota de Repositorios Neuroon ==="
mkdir -p "$BASE_PATH"

# Leer cada proyecto del JSON e iterar
jq -c '.projects[]' "$MANIFEST" | while read -r project; do
    NAME=$(echo "$project" | jq -r '.name')
    ENABLED=$(echo "$project" | jq -r '.agent_enabled')
    BRANCH=$(echo "$project" | jq -r '.default_branch // "main"')

    echo "➡️ Procesando: $NAME"

    if [ ! -d "$BASE_PATH/$NAME" ]; then
        echo "   Clonando $ORG/$NAME..."
        (cd "$BASE_PATH" && gh repo clone "$ORG/$NAME")
    elif ! git -C "$BASE_PATH/$NAME" rev-parse --is-inside-work-tree &> /dev/null; then
        # El directorio existe pero no es un repo git válido (p. ej. un
        # "gh repo clone" anterior interrumpido a medias) — no dejar que
        # `git branch --show-current` reviente el script entero (set -e) y
        # tumbe la sincronización del resto de la flota.
        echo "   ⚠️  $BASE_PATH/$NAME existe pero no es un repositorio git válido — omitido (bórralo y vuelve a correr ./sync-fleet.sh para reclonarlo)."
    else
        # NUNCA tocar una rama de trabajo: solo se hace pull si el repo está
        # en su default_branch declarado en repositories.json (que varía por
        # proyecto — no asumas que toda la flota usa la misma rama).
        CURRENT="$(git -C "$BASE_PATH/$NAME" branch --show-current)"
        if [ "$CURRENT" = "$BRANCH" ]; then
            echo "   Actualizando $NAME (rama $BRANCH)..."
            git -C "$BASE_PATH/$NAME" pull origin "$BRANCH"
        else
            echo "   ⚠️  $NAME está en la rama de trabajo '$CURRENT' (≠ $BRANCH) — no se toca."
        fi
    fi

    # Si tiene un worker asignado y activado, recordar cómo arrancarlo
    if [ "$ENABLED" = "true" ]; then
        echo "   🤖 Agente habilitado para $NAME. (Usa ./deploy-worker.sh $NAME para arrancar el worker)."
    fi
done

echo "✅ Sincronización completa."
