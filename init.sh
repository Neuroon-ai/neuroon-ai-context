#!/bin/bash
# Init script para el repositorio Matriz (Context)
set -euo pipefail

echo "=== 🛡️  Harness Validation (Context Repo) ==="

# Validar que los scripts bash no tienen errores graves de sintaxis
# (Si no hay shellcheck instalado, avisa pero no falla)
if command -v shellcheck &> /dev/null; then
    echo "🔍 Verificando scripts con ShellCheck..."
    # nullglob evita que ./tools/*.sh quede como patrón literal sin expandir
    # (y reviente ShellCheck con "No such file") si tools/ no existe o está vacío.
    shopt -s nullglob
    SCRIPTS=(./*.sh ./tools/*.sh)
    shopt -u nullglob
    shellcheck "${SCRIPTS[@]}" || { echo "❌ Fallo en validación ShellCheck"; exit 1; }
    echo "✅ Scripts válidos."
else
    echo "⚠️ ShellCheck no está instalado. Correr ./install-factory.sh para instalarlo."
fi

# Validar que el manifiesto de repositorios es un JSON válido
if command -v jq &> /dev/null; then
    echo "🔍 Validando manifiesto de repositorios..."
    jq . repositories.json > /dev/null || { echo "❌ repositories.json es inválido"; exit 1; }
    echo "✅ repositories.json es válido."
else
    echo "⚠️ jq no está instalado. Omitiendo validación de repositories.json."
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

echo "✅ Línea base del repo Matriz en verde."
