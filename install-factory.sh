#!/bin/bash
# Script de aprovisionamiento de Servidor (Matriz) para Agentes de IA — Neuroon
#
# Filosofía: idempotente, resiliente y auto-reparable. Cada paso comprueba si
# la herramienta no solo existe sino que responde de verdad (--version) antes
# de decidir instalar, actualizar o reparar. Un fallo puntual no tumba el
# resto del aprovisionamiento — se acumula y se reporta al final. `set -e`
# sigue activo (falla rápido ante bugs de programación); los fallos
# *esperables* de cada paso se contienen explícitamente con `if`.
set -euo pipefail

# Nunca correr como root / con `sudo` delante de todo el script: todo lo que
# instala este script (Node.js, Claude Code CLI, RTK, Graphify, Claude-Mem,
# identidad de Git) debe vivir en el $HOME del usuario real de la máquina.
# Ejecutado con sudo por delante, TODO acaba bajo /root en vez del usuario
# real — invisible e inútil en cualquier sesión normal. El script ya pide
# sudo internamente (una sola vez, ver detección de HAS_SUDO más abajo) solo
# para los dos pasos que de verdad lo necesitan (apt-get de Node.js/pipx).
if [ "$(id -u)" -eq 0 ]; then
    echo "❌ No ejecutes este script como root ni con 'sudo ./install-factory.sh'."
    echo "   Ejecútalo como tu usuario normal: ./install-factory.sh"
    echo "   Pedirá la contraseña de sudo una única vez, solo para los pasos"
    echo "   que de verdad la necesitan (instalar Node.js/pipx vía apt)."
    exit 1
fi

STEPS_OK=()
STEPS_FAILED=()

ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
info() { echo "🔧 $*"; }

# Reintenta un comando hasta 3 veces con backoff simple. Para descargas de
# red que pueden fallar de forma transitoria.
retry() {
    local attempts=3 delay=2 n=1
    until "$@"; do
        if (( n >= attempts )); then
            return 1
        fi
        warn "Intento $n/$attempts falló (${*}). Reintentando en ${delay}s..."
        sleep "$delay"
        n=$((n + 1))
        delay=$((delay * 2))
    done
}

# Comprueba que un binario no solo está en PATH sino que responde.
binary_healthy() {
    local bin="$1" flag="${2:---version}"
    command -v "$bin" &> /dev/null && "$bin" "$flag" &> /dev/null
}

# Último tag de un repo de GitHub, sin depender de jq (se usa antes de que
# jq exista). OJO: la API devuelve el JSON minificado en UNA línea — un
# grep de línea entera + sed greedy coge la última cadena del documento. La
# combinación grep -o + head -1 extrae solo el campo tag_name, venga el JSON
# minificado o pretty-printed.
latest_github_tag() {
    local repo="$1"
    curl -s "https://api.github.com/repos/${repo}/releases/latest" \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/'
}

echo "=== 🏭 Provisionando Máquina Matriz (Neuroon Factory) ==="

# Resuelto por ubicación del script, no por cwd: así configure_claude_mcp_approval
# encuentra repositories.json aunque el script se invoque desde otro directorio
# (ruta absoluta, symlink, cron...) — mismo patrón que MATRIX_ROOT en deploy-worker.sh.
MATRIX_ROOT="$(cd "$(dirname "$0")" && pwd)"

# --- PATH local ---
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"

# --- Detección de sudo (sin bloquear en entornos no interactivos/sin password) ---
HAS_SUDO=false
if command -v sudo &> /dev/null; then
    if sudo -n true 2>/dev/null; then
        HAS_SUDO=true
    elif [ -t 0 ]; then
        # Interactivo: un único prompt al principio, no uno por paso.
        sudo -v 2>/dev/null && HAS_SUDO=true
    fi
fi
[ "$HAS_SUDO" = true ] || warn "Sin acceso a sudo (sin password y no interactivo, o no disponible). Los pasos que lo requieran quedarán pendientes."

# --- GitHub CLI (gh): instala o actualiza a la última release ---
install_gh() {
    local latest current
    latest=$(latest_github_tag "cli/cli" | sed 's/^v//')
    if [ -z "$latest" ]; then
        warn "No se pudo consultar la última versión de gh (¿sin red?)."
        binary_healthy gh && { ok "GitHub CLI ya instalado (versión no verificable contra latest)."; return 0; }
        return 1
    fi

    if binary_healthy gh; then
        current=$(gh --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ "$current" = "$latest" ]; then
            ok "GitHub CLI ya está al día (v$current)."
            return 0
        fi
        info "Actualizando GitHub CLI (v$current -> v$latest)..."
    else
        info "Instalando GitHub CLI v$latest..."
    fi

    # Directorio temporal único (mktemp -d) en vez de nombres fijos en /tmp:
    # en una máquina compartida, un nombre predecible (/tmp/gh.tar.gz) es
    # aprovechable vía symlink preplantado por otro usuario local.
    local tmpdir; tmpdir="$(mktemp -d)"
    retry curl -sSL "https://github.com/cli/cli/releases/download/v${latest}/gh_${latest}_linux_amd64.tar.gz" -o "$tmpdir/gh.tar.gz" || { rm -rf "$tmpdir"; return 1; }
    tar xzf "$tmpdir/gh.tar.gz" -C "$tmpdir"
    mv "$tmpdir/gh_${latest}_linux_amd64/bin/gh" "$HOME/.local/bin/"
    rm -rf "$tmpdir"
    binary_healthy gh || { warn "gh instalado pero no responde a --version."; return 1; }
    ok "GitHub CLI v$latest listo. RECUERDA HACER: gh auth login"
}

# --- jq: requisito duro de la fábrica (repositories.json es la fuente de
# verdad y casi todos los scripts lo parsean con jq). Binario estático
# oficial a ~/.local/bin — sin sudo, coherente con el resto del script. ---
install_jq() {
    if binary_healthy jq; then
        ok "jq ya está instalado ($(jq --version 2>/dev/null))."
        return 0
    fi
    local latest
    latest=$(latest_github_tag "jqlang/jq")
    if [ -z "$latest" ]; then
        warn "No se pudo consultar la última versión de jq (¿sin red?)."
        return 1
    fi
    info "Instalando jq ($latest, binario estático, sin sudo)..."
    retry curl -fsSL "https://github.com/jqlang/jq/releases/download/${latest}/jq-linux-amd64" -o "$HOME/.local/bin/jq" || return 1
    chmod +x "$HOME/.local/bin/jq"
    binary_healthy jq || { warn "jq instalado pero no responde a --version."; return 1; }
    ok "jq instalado ($(jq --version 2>/dev/null))."
}

# --- ShellCheck: CLAUDE.md ordena validar todo .sh tras modificarlo; sin el
# binario, esa regla degrada a warning silencioso en máquina nueva. Binario
# estático oficial a ~/.local/bin — sin sudo. ---
install_shellcheck() {
    if binary_healthy shellcheck; then
        ok "ShellCheck ya está instalado ($(shellcheck --version 2>/dev/null | grep '^version' | head -1))."
        return 0
    fi
    local latest
    latest=$(latest_github_tag "koalaman/shellcheck")
    if [ -z "$latest" ]; then
        warn "No se pudo consultar la última versión de ShellCheck (¿sin red?)."
        return 1
    fi
    info "Instalando ShellCheck ($latest, binario estático, sin sudo)..."
    local tmpdir; tmpdir="$(mktemp -d)"
    retry curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/${latest}/shellcheck-${latest}.linux.x86_64.tar.xz" -o "$tmpdir/shellcheck.tar.xz" || { rm -rf "$tmpdir"; return 1; }
    tar -xf "$tmpdir/shellcheck.tar.xz" -C "$tmpdir"
    mv "$tmpdir/shellcheck-${latest}/shellcheck" "$HOME/.local/bin/"
    rm -rf "$tmpdir"
    binary_healthy shellcheck || { warn "ShellCheck instalado pero no responde a --version."; return 1; }
    ok "ShellCheck instalado ($(shellcheck --version 2>/dev/null | grep '^version' | head -1))."
}

# --- envsubst: lo usa sync-fleet.sh para expandir base_path. Viene en
# gettext-base (apt); no hay binario estático oficial razonable, así que
# solo se instala si hay sudo, y si no, se avisa. ---
install_envsubst() {
    if command -v envsubst &> /dev/null; then
        ok "envsubst ya está instalado."
        return 0
    fi
    if [ "$HAS_SUDO" = true ]; then
        info "Instalando envsubst (gettext-base) vía apt..."
        sudo apt-get install -y gettext-base
        command -v envsubst &> /dev/null || { warn "envsubst no quedó disponible."; return 1; }
        ok "envsubst instalado."
    else
        warn "envsubst no está instalado y no hay sudo (sync-fleet.sh lo necesita). Instala gettext-base cuando puedas."
        return 1
    fi
}

# --- Node.js: vía nvm, NUNCA vía apt/NodeSource ---
# Un Node instalado a nivel de sistema (apt/NodeSource) deja el prefix global
# de npm bajo /usr, propiedad de root — cualquier `npm install -g` posterior
# como usuario normal revienta con EACCES. nvm instala todo bajo $HOME: cero
# sudo, cero EACCES, y de regalo elimina la única razón por la que este
# script necesitaba sudo en absoluto.
NVM_VERSION="v0.40.6"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

load_nvm() {
    [ -s "$NVM_DIR/nvm.sh" ] || return 1
    # nvm.sh no es 100% compatible con `set -u` (variables internas pueden
    # quedar sin definir según la versión). Se restaura siempre al terminar
    # la función que llama a load_nvm, nunca dentro de un `return` temprano.
    # shellcheck disable=SC1091  # nvm.sh es externo, no auditable por shellcheck
    \. "$NVM_DIR/nvm.sh"
}

# Si el node activo es el del SISTEMA (prefix global /usr, de root), cualquier
# `npm install -g` de usuario falla con EACCES. Fix estándar de npm sin sudo:
# prefix de usuario en ~/.npmrc apuntando a ~/.local (ya está en el PATH).
# Solo aplica cuando NO gestiona nvm el node (nvm ya instala bajo $HOME).
ensure_user_npm_prefix() {
    command -v npm &> /dev/null || return 0
    local gprefix
    gprefix="$(npm prefix -g 2>/dev/null || true)"
    case "$gprefix" in
        "$HOME"*) return 0 ;;  # ya es de usuario (nvm o prefix propio)
    esac
    if [ ! -w "$gprefix/lib/node_modules" ] 2>/dev/null || [ ! -w "$gprefix/bin" ] 2>/dev/null; then
        info "npm global apunta a $gprefix (de root) — configurando prefix de usuario en ~/.local..."
        npm config set prefix "$HOME/.local"
        ok "npm prefix de usuario configurado (~/.npmrc): los install -g van a ~/.local/bin sin sudo."
    fi
}

install_node() {
    set +u
    load_nvm

    if binary_healthy node; then
        ok "Node.js ya está instalado ($(node --version))."
        ensure_user_npm_prefix
        info "Comprobando actualizaciones de Node.js (LTS)..."
        nvm install --lts &> /dev/null || true
        nvm alias default 'lts/*' &> /dev/null || true
        set -u
        binary_healthy node || { warn "Node.js dejó de responder tras comprobar actualizaciones."; return 1; }
        return 0
    fi

    local rc=0
    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
        info "Instalando nvm (Node Version Manager) ${NVM_VERSION}..."
        set -u
        local nvm_installer; nvm_installer="$(mktemp)"
        if ! retry curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" -o "$nvm_installer"; then
            rc=1
        else
            bash "$nvm_installer"
        fi
        rm -f "$nvm_installer"
        set +u
        [ "$rc" -eq 0 ] && load_nvm
    fi

    if [ "$rc" -eq 0 ]; then
        if ! command -v nvm &> /dev/null; then
            warn "nvm no quedó disponible tras la instalación."
            rc=1
        else
            info "Instalando Node.js LTS vía nvm..."
            nvm install --lts
            nvm alias default 'lts/*'
        fi
    fi
    set -u

    [ "$rc" -eq 0 ] || return 1
    binary_healthy node || { warn "Node.js instalado vía nvm pero no responde a --version."; return 1; }
    ok "Node.js instalado vía nvm: $(node --version)"
}

# --- Claude Code CLI: compara contra la última versión publicada antes de
# tocar nada (mismo patrón que gh) — si ya está al día, no ejecuta npm install ---
install_claude_code() {
    if ! command -v npm &> /dev/null; then
        warn "npm no disponible. Omitiendo Claude Code CLI (depende de Node.js, ver paso anterior)."
        return 1
    fi

    local latest current
    latest=$(npm view @anthropic-ai/claude-code version 2>/dev/null || true)

    if binary_healthy claude; then
        current=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ -n "$latest" ] && [ "$current" = "$latest" ]; then
            ok "Claude Code CLI ya está al día (v$current)."
            return 0
        fi
        info "Actualizando Claude Code CLI (v${current:-?} -> v${latest:-latest})..."
    else
        info "Instalando Claude Code CLI (v${latest:-latest})..."
    fi

    # NPM 11+ bloquea postinstall scripts por defecto. Añadimos flags para
    # permitir que Claude Code baje sus binarios y evitamos warnings.
    npm install -g @anthropic-ai/claude-code --foreground-scripts --audit=false --fund=false
    binary_healthy claude || { warn "Claude Code CLI instalado pero no responde a --version."; return 1; }
    ok "Claude Code CLI al día ($(claude --version 2>/dev/null))."
}

# --- RTK (Rust Token Killer): comprueba versión antes de re-descargar ---
install_rtk() {
    local had_rtk=false
    binary_healthy rtk && had_rtk=true

    local current="" latest=""
    if [ "$had_rtk" = true ]; then
        current=$(rtk --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        latest=$(curl -s "https://api.github.com/repos/rtk-ai/rtk/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
        if [ -n "$latest" ] && [ "$current" = "$latest" ]; then
            ok "RTK ya está al día (v$current)."
            return 0
        fi
        if [ -z "$latest" ]; then
            # Mismo patrón que install_gh: si no se pudo consultar la última
            # versión (¿rate-limit de la API de GitHub, sin red?) pero RTK ya
            # está instalado y operativo, no lo reinstalamos a ciegas.
            warn "No se pudo consultar la última versión de RTK (¿sin red o rate-limit?). RTK ya instalado (v$current) — se deja como está."
            return 0
        fi
        info "Actualizando RTK (v${current:-?} -> v${latest:-latest})..."
    else
        info "Instalando RTK..."
    fi

    local rtk_installer; rtk_installer="$(mktemp)"
    retry curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh -o "$rtk_installer" || { rm -f "$rtk_installer"; return 1; }
    sh "$rtk_installer"
    rm -f "$rtk_installer"

    binary_healthy rtk || { warn "RTK no quedó disponible/operativo tras la instalación."; return 1; }

    if [ "$had_rtk" = false ]; then
        info "Configurando RTK para Claude Code..."
        # En shells no interactivos, rtk degrada solo (imprime el paso manual
        # y sigue) pero el pipe con `yes` recibe SIGPIPE al cerrarse rtk ->
        # pipefail lo marcaría como fallo del script entero. Toleramos esto.
        yes | rtk init -g || true
    fi
    ok "RTK instalado/actualizado ($(rtk --version 2>/dev/null))."
}

# --- Graphify (Grafo Semántico): auto-reparación de instalaciones pipx corruptas ---
install_graphify() {
    if ! command -v pipx &> /dev/null; then
        info "pipx no detectado. Instalando mediante apt..."
        if [ "$HAS_SUDO" = true ]; then
            sudo apt-get update && sudo apt-get install -y pipx || true
        fi
    fi

    if command -v pipx &> /dev/null; then
        pipx ensurepath &> /dev/null || true

        # Auto-reparación: una instalación pipx interrumpida a medias deja
        # metadata corrupta que pipx reporta explícitamente. La detectamos y
        # reinstalamos desde cero en vez de dejar el paso a medias.
        if pipx list 2>&1 | grep -q "graphifyy has missing internal pipx metadata"; then
            warn "Instalación de Graphify corrupta detectada. Reparando (reinstalación limpia)..."
            rm -rf "$HOME/.local/share/pipx/venvs/graphifyy"
        fi

        if binary_healthy graphify; then
            if binary_healthy graphify-mcp --help; then
                info "Graphify ya instalado. Comprobando actualizaciones..."
                pipx upgrade graphifyy || true
            else
                # graphify-mcp existe como comando pero falla al arrancar de
                # verdad si falta el extra [mcp] (ModuleNotFoundError: mcp) —
                # --help no lo detecta porque no llega a importar el módulo.
                warn "Graphify instalado sin el extra [mcp] (necesario para el servidor MCP). Reinstalando con el extra..."
                pipx install "graphifyy[mcp]" --force
            fi
        else
            info "Instalando Graphify (con extra [mcp] para el servidor graphify-mcp)..."
            pipx install "graphifyy[mcp]"
        fi
    elif binary_healthy graphify && binary_healthy graphify-mcp --help; then
        ok "Graphify ya operativo vía venv aislado (sin pipx) — se omite la reinstalación."
    else
        warn "pipx no disponible. Creando entorno virtual aislado para Graphify..."
        python3 -m venv "$HOME/.graphify-env"
        "$HOME/.graphify-env/bin/pip" install --upgrade "graphifyy[mcp]"
        ln -sf "$HOME/.graphify-env/bin/graphify" "$HOME/.local/bin/graphify"
        ln -sf "$HOME/.graphify-env/bin/graphify-mcp" "$HOME/.local/bin/graphify-mcp"
    fi

    binary_healthy graphify || { warn "Graphify no quedó operativo en el PATH."; return 1; }
    ok "Graphify instalado/actualizado ($(graphify --version 2>/dev/null))."
}

# --- OpenSpec (spec-driven development para el rol Planner) ---
# Versión FIJADA a propósito: subir de versión es una decisión consciente
# (cambiar el pin + correr `openspec update` en cada repo de la flota), nunca
# un drive-by.
OPENSPEC_PIN="1.6.0"
install_openspec() {
    if ! command -v npm &> /dev/null; then
        warn "npm no disponible. Omitiendo OpenSpec (depende de Node.js)."
        return 1
    fi
    local current=""
    if command -v openspec &> /dev/null; then
        current=$(openspec --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    if [ "$current" = "$OPENSPEC_PIN" ]; then
        ok "OpenSpec ya está en la versión fijada (v$OPENSPEC_PIN)."
        return 0
    fi
    info "Instalando OpenSpec v$OPENSPEC_PIN (pinned)${current:+ — actual: v$current}..."
    npm install -g "@fission-ai/openspec@$OPENSPEC_PIN" --audit=false --fund=false
    command -v openspec &> /dev/null || { warn "OpenSpec no quedó disponible en el PATH."; return 1; }
    ok "OpenSpec v$(openspec --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) listo."
}

# --- Claude-Mem (memoria persistente entre sesiones, a nivel de máquina) ---
install_claude_mem() {
    if ! command -v npx &> /dev/null; then
        warn "npx no disponible (depende de Node.js). Omitiendo Claude-Mem."
        return 1
    fi

    # El propio instalador de claude-mem NO es idempotente de verdad: aunque
    # ya esté en la última versión, un `claude-mem install` repetido revalida
    # Bun/uv y vuelve a correr `bun install` + `npm install` completos. Nos
    # ahorramos esa pasada comparando su propio marcador de versión (que sí
    # escribe en disco) contra el registry ANTES de invocarlo.
    local marker="$HOME/.claude/plugins/marketplaces/thedotmack/.install-version"
    local installed="" latest=""
    if [ -f "$marker" ]; then
        # node en vez de python3 para leer el marcador: node ya es una
        # dependencia dura de este mismo paso (npx lo requiere), así que no
        # añade ninguna dependencia nueva — a diferencia de python3, que
        # install-factory.sh solo verifica con un warning, nunca instala.
        installed=$(node -e "
try {
  const fs = require('fs');
  console.log(JSON.parse(fs.readFileSync(process.argv[1], 'utf8')).version || '');
} catch { /* deja installed vacío */ }
" "$marker" 2>/dev/null || true)
    fi
    latest=$(npm view claude-mem version 2>/dev/null || true)

    if [ -n "$installed" ] && [ -n "$latest" ] && [ "$installed" = "$latest" ]; then
        ok "Claude-Mem ya está al día (v$installed) — se omite la reinstalación completa."
        return 0
    fi

    info "Instalando/actualizando Claude-Mem (v${installed:-ninguna} -> v${latest:-latest})..."
    # Algunas versiones de claude-mem tienen conflictos de peerDependencies en
    # sus propias devDependencies (grammars de tree-sitter con rangos que no
    # se solapan). En vez de depender del reintento automático del instalador
    # de plugins de Claude Code, lo forzamos aquí de forma explícita.
    npm_config_legacy_peer_deps=true npx --yes claude-mem install
    ok "Claude-Mem configurado."
}

# --- Identidad de Git para los commits de los agentes de esta máquina ---
# Así los commits de los workers se identifican con nombre + soporte@neuroon.ai
# en vez de la identidad personal de quien aprovisionó la máquina.
configure_git_identity() {
    local git_name git_email
    git_name=$(git config --global user.name || true)
    git_email=$(git config --global user.email || true)

    if [ -n "$git_name" ] && [ -n "$git_email" ]; then
        ok "Identidad de Git ya configurada: $git_name <$git_email>"
        return 0
    fi

    local agent_name="$git_name"
    if [ -z "$agent_name" ] && [ -t 0 ]; then
        read -r -p "Nombre para los commits de los agentes de esta máquina (Enter para generar uno aleatorio): " agent_name
    fi
    if [ -z "$agent_name" ]; then
        local starwars_names=(
            "Jar Jar Binks" "Grogu" "BB-8" "R2-D2" "C-3PO" "Chewbacca"
            "Wicket el Ewok" "Admiral Ackbar" "Babu Frik" "Nien Nunb"
            "Salacious Crumb" "Watto" "Greedo" "Porg"
        )
        agent_name="${starwars_names[$RANDOM % ${#starwars_names[@]}]}"
        info "No se introdujo nombre. Usando identidad generada: $agent_name"
    fi
    git config --global user.name "$agent_name"
    git config --global user.email "soporte@neuroon.ai"
    ok "Identidad de Git configurada: $agent_name <soporte@neuroon.ai>"
}

# --- Pre-aprobación de servidores MCP de la flota, según repositories.json ---
# Claude Code exige aprobar a mano cada servidor MCP que un .mcp.json de
# proyecto declare, y por diseño de seguridad esa aprobación NUNCA puede
# venir de un fichero commiteado en el propio repo clonado. La única vía que
# sí aplica en una carpeta recién clonada es la config de usuario
# (~/.claude/settings.json). Por eso vive aquí (una vez por máquina) y no en
# cada repo: así "clonar + lanzar el worker" basta, sin que nadie tenga que
# aprobar nada a mano cada vez.
#
# La lista a aprobar NO está hardcodeada aquí: se calcula como la unión de
# los `mcp_servers` que cada proyecto declara en repositories.json (fuente
# de verdad de la flota). Añadir un MCP nuevo a un proyecto + volver a correr
# este script basta — nada que tocar a mano en dos sitios.
#
# NOTA: esto SOLO añade, nunca quita. Es intencional (no un descuido): si un
# humano borrara un servidor a mano de enabledMcpjsonServers, un re-run lo
# volvería a añadir mientras siga declarado en repositories.json — porque
# repositories.json, no el settings.json local, es la Verdad Absoluta de qué
# MCPs están sancionados para la flota. Para retirar un MCP de verdad, quítalo
# de mcp_servers en repositories.json (y opcionalmente bórralo a mano de
# enabledMcpjsonServers una vez).
configure_claude_mcp_approval() {
    local settings="$HOME/.claude/settings.json"
    mkdir -p "$(dirname "$settings")"
    [ -f "$settings" ] || echo '{}' > "$settings"

    if ! command -v jq &> /dev/null; then
        warn "jq no disponible; no se pudo pre-aprobar servidores MCP en $settings."
        return 1
    fi

    if ! jq empty "$settings" &> /dev/null; then
        warn "$settings no es JSON válido; no se toca (revísalo a mano)."
        return 1
    fi

    # Resuelto por ubicación del script (MATRIX_ROOT), no por cwd: así este
    # paso funciona igual si install-factory.sh se relanza desde otro
    # directorio (idempotencia real, no solo "si estás en el sitio correcto").
    local manifest="$MATRIX_ROOT/repositories.json"
    if [ ! -f "$manifest" ]; then
        warn "repositories.json no encontrado en $MATRIX_ROOT; no se pudo calcular qué servidores MCP pre-aprobar."
        return 1
    fi

    local servers
    servers=$(jq -c '[.projects[].mcp_servers[]?] | unique' "$manifest" 2>/dev/null || echo '[]')
    if [ "$servers" = "[]" ]; then
        ok "repositories.json no declara servidores MCP todavía — nada que pre-aprobar."
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    jq --argjson servers "$servers" \
       '.enabledMcpjsonServers = (((.enabledMcpjsonServers // []) + $servers) | unique)' \
       "$settings" > "$tmp" && mv "$tmp" "$settings"
    ok "Servidores MCP pre-aprobados en $settings: $servers"
}

# --- Runtimes que solo verificamos (instalarlos a ciegas sería demasiado
# invasivo/específico de infra: JDK, Docker) ---
check_readonly_runtimes() {
    command -v python3 &> /dev/null || warn "python3 no está instalado. Requerido para api-search-engine."
    command -v java &> /dev/null   || warn "java (JDK) no está instalado. Requerido para el backend Java (api-search-neuroon, usa Maven/mvnw)."
    command -v docker &> /dev/null || warn "docker no está instalado. Requerido para MCP Qdrant/BBDD."
}

# === Orquestación ===
# Cada paso corre dentro de un `if` para que su fallo no dispare `set -e` y
# tumbe el resto — se registra en STEPS_FAILED y seguimos con el siguiente.
run_step() {
    local name="$1"; shift
    if "$@"; then
        STEPS_OK+=("$name")
    else
        STEPS_FAILED+=("$name")
    fi
}

check_readonly_runtimes
run_step "gh CLI"        install_gh
run_step "jq"            install_jq
run_step "ShellCheck"    install_shellcheck
run_step "envsubst"      install_envsubst
run_step "Node.js"       install_node
run_step "Claude Code"   install_claude_code
run_step "RTK"           install_rtk
run_step "Graphify"      install_graphify
run_step "OpenSpec"      install_openspec
run_step "Claude-Mem"    install_claude_mem
run_step "Identidad Git" configure_git_identity
run_step "Aprobación MCP" configure_claude_mcp_approval

echo "=========================================================="
echo "🎉 APROVISIONAMIENTO COMPLETADO"
[ "${#STEPS_OK[@]}" -gt 0 ] && echo "✅ OK: ${STEPS_OK[*]}"
if [ "${#STEPS_FAILED[@]}" -gt 0 ]; then
    echo "⚠️  Pendiente/fallido (revisar avisos arriba): ${STEPS_FAILED[*]}"
fi
echo ""
echo "Para operar la matriz en esta máquina:"
echo "1. Haz login en GitHub: gh auth login"
echo "2. Haz login en Claude Pro: claude login"
echo "3. Sincroniza la flota: ./sync-fleet.sh"
echo "4. Arranca un worker: ./deploy-worker.sh <nombre-del-repo>"
echo "=========================================================="
