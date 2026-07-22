#!/bin/bash
# Script de aprovisionamiento de Servidor (Matriz) para Agentes de IA
set -e

echo "=== 🏭 Provisionando Máquina Matriz (Neuroon AI Factory) ==="

# 1. Configurar PATH local
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"

# 2. Instalar GitHub CLI (gh) si no existe
echo "Verificando dependencias del sistema..."
if ! command -v gh &> /dev/null; then
    echo "Descargando e instalando GitHub CLI (gh)..."
    GH_VERSION=$(curl -s "https://api.github.com/repos/cli/cli/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    curl -sSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" -o gh.tar.gz
    tar xzf gh.tar.gz
    mv gh_${GH_VERSION}_linux_amd64/bin/gh "$HOME/.local/bin/"
    rm -rf gh.tar.gz gh_${GH_VERSION}_linux_amd64
    echo "✅ GitHub CLI instalado. RECUERDA HACER: gh auth login"
else
    echo "✅ GitHub CLI ya está instalado."
fi

# 3. Validar runtimes de sistema requeridos por los proyectos
if ! command -v python3 &> /dev/null; then echo "⚠️ ADVERTENCIA: python3 no está instalado. Requerido para scripts."; fi
if ! command -v java &> /dev/null; then echo "⚠️ ADVERTENCIA: java (JDK 21) no está instalado. Requerido para backend Java."; fi
if ! command -v docker &> /dev/null; then echo "⚠️ ADVERTENCIA: docker no está instalado. Requerido para MCP Qdrant/BBDD."; fi

# 4. Instalar Claude Code CLI
if ! command -v claude &> /dev/null; then
    echo "Instalando Claude Code CLI..."
    # NPM 11+ bloquea postinstall scripts por defecto. Añadimos flags para permitir que Claude Code baje sus binarios y evitamos warnings.
    npm install -g @anthropic-ai/claude-code --foreground-scripts --audit=false --fund=false
    echo "✅ Claude Code instalado."
else
    echo "✅ Claude Code ya está instalado."
fi

# 5. Instalar RTK (Rust Token Killer)
if ! command -v rtk &> /dev/null; then
    echo "Instalando RTK (Rust Token Killer)..."
    curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
    echo "Configurando RTK para Claude Code..."
    yes | rtk init -g
    echo "✅ RTK instalado."
else
    echo "✅ RTK ya está instalado."
fi

# 6. Instalar Graphify (Grafo Semántico)
if ! command -v graphify &> /dev/null; then
    echo "Instalando Graphify..."
    
    # Instalación segura usando pipx (recomendado por PEP 668) o venv
    if ! command -v pipx &> /dev/null; then
        echo "🔧 Pipx no detectado. Intentando instalar mediante apt..."
        sudo apt update && sudo apt install -y pipx || true
    fi
    
    if command -v pipx &> /dev/null; then
        pipx ensurepath
        pipx install graphifyy
    else
        echo "⚠️ pipx no disponible. Creando entorno virtual aislado para Graphify..."
        python3 -m venv "$HOME/.graphify-env"
        "$HOME/.graphify-env/bin/pip" install graphifyy
        ln -sf "$HOME/.graphify-env/bin/graphify" "$HOME/.local/bin/graphify"
    fi
    echo "✅ Graphify instalado."
else
    echo "✅ Graphify ya está instalado."
fi

# 7. Instalar Claude-Mem (Memoria Persistente entre Sesiones)
# Se instala a nivel de usuario/máquina, no de proyecto. Da continuidad
# automática a CUALQUIER worker que arranquemos con claude-code.
echo "Instalando Claude-Mem (memoria persistente entre sesiones)..."
npx --yes claude-mem install || echo "⚠️ No se pudo instalar claude-mem automáticamente. Instálalo manualmente con: npx claude-mem install"
echo "✅ Claude-Mem configurado."

chmod +x install-factory.sh
echo "=========================================================="
echo "🎉 MÁQUINA APROVISIONADA."
echo "Para operar la matriz en esta máquina:"
echo "1. Haz login en GitHub: gh auth login"
echo "2. Haz login en Claude Pro: claude login"
echo "3. Usa ./deploy-worker.sh <nombre-del-repo-de-neuroon> para sincronizar un proyecto."
echo "=========================================================="
