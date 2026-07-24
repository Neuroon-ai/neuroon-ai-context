#!/bin/bash
# Despliega un repositorio y prepara al agente Worker para operar sobre él.
# Uso: ./deploy-worker.sh <nombre-repo> [--yes] [--issue <N>]
#   --yes        acepta automáticamente los pasos y/N (para ejecución no interactiva).
#   --issue <N>  asigna explícitamente la Issue #N al worker (si no, el worker
#                elige él solo una Issue abierta cualquiera al arrancar).
set -euo pipefail

REPO_NAME=""
ASSUME_YES=0
ISSUE_NUMBER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --issue) ISSUE_NUMBER="${2:-}"; shift 2 ;;
    -*) echo "❌ Flag desconocido: $1"; exit 1 ;;
    *) REPO_NAME="$1"; shift ;;
  esac
done

if [ -z "$REPO_NAME" ]; then
  echo "❌ Error: Debes indicar el nombre del repositorio a desplegar."
  echo "Uso: ./deploy-worker.sh api-search-neuroon [--yes] [--issue <N>]"
  exit 1
fi
if [ -n "$ISSUE_NUMBER" ] && ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "❌ --issue debe ser un número (ej. --issue 42), recibido: '$ISSUE_NUMBER'"
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

# --issue valida contra GitHub ANTES de tocar nada más: si el número está mal
# o la Issue no está abierta, mejor fallar aquí que dejar al worker
# arrancando una sesión sobre una Issue inexistente/ya cerrada.
if [ -n "$ISSUE_NUMBER" ]; then
  command -v gh >/dev/null 2>&1 || { echo "❌ gh no está instalado (correr ./install-factory.sh)."; exit 1; }
  ISSUE_STATE=$(gh issue view "$ISSUE_NUMBER" --repo "$ORG/$REPO_NAME" --json state -q .state 2>/dev/null || true)
  if [ -z "$ISSUE_STATE" ]; then
    echo "❌ No se encontró la Issue #$ISSUE_NUMBER en $ORG/$REPO_NAME."
    exit 1
  fi
  if [ "$ISSUE_STATE" != "OPEN" ]; then
    echo "❌ La Issue #$ISSUE_NUMBER en $ORG/$REPO_NAME no está abierta (estado: $ISSUE_STATE)."
    exit 1
  fi
  echo "🎯 Worker asignado explícitamente a la Issue #$ISSUE_NUMBER."

  # Mover la Issue a "In progress" en el Project Board justo al arrancar el
  # worker — no cuando abra el PR (eso ya lo cubriría un GitHub Action, que
  # no tenemos montado). Best-effort: si el proyecto/campo no existen o gh no
  # tiene permisos, solo avisa, nunca aborta el despliegue por esto.
  # IDs reales de "Neuroon AI Dashboard" (Project #1 de la org Neuroon-ai),
  # verificados con `gh project field-list 1 --owner Neuroon-ai`.
  PROJECT_NUMBER=1
  PROJECT_OWNER="Neuroon-ai"
  PROJECT_ID="PVT_kwDODjIeO84BeHNs"
  STATUS_FIELD_ID="PVTSSF_lADODjIeO84BeHNszhYj1XY"
  IN_PROGRESS_OPTION_ID="47fc9ee4"
  ITEM_ID=$(gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 300 2>/dev/null \
    | jq -r --argjson n "$ISSUE_NUMBER" --arg repo "$REPO_NAME" \
      '.items[] | select(.content.number == $n and (.content.repository | endswith($repo))) | .id' 2>/dev/null || true)
  if [ -n "$ITEM_ID" ]; then
    if gh project item-edit --id "$ITEM_ID" --project-id "$PROJECT_ID" --field-id "$STATUS_FIELD_ID" --single-select-option-id "$IN_PROGRESS_OPTION_ID" >/dev/null 2>&1; then
      echo "   📋 Issue #$ISSUE_NUMBER movida a 'In progress' en el Project Board."
    else
      echo "   ⚠️  No se pudo mover la Issue #$ISSUE_NUMBER en el Project Board (revisa permisos de gh)."
    fi
  else
    echo "   ⚠️  La Issue #$ISSUE_NUMBER no está en el Project Board '$PROJECT_OWNER'/#$PROJECT_NUMBER — no se mueve nada."
  fi
fi

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

# Auditar y mostrar el resultado. Con CRITICAL en rojo NO se arranca el
# worker automáticamente (ver el gate más abajo, antes del exec) — con el
# arnés roto el worker no tendría ni init.sh/feature_list.json que leer.
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

# --issue: se añade como una sección aparte al final del prompt renderizado,
# en vez de tocar la plantilla versionada — así el paso 7 del worker-prompt
# ("elige UNA Issue") queda sobreescrito solo cuando de verdad se pidió una
# Issue concreta, y el caso sin --issue no cambia en nada.
if [ -n "$ISSUE_NUMBER" ]; then
  cat >> "$RENDERED" <<EOF

## Issue asignada para este despliegue

Esta sesión tiene asignada EXPLÍCITAMENTE la Issue #$ISSUE_NUMBER
(\`gh issue view $ISSUE_NUMBER\`). En el paso 7 de arriba, NO elijas otra
Issue de la lista de abiertas: trabaja EXCLUSIVAMENTE en la #$ISSUE_NUMBER.
EOF
fi

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
# NOTA IMPORTANTE: --allowedTools por sí solo NO es "auto mode" — solo añade
# excepciones al modo "default", que sigue preguntando (o denegando en
# silencio, si no hay TTY) para cualquier cosa fuera de esta lista exacta. Por
# eso el worker real de la Issue #290 se quedaba parado pidiendo aprobación
# aunque "en teoría" ya tuviera permisos de sobra. Comprobado en real con un
# repo de pruebas y una regla deny: --permission-mode bypassPermissions SÍ
# ejecuta cualquier cosa sin preguntar y SIGUE respetando el deny de
# .claude/settings.json (protección de rama, .env, etc. quedan intactas). Es
# el que se usa más abajo en el exec final. --permission-mode dontAsk NO
# sirve solo: falla cerrado (deniega) para todo lo que no esté ya en esta
# ALLOWED_TOOLS, así que sin bypassPermissions el worker se seguiría
# quedando parado igual.
# NOTA: "Bash(git push origin:*)" (usado en una versión anterior) NO matchea
# "git push -u origin <rama>" — el permiso de Claude Code hace match de
# prefijo literal token a token, y el -u va ANTES de "origin". Comprobado en
# real: bloqueó el primer intento de la Issue #290 pidiendo aprobación manual
# para un push de rama de trabajo que ya estaba permitido "en teoría". Con
# "git push:*" cubrimos -u/--set-upstream/etc.; el deny de push directo a la
# rama por defecto en .claude/settings.json (tools/scaffold-harness.sh) sigue
# aplicando y gana siempre sobre este allow.
# git rm: faltaba en una versión anterior — bloqueó a un worker real que
# necesitaba borrar 4 ficheros como parte del alcance de una Issue (retirar
# una feature, no solo añadir código). Sin esto, cualquier Issue de tipo
# "eliminar X" se queda parada pidiendo aprobación manual.
ALLOWED_TOOLS='Edit,Write,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git add:*),Bash(git rm:*),Bash(git commit:*),Bash(git checkout:*),Bash(git switch:*),Bash(git push:*),Bash(git pull:*),Bash(./mvnw:*),Bash(mvn:*),Bash(npm:*),Bash(npx:*),Bash(python3:*),Bash(pytest:*),Bash(gh issue:*),Bash(gh pr:*),Bash(./init.sh),Bash(./scripts/verify-feature.sh:*),Bash(openspec:*),Bash(graphify:*)'

echo ""
if [ "$AUDIT_OK" -ne 1 ]; then
  echo "🔴 No se ofrece arranque automático porque el arnés tiene CRITICAL en rojo — revisa el detalle de arriba."
  echo "Si quieres lanzarlo igualmente, entra en la carpeta y ejecuta:"
  echo "   cd $WORK_DIR"
  echo "Y ejecuta:"
  echo "   claude -p \"\$(cat $RENDERED)\" --allowedTools '$ALLOWED_TOOLS'"
  exit 0
fi

# Autónomo: sin confirmación y/N. El único gate es el arnés en verde de
# arriba — si el arnés está bien, el worker arranca directo, sin pedir
# permiso (igual que el resto de la sesión corre en auto mode).
#
# Con terminal real (-t 1): modo INTERACTIVO (sin -p), igual que
# plan-feature.sh. `-p` es headless y no imprime NADA hasta terminar o hasta
# que necesite preguntar algo — en una terminal humana eso se ve exactamente
# igual que "colgado" aunque esté trabajando de verdad. El modo interactivo
# muestra en vivo lo que hace, y si necesita preguntar algo (p. ej. una
# decisión ambigua) lo haces ahí mismo, sin --resume por separado.
# Sin terminal (cron, otro script, este mismo deploy-worker.sh invocado por
# un proceso no interactivo): cae a -p, que sí es el modo correcto ahí.
echo "🚀 Arrancando el worker en $WORK_DIR..."
cd "$WORK_DIR"

# Scope de systemd con CPUWeight=50 (la mitad del peso por defecto) y
# MemoryHigh=10G: cuando el worker + su mvnw verify compiten con la sesión
# interactiva del humano, el cgroup cede CPU a la sesión y amortigua los picos
# de RAM del build. Un `nice` a secas NO sirve aquí: cada sesión corre en un
# scope hermano de cgroup v2 y el kernel arbitra por scope, no por niceness.
# Si el user manager de systemd no está disponible (contenedor raro, ssh sin
# lingering), se lanza sin envolver antes que no lanzar.
RUN_WRAP=()
if systemd-run --user --scope -q -p CPUWeight=50 true 2>/dev/null; then
  RUN_WRAP=(systemd-run --user --scope -q -p CPUWeight=50 -p MemoryHigh=10G)
else
  echo "⚠️  systemd-run --user no disponible — el worker arranca sin límites de CPU/RAM propios."
fi

if [ -t 1 ] && [ -t 0 ]; then
  exec "${RUN_WRAP[@]}" claude "$(cat "$RENDERED")" --allowedTools "$ALLOWED_TOOLS" --permission-mode bypassPermissions
else
  exec "${RUN_WRAP[@]}" claude -p "$(cat "$RENDERED")" --allowedTools "$ALLOWED_TOOLS" --permission-mode bypassPermissions
fi
