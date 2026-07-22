#!/bin/bash
# Init script para el repositorio Matriz (Context)
set -e

echo "=== 🛡️  Harness Validation (Context Repo) ==="

# Validar que los scripts bash no tienen errores graves de sintaxis
# (Si no hay shellcheck instalado, avisa pero no falla)
if command -v shellcheck &> /dev/null; then
    echo "🔍 Verificando scripts con ShellCheck..."
    shellcheck *.sh || { echo "❌ Fallo en validación ShellCheck"; exit 1; }
    echo "✅ Scripts válidos."
else
    echo "⚠️ ShellCheck no está instalado. Omitiendo validación estricta de bash."
fi

# Validar que el manifiesto de repositorios es un JSON válido
if command -v jq &> /dev/null; then
    echo "🔍 Validando manifiesto de repositorios..."
    jq . repositories.json > /dev/null || { echo "❌ repositories.json es inválido"; exit 1; }
    echo "✅ repositories.json es válido."
fi

echo "✅ Línea base del repo Matriz en verde."
