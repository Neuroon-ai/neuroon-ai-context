#!/bin/bash
# Init script para el repositorio Matriz (Context)
set -euo pipefail

# Valida SIEMPRE el árbol donde vive este script, no el cwd. Antes los globs
# (./*.sh) y `jq . repositories.json` eran relativos al directorio desde el
# que se invocara: llamarlo por ruta —que es justo lo que CLAUDE.md pide tras
# editar un script— validaba OTRO árbol y daba "línea base en verde" de algo
# que no había mirado.
cd "$(dirname "$0")" || exit 1

echo "=== 🛡️  Harness Validation (Context Repo) ==="
echo "Validando: $(pwd)"

# Comprobaciones que no se pudieron ejecutar por falta de herramientas. No es
# lo mismo "pasa" que "no lo he podido mirar": este script cerraba en verde
# en ambos casos.
OMITIDO=0

# Validar que los scripts bash no tienen errores graves de sintaxis
if command -v shellcheck &> /dev/null; then
    echo "🔍 Verificando scripts con ShellCheck..."
    # nullglob evita que ./tools/*.sh quede como patrón literal sin expandir
    # (y reviente ShellCheck con "No such file") si tools/ no existe o está
    # vacío. La inicialización explícita del array es obligatoria: con el
    # bash 3.2 de macOS y `set -u`, expandir "${SCRIPTS[@]}" de un array vacío
    # aborta con "unbound variable".
    shopt -s nullglob
    SCRIPTS=()
    SCRIPTS=(./*.sh ./tools/*.sh)
    shopt -u nullglob
    if [ "${#SCRIPTS[@]}" -eq 0 ]; then
        echo "⚠️ No se encontró ningún .sh que validar."
        OMITIDO=$((OMITIDO+1))
    else
        shellcheck "${SCRIPTS[@]}" || { echo "❌ Fallo en validación ShellCheck"; exit 1; }
        echo "✅ ${#SCRIPTS[@]} script(s) válidos."
    fi
else
    echo "⚠️ ShellCheck no está instalado. Correr ./install-factory.sh para instalarlo."
    OMITIDO=$((OMITIDO+1))
fi

# Validar TODOS los JSON versionados, no solo el manifiesto: un .mcp.json
# roto deja la sesión entera sin ningún MCP y sin decirlo, y CLAUDE.md ya
# promete que este script valida "la sintaxis de bash y JSON".
if command -v jq &> /dev/null; then
    echo "🔍 Validando JSON versionados..."
    # Un fichero versionado que NO está no se salta en silencio: saltarlo era
    # el mismo verde falso que este script existe para evitar (cerraba con
    # "línea base en verde" sin haber mirado lo que dice mirar).
    for f in repositories.json .mcp.json .claude/settings.json tools/gcloud-mcp-allow.json; do
        if [ -f "$f" ]; then
            jq . "$f" > /dev/null || { echo "❌ $f es inválido"; exit 1; }
            echo "   ✅ $f"
        else
            echo "   ❔ falta $f — no se puede validar (incógnita, no verde)"
            OMITIDO=$((OMITIDO+1))
        fi
    done
else
    echo "⚠️ jq no está instalado. Omitiendo validación de los JSON."
    OMITIDO=$((OMITIDO+1))
fi

# Validar que la identidad de Git está configurada (para que los commits de
# los agentes se identifiquen correctamente). Solo aviso, no bloquea ni pide input.
GIT_USER_NAME=$(git config --global user.name || true)
GIT_USER_EMAIL=$(git config --global user.email || true)
if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then
    echo "✅ Identidad de Git configurada: $GIT_USER_NAME <$GIT_USER_EMAIL>"
else
    echo "⚠️ Identidad de Git no configurada. Ejecuta ./install-factory.sh para configurarla."
fi

if [ "$OMITIDO" -gt 0 ]; then
    echo "❔ Línea base NO verificada: $OMITIDO comprobación(es) omitidas por falta de herramientas (correr ./install-factory.sh) — incógnita, no verde."
    exit 2
fi

echo "✅ Línea base del repo Matriz en verde."
