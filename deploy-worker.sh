#!/bin/bash
# Despliega un repositorio y prepara al agente Worker para operar sobre él.
# Uso: ./deploy-worker.sh <nombre-repo> [--yes]
#   --yes  acepta automáticamente los pasos y/N (para ejecución no interactiva).
set -euo pipefail

REPO_NAME=""
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -*) echo "❌ Flag desconocido: $arg"; exit 1 ;;
    *) REPO_NAME="$arg" ;;
  esac
done

if [ -z "$REPO_NAME" ]; then
  echo "❌ Error: Debes indicar el nombre del repositorio a desplegar."
  echo "Uso: ./deploy-worker.sh api-search-neuroon [--yes]"
  exit 1
fi

MATRIX_ROOT="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$MATRIX_ROOT/repositories.json"

command -v jq >/dev/null 2>&1 || { echo "❌ jq no está instalado (correr ./install-factory.sh)."; exit 1; }
[ -f "$MANIFEST" ] || { echo "❌ No existe $MANIFEST"; exit 1; }

# base_path viene de repositories.json (misma fuente que sync-fleet.sh) para
# que ambos scripts SIEMPRE coincidan en dónde vive la flota, aunque cambie.
RAW_BASE_PATH=$(jq -r '.base_path' "$MANIFEST")
if command -v envsubst &> /dev/null; then
  BASE_PATH_EXPANDED=$(echo "$RAW_BASE_PATH" | envsubst)
else
  BASE_PATH_EXPANDED="$RAW_BASE_PATH"
fi
case "$BASE_PATH_EXPANDED" in
  /*) WORKSPACES_DIR="$BASE_PATH_EXPANDED" ;;
  *) WORKSPACES_DIR="$MATRIX_ROOT/${BASE_PATH_EXPANDED#./}" ;;
esac
WORK_DIR="$WORKSPACES_DIR/$REPO_NAME"

# repositories.json es la Verdad Absoluta de la flota: el repo debe estar
# declarado y con agent_enabled=true para poder desplegarle un worker.
PROJECT_JSON=$(jq -c --arg n "$REPO_NAME" '.projects[] | select(.name==$n)' "$MANIFEST")
if [ -z "$PROJECT_JSON" ]; then
  echo "❌ '$REPO_NAME' no está declarado en repositories.json — regístralo ahí primero."
  exit 1
fi
if [ "$(echo "$PROJECT_JSON" | jq -r '.agent_enabled')" != "true" ]; then
  echo "❌ '$REPO_NAME' tiene agent_enabled=false en repositories.json — no se despliega worker."
  echo "   (Cambia el flag en repositories.json si de verdad quieres habilitarlo.)"
  exit 1
fi
ORG=$(jq -r '.org' "$MANIFEST")
DEFAULT_BRANCH=$(echo "$PROJECT_JSON" | jq -r '.default_branch // "main"')

# Pregunta y/N respetando --yes y la ausencia de TTY: sin terminal humana y
# sin --yes, la respuesta es N con aviso (nunca colgarse ni morir por EOF).
confirm() {
  local prompt="$1" ans
  if [ "$ASSUME_YES" -eq 1 ]; then
    echo "   (--yes) $prompt → sí"
    return 0
  fi
  if [ ! -t 0 ]; then
    echo "   (sin TTY) $prompt → omitido (usa --yes para aceptarlo en ejecución no interactiva)"
    return 1
  fi
  read -r -p "$prompt [y/N] " ans
  case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac
}

echo "=== 🚀 Desplegando Worker para $REPO_NAME ==="

mkdir -p "$WORKSPACES_DIR"
cd "$WORKSPACES_DIR"

# Clonar si no existe, hacer pull si existe — pero NUNCA tocar una rama de
# trabajo: solo se hace pull si el repo está en su default_branch.
if [ ! -d "$REPO_NAME" ]; then
  gh repo clone "$ORG/$REPO_NAME"
elif ! git -C "$REPO_NAME" rev-parse --is-inside-work-tree &> /dev/null; then
  # El directorio existe pero no es un repo git válido (p. ej. un
  # "gh repo clone" anterior interrumpido a medias) — no dejar que
  # `git branch --show-current` reviente el script con set -e.
  echo "⚠️  $REPO_NAME existe en $WORKSPACES_DIR pero no es un repositorio git válido."
  echo "   Bórralo y vuelve a correr ./deploy-worker.sh $REPO_NAME para reclonarlo."
  exit 1
else
  CURRENT_BRANCH="$(git -C "$REPO_NAME" branch --show-current)"
  if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
    (cd "$REPO_NAME" && git pull origin "$DEFAULT_BRANCH")
  else
    echo "⚠️  $REPO_NAME está en la rama de trabajo '$CURRENT_BRANCH' (≠ $DEFAULT_BRANCH) — no se hace pull para no tocarla."
  fi
fi

cd "$REPO_NAME"

# ¿Falta el arnés? Confirmación explícita del humano — nunca automático,
# porque crear ficheros es una acción que debe verse, no una decisión
# silenciosa de un script.
HARNESS_MISSING=0
for f in feature_list.json claude-progress.md init.sh .gitignore; do
  [ -f "$f" ] || HARNESS_MISSING=1
done
if [ ! -f "AGENTS.md" ] && [ ! -f "CLAUDE.md" ]; then HARNESS_MISSING=1; fi

if [ "$HARNESS_MISSING" -eq 1 ]; then
  echo ""
  echo "⚠️  Este repo no tiene el arnés completo todavía."
  if confirm "¿Generar el esqueleto ahora con scaffold-harness.sh?"; then
    "$MATRIX_ROOT/tools/scaffold-harness.sh" --target "$WORK_DIR" --default-branch "$DEFAULT_BRANCH"
  else
    echo "   Omitido. El worker puede seguir sin arnés completo (no recomendado)."
  fi
fi

# ¿Falta el grafo de código (graphify) o sus hooks de auto-actualización?
# Bootstrap de una sola vez — mismo principio que el arnés: instalar cosas
# es una acción que debe verse, nunca una decisión silenciosa de un script.
GRAPH_MISSING=0
[ -f "graphify-out/graph.json" ] || GRAPH_MISSING=1
if command -v graphify &>/dev/null && graphify hook status 2>/dev/null | grep -q "not installed"; then
  GRAPH_MISSING=1
fi

if [ "$GRAPH_MISSING" -eq 1 ]; then
  echo ""
  echo "🕸️  El grafo de código (graphify-out/graph.json) no existe o sus hooks de auto-actualización no están instalados."
  if confirm "¿Hacer el bootstrap ahora con sync-graph.sh?"; then
    "$MATRIX_ROOT/tools/sync-graph.sh" "$WORK_DIR"
  else
    echo "   Omitido. El worker puede seguir sin grafo de código (no recomendado)."
  fi
fi

# Sincroniza .mcp.json contra lo declarado en repositories.json (fuente de
# verdad de qué MCPs necesita este repo). A diferencia del arnés/grafo, esto
# es automático (sin y/N): es una sincronización declarativa e idempotente
# desde una plantilla propia de la Matriz, no la instalación de algo nuevo.
"$MATRIX_ROOT/tools/scaffold-mcp.sh" "$REPO_NAME" --target "$WORK_DIR"

# Auditar y mostrar el resultado (informativo, no bloquea el despliegue: el
# humano decide si lanza al worker igualmente aunque haya CRITICAL en rojo).
echo ""
echo "🔍 Auditando arnés..."
if "$MATRIX_ROOT/tools/audit-harness.sh" "$WORK_DIR"; then
  AUDIT_OK=1
else
  AUDIT_OK=0
fi

# Renderizar el worker-prompt versionado (templates/worker-prompt.md) con el
# contexto de este repo. Se guarda FUERA del repo target, en .prompts dentro
# de $WORKSPACES_DIR (ya cubierto por /workspaces/ en .gitignore cuando
# base_path es el valor por defecto), para no ensuciar el git status del
# repo target.
PROMPTS_DIR="$WORKSPACES_DIR/.prompts"
mkdir -p "$PROMPTS_DIR"
RENDERED="$PROMPTS_DIR/${REPO_NAME}-worker-prompt.md"
sed \
  -e "s/{{REPO_NAME}}/$REPO_NAME/g" \
  -e "s/{{DATE}}/$(date +%F)/g" \
  "$MATRIX_ROOT/templates/worker-prompt.md" > "$RENDERED"

echo ""
echo "✅ Worker desplegado en $WORK_DIR"
if [ "$AUDIT_OK" -eq 1 ]; then
  echo "   Arnés: 🟢 CRITICAL en verde"
else
  echo "   Arnés: 🔴 hay CRITICAL en rojo — revisa el detalle de arriba antes de lanzar al agente"
fi

# Declarado (repositories.json) vs realidad (auditoría de ahora mismo) — hace
# visible la deuda de flip de flags sin automatizar la decisión (el "sostenido"
# del criterio de flip es juicio humano).
DECLARED_HARNESS=$(echo "$PROJECT_JSON" | jq -r '.harness_ready')
DECLARED_GRAPH=$(echo "$PROJECT_JSON" | jq -r '.graph_ready // false')
AUDIT_RESULT_TXT=$([ "$AUDIT_OK" -eq 1 ] && echo "0 CRITICAL" || echo "CRITICAL en rojo")
echo "   repositories.json declara: harness_ready=$DECLARED_HARNESS, graph_ready=$DECLARED_GRAPH | auditoría de hoy: $AUDIT_RESULT_TXT"
if [ "$DECLARED_HARNESS" = "false" ] && [ "$AUDIT_OK" -eq 1 ]; then
  echo "   💡 La auditoría está en verde: si se sostiene varias rondas, considera flipar harness_ready=true en repositories.json."
fi

# Allowlist de herramientas del worker: las reglas del prompt ("nunca push a
# la rama por defecto", etc.) son consultivas — esto las hace mecánicas en la
# invocación. El deny de .claude/settings.json del repo (si existe) gana
# siempre además. Cubre los stacks reales de la flota (Maven, npm, Python).
ALLOWED_TOOLS='Edit,Write,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git add:*),Bash(git commit:*),Bash(git checkout:*),Bash(git switch:*),Bash(git push origin:*),Bash(git pull:*),Bash(./mvnw:*),Bash(mvn:*),Bash(npm:*),Bash(npx:*),Bash(python3:*),Bash(pytest:*),Bash(gh issue:*),Bash(gh pr:*),Bash(./init.sh),Bash(./scripts/verify-feature.sh:*),Bash(openspec:*),Bash(graphify:*)'

echo ""
echo "Para arrancar el agente, entra en la carpeta:"
echo "   cd $WORK_DIR"
echo "Y ejecuta:"
echo "   claude -p \"\$(cat $RENDERED)\" --allowedTools '$ALLOWED_TOOLS'"
