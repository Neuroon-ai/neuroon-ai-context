#!/bin/bash
# Sincroniza (clona o actualiza) todos los repositorios definidos en repositories.json
set -euo pipefail

MATRIX_ROOT="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$MATRIX_ROOT/repositories.json"

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
# Un base_path relativo es relativo a la Matriz (donde vive el script), no al
# cwd: si no, correr el script desde otro sitio duplicaría la flota entera.
case "$BASE_PATH" in
    /*) ;;
    *) BASE_PATH="$MATRIX_ROOT/${BASE_PATH#./}" ;;
esac

# Los fallos tolerados (un pull que no baja, un proyecto de serena que no se
# da de alta, un grafo que no se reconstruye) dejan seguir con el resto de la
# flota, pero se cuentan: terminar con fallos y decir "✅ completa" mentiría
# al operador. Sin process substitution (`< <(...)` al final del while) el
# contador se perdería: un `| while` corre en una subshell.
FALLOS=0

echo "=== 🌐 Sincronizando Flota de Repositorios Neuroon ==="
mkdir -p "$BASE_PATH"

while read -r project; do
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
            if ! git -C "$BASE_PATH/$NAME" pull origin "$BRANCH"; then
                echo "   ❌ Pull de $BRANCH falló para $NAME — se sigue con el resto de la flota."
                FALLOS=$((FALLOS + 1))
            fi
        else
            echo "   ⚠️  $NAME está en la rama de trabajo '$CURRENT' (≠ $BRANCH) — no se toca."
        fi
    fi

    # Proyecto de serena para este repo. Los servidores serena-<repo> de
    # .mcp.json piden su proyecto POR NOMBRE (no por ruta), así que da igual
    # el cwd desde el que se abra la sesión — pero el nombre tiene que estar
    # dado de alta en el registro global de serena (~/.serena/serena_config.yml),
    # y eso lo hace `serena project create`, que es lo que se ejecuta aquí. Ni
    # el project.yml ni el registro viajan con el clon (gitignoreados por
    # /workspaces/ aquí y por /.serena/ en cada repo): son estado de máquina y
    # se rehacen en cada una. El lenguaje sale del `framework` que ya declara
    # repositories.json: un framework sin mapeo se avisa, no se adivina.
    SERENA_LANG=""
    FRAMEWORK="$(echo "$project" | jq -r '.framework // ""')"
    case "$FRAMEWORK" in
        *spring-boot*|*java*)                     SERENA_LANG="java" ;;
        *next*|*vite*|*react*|*docusaurus*|*node*) SERENA_LANG="typescript" ;;
        *wordpress*|*php*)                         SERENA_LANG="php" ;;
        *python*)                                  SERENA_LANG="python" ;;
        *upptime*)                                 SERENA_LANG="__fuera_de_alcance__" ;;
    esac
    SERENA_REG="$HOME/.serena/serena_config.yml"
    if [ "$SERENA_LANG" = "__fuera_de_alcance__" ]; then
        echo "   ⏭️  $NAME (framework $FRAMEWORK) fuera de alcance del arnés — sin proyecto de serena."
    elif [ -f "$BASE_PATH/$NAME/.serena/project.yml" ]; then
        REPO_ABS="$(cd "$BASE_PATH/$NAME" && pwd)"
        # `-e` obligatorio: el patrón empieza por "- " y sin él grep se lo
        # come como si fuera una opción suya.
        if [ -f "$SERENA_REG" ] && ! grep -qxF -e "- $REPO_ABS" "$SERENA_REG"; then
            echo "   ⚠️  $NAME tiene .serena/project.yml pero NO está en el registro de serena ($SERENA_REG): el servidor serena-* que lo busca por nombre arrancará sin proyecto. Borra ese project.yml y vuelve a pasar por aquí."
            FALLOS=$((FALLOS + 1))
        else
            echo "   ✅ serena ya tiene proyecto declarado para $NAME."
        fi
    elif [ -z "$SERENA_LANG" ]; then
        echo "   ⚠️  Framework '$FRAMEWORK' sin mapeo a lenguaje de serena — añádelo en sync-fleet.sh o $NAME se queda sin edición simbólica."
        FALLOS=$((FALLOS + 1))
    elif ! command -v serena >/dev/null 2>&1; then
        echo "   ⚠️  serena no está instalado (corre ./install-factory.sh) — $NAME se queda sin edición simbólica."
        FALLOS=$((FALLOS + 1))
    else
        echo "   Creando proyecto de serena para $NAME (lenguaje: $SERENA_LANG)..."
        if ! serena project create --name "$NAME" --language "$SERENA_LANG" "$BASE_PATH/$NAME" >/dev/null; then
            echo "   ⚠️  No se pudo crear el proyecto de serena para $NAME — se sigue con el resto de la flota."
            FALLOS=$((FALLOS + 1))
        fi
    fi

    # Bootstrap/refresco del grafo de código (graphify), si el proyecto lo
    # declara en mcp_servers. Idempotente: tools/sync-graph.sh se salta el
    # build si el sello .built-at-commit ya coincide con HEAD.
    if echo "$project" | jq -e '(.mcp_servers // []) | map(select(startswith("graphify"))) | length > 0' >/dev/null 2>&1; then
        if ! "$MATRIX_ROOT/tools/sync-graph.sh" "$BASE_PATH/$NAME"; then
            echo "   ⚠️  sync-graph.sh falló para $NAME — se sigue con el resto de la flota."
            FALLOS=$((FALLOS + 1))
        fi
    fi

    if [ "$ENABLED" = "true" ]; then
        echo "   🤖 Agente habilitado para $NAME (repositories.json: agent_enabled)."
    fi
done < <(jq -c '.projects[]' "$MANIFEST")

if [ "$FALLOS" -gt 0 ]; then
    echo "⚠️ Sincronización terminada con $FALLOS fallo(s) tolerados — revisa los mensajes de arriba."
    exit 1
fi

echo "✅ Sincronización completa."
