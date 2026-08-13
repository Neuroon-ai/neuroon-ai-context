#!/bin/bash
# Sincroniza (clona o actualiza) todos los repositorios definidos en repositories.json
set -euo pipefail

MATRIX_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Raíz de DATOS (workspaces/), distinta de la raíz de CÓDIGO/config. Sin
# esto, ejecutar este script desde un git worktree secundario clonaba la
# flota ENTERA por segunda vez dentro del worktree (invisible en `git status`
# porque /workspaces/ está gitignorado) y además daba de alta cada proyecto
# de serena POR NOMBRE apuntando a esos clones duplicados, pisando el
# registro global de la máquina que usa .mcp.json.
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
# Una base_path con variables SIN expandir no empieza por "/" y se trataría
# como relativa, construyendo rutas del tipo $FLEET_ROOT/$HOME/... Mejor
# parar que clonar la flota en un sitio absurdo.
case "$BASE_PATH" in
    *\$*)
        echo "❌ base_path trae variables sin expandir ($BASE_PATH): instala gettext-base (./install-factory.sh)."
        exit 1
        ;;
esac
# Un base_path relativo es relativo a la raíz de DATOS de la Matriz, no al
# cwd ni al worktree: si no, correr el script desde otro sitio duplicaría la
# flota entera.
case "$BASE_PATH" in
    /*) ;;
    *) BASE_PATH="$FLEET_ROOT/${BASE_PATH#./}" ;;
esac

# Los fallos tolerados (un clon que no baja, un pull que no baja, un proyecto
# de serena que no se da de alta, un grafo que no se reconstruye) dejan
# seguir con el resto de la flota, pero se cuentan: terminar con fallos y
# decir "✅ completa" mentiría al operador. Sin process substitution
# (`< <(...)` al final del while) el contador se perdería: un `| while` corre
# en una subshell.
#
# NO_SINCRONIZADOS es distinto de FALLOS: dejar en paz un repo parado en una
# rama de trabajo es correcto y deliberado, pero anunciar "sincronización
# completa" después NO lo es — ese clon no refleja su default_branch.
FALLOS=0
NO_SINCRONIZADOS=0

echo "=== 🌐 Sincronizando Flota de Repositorios Neuroon ==="
echo "    Raíz de datos: $BASE_PATH"
mkdir -p "$BASE_PATH"

while read -r project; do
    NAME=$(echo "$project" | jq -r '.name')
    ENABLED=$(echo "$project" | jq -r '.agent_enabled')
    BRANCH=$(echo "$project" | jq -r '.default_branch // "main"')

    echo "➡️ Procesando: $NAME"

    if [ ! -d "$BASE_PATH/$NAME" ]; then
        echo "   Clonando $ORG/$NAME..."
        # Un clon fallido NO puede tumbar la sincronización del resto de la
        # flota: con `set -e`, la subshell abortaba el script entero, justo
        # lo contrario del modelo de fallos tolerados declarado arriba.
        if ! (cd "$BASE_PATH" && gh repo clone "$ORG/$NAME"); then
            echo "   ❌ Clonado de $ORG/$NAME falló — se sigue con el resto de la flota."
            FALLOS=$((FALLOS + 1))
            continue
        fi
    elif ! git -C "$BASE_PATH/$NAME" rev-parse --is-inside-work-tree &> /dev/null; then
        # El directorio existe pero no es un repo git válido (p. ej. un
        # "gh repo clone" anterior interrumpido a medias) — no dejar que
        # `git branch --show-current` reviente el script entero (set -e) y
        # tumbe la sincronización del resto de la flota.
        echo "   ⚠️  $BASE_PATH/$NAME existe pero no es un repositorio git válido — omitido (bórralo y vuelve a correr ./sync-fleet.sh para reclonarlo)."
        FALLOS=$((FALLOS + 1))
        continue
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
            echo "   ⚠️  $NAME está en la rama de trabajo '$CURRENT' (≠ $BRANCH) — no se toca, pero su clon NO refleja $BRANCH."
            NO_SINCRONIZADOS=$((NO_SINCRONIZADOS + 1))
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
        # Si el registro global NO existe, es IMPOSIBLE que el proyecto esté
        # dado de alta: antes esa rama caía al else y anunciaba un ✅.
        if [ ! -f "$SERENA_REG" ]; then
            echo "   ⚠️  $NAME tiene .serena/project.yml pero NO existe el registro de serena ($SERENA_REG): no se puede saber si está dado de alta (incógnita, no verde). Corre ./install-factory.sh."
            FALLOS=$((FALLOS + 1))
        # `-e` obligatorio: el patrón empieza por "- " y sin él grep se lo
        # come como si fuera una opción suya.
        elif ! grep -qxF -e "- $REPO_ABS" "$SERENA_REG"; then
            echo "   ⚠️  $NAME tiene .serena/project.yml pero NO está en el registro de serena ($SERENA_REG): el servidor serena-* que lo busca por nombre arrancará sin proyecto. Borra ese project.yml y vuelve a pasar por aquí."
            FALLOS=$((FALLOS + 1))
        else
            echo "   ✅ serena tiene el proyecto de $NAME registrado."
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
        # El rc se captura ASÍ y no con `if ! cmd; then rc=$?`: dentro de ese
        # then, $? es el del `!`, siempre 0.
        RC_GRAFO=0
        "$MATRIX_ROOT/tools/sync-graph.sh" "$BASE_PATH/$NAME" || RC_GRAFO=$?
        if [ "$RC_GRAFO" -ne 0 ]; then
            echo "   ⚠️  sync-graph.sh no dejó el grafo al día para $NAME (código $RC_GRAFO) — se sigue con el resto de la flota."
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

if [ "$NO_SINCRONIZADOS" -gt 0 ]; then
    echo "✅ Sincronización terminada SIN fallos, pero $NO_SINCRONIZADOS repo(s) NO se actualizaron por estar en una rama de trabajo — su clon no refleja su default_branch."
else
    echo "✅ Sincronización completa."
fi
