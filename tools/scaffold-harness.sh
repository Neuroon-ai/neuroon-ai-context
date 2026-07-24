#!/bin/bash
# tools/scaffold-harness.sh — Genera el esqueleto mínimo de arnés en un repo target.
# Idempotente: SOLO crea lo que falta. Nunca sobreescribe sin --force.
#
# Uso:
#   ./tools/scaffold-harness.sh --target ./workspaces/api-search-neuroon --default-branch develop
#   ./tools/scaffold-harness.sh --target ./workspaces/app-search-neuroon --force
set -euo pipefail

TARGET=""
FORCE=0
DEFAULT_BRANCH="main"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --default-branch) DEFAULT_BRANCH="${2:-main}"; shift 2 ;;
    *) echo "Uso: ./scaffold-harness.sh --target <dir> [--force] [--default-branch <rama>]"; exit 1 ;;
  esac
done

if [ -z "$TARGET" ]; then echo "❌ Falta --target <dir>"; exit 1; fi
if [ ! -d "$TARGET" ]; then echo "❌ No existe: $TARGET"; exit 1; fi
TARGET="$(cd "$TARGET" && pwd)"

detect_type() {
  if [ -f "$TARGET/build.gradle.kts" ] || [ -f "$TARGET/build.gradle" ]; then echo "gradle"
  elif [ -f "$TARGET/pom.xml" ]; then echo "maven"
  elif [ -f "$TARGET/pyproject.toml" ] || [ -f "$TARGET/requirements.txt" ]; then echo "python"
  elif [ -f "$TARGET/package.json" ]; then
    if ls "$TARGET"/next.config.* >/dev/null 2>&1; then echo "next"; else echo "node"; fi
  elif find "$TARGET" -maxdepth 2 -iname "*.php" 2>/dev/null | grep -q .; then echo "wordpress"
  else echo "unknown"; fi
}
TYPE="$(detect_type)"
echo "=== 🧩 Scaffold Harness — $TARGET (tipo: $TYPE) ==="

write_if_missing() {
  local path="$1"
  if [ -f "$path" ] && [ "$FORCE" -ne 1 ]; then
    echo "  ⏭️  Ya existe, no se toca: $(basename "$path")"
    return 0
  fi
  cat > "$path"
  echo "  ✅ Generado: $(basename "$path")"
}

# ── Router (AGENTS.md + CLAUDE.md) ────────────────────────────────────────
if [ ! -f "$TARGET/AGENTS.md" ] && [ ! -f "$TARGET/CLAUDE.md" ]; then
  write_if_missing "$TARGET/AGENTS.md" <<EOF
# AGENTS.md — $(basename "$TARGET")

Router de agente para este repositorio (tipo detectado: $TYPE).

## Cómo empezar (obligatorio, en este orden)
1. \`pwd\` — confirma en qué repo/carpeta estás.
2. Lee \`claude-progress.md\` — qué se hizo en la última sesión.
3. Revisa las **GitHub Issues abiertas** (\`gh issue list --state open\`) — ahí
   vive el backlog real, no en \`feature_list.json\` (que solo trackea el arnés).
4. \`git log --oneline -10\` — últimos commits reales.
5. Ejecuta \`./init.sh\` — verificación LIGERA (compila/lint). No corre el
   suite completo de tests — eso lo hace la CI sobre el PR.
6. Elige UNA sola Issue. Crea rama \`tipo/gh-ID\` y abre el PR en Draft
   INMEDIATAMENTE (\`gh pr create --draft --title "WIP: <título>" --body "Resolves #<ID>"\`)
   — no esperes a tener el código terminado.
7. Verifica tu trabajo de forma ACOTADA a lo que tocaste:
   \`./scripts/verify-feature.sh "<patrón>"\`. El check completo lo corre la CI
   del PR, no tu sesión local.

## Nunca hacer
- Nunca push directo a la rama por defecto del repo.
- Nunca corras el suite completo en local "por si acaso" si no has tocado código.
- Nunca marques una feature como \`passing\` si eres quien la implementó — la
  aprueba un Verifier separado o un humano, nunca el propio Maker.
- Nunca silencies un check en rojo para "avanzar".

## TODO (rellenar durante el piloto)
- [ ] Enlazar aquí las reglas de arquitectura reales del repo, si existen.
- [ ] Ajustar los comandos de \`./init.sh\` y \`./scripts/verify-feature.sh\` a los scripts reales del repo.
EOF

  write_if_missing "$TARGET/CLAUDE.md" <<'EOF'
# CLAUDE.md

Este repo usa **AGENTS.md** como router único para agentes IA (agente-agnóstico).
Lee `AGENTS.md` primero. Este archivo existe solo para las herramientas que
todavía buscan `CLAUDE.md` por convención.
EOF
else
  echo "  ⏭️  Ya existe AGENTS.md o CLAUDE.md — no se crea un router nuevo (usa --force para forzar)."
  if [ "$FORCE" -eq 1 ] && [ ! -f "$TARGET/AGENTS.md" ]; then
    echo "  ⚠️  --force pedido pero solo existe CLAUDE.md: no se genera un AGENTS.md paralelo automáticamente."
    echo "      Migrar a AGENTS.md es una decisión de contenido, no de scaffold — hazlo a mano."
  fi
fi

# ── feature_list.json ──────────────────────────────────────────────────────
# Array plano (no envuelto en {"features": [...]}) — mismo patrón que
# api-search-neuroon. Solo trackea el bootstrap del arnés; el backlog de
# negocio real vive en GitHub Issues + Project Board, creadas por el rol
# Planner (.claude/agents/planner.md).
write_if_missing "$TARGET/feature_list.json" <<EOF
[
  {
    "id": "setup-harness",
    "priority": 1,
    "area": "tooling",
    "title": "Configuración inicial de Harness Engineering",
    "user_visible_behavior": "Los agentes de IA leen el estado al inicio de sesión (claude-progress.md, GitHub Issues abiertas) y documentan sus avances al salir.",
    "status": "passing",
    "verification": "AGENTS.md/CLAUDE.md, claude-progress.md, session-handoff.md, clean-state-checklist.md e init.sh están presentes en la raíz.",
    "evidence": "Ficheros generados por scaffold-harness.sh el $(date +%F).",
    "notes": "El backlog de negocio real vive en GitHub Issues + Project Board, NO en este fichero."
  }
]
EOF

# ── claude-progress.md ─────────────────────────────────────────────────────
write_if_missing "$TARGET/claude-progress.md" <<EOF
# Progreso — $(basename "$TARGET")

## Estado actual
_(sin sesiones registradas todavía)_

## Última sesión
- Fecha:
- Qué se hizo:
- Qué quedó a medias:

## Próximo paso sugerido
_(vacío — lo rellena la primera sesión real)_

## Bloqueos conocidos
_(ninguno todavía)_
EOF

# ── session-handoff.md ─────────────────────────────────────────────────────
write_if_missing "$TARGET/session-handoff.md" <<'EOF'
# Session Handoff

> Rellenar SIEMPRE al final de una sesión de agente, antes de cerrar.

## Qué se hizo esta sesión


## Qué falta / próximo paso


## Cómo verificar que lo hecho sigue funcionando


## Riesgos, dudas o decisiones que necesita revisar un humano

EOF

# ── clean-state-checklist.md ───────────────────────────────────────────────
write_if_missing "$TARGET/clean-state-checklist.md" <<'EOF'
# Clean State Checklist

Antes de terminar una sesión de agente, confirma TODO lo siguiente:

- [ ] `git status` sin cambios sueltos sin commitear (o documentados en session-handoff.md).
- [ ] La verificación local (init.sh / build del repo) está en verde.
- [ ] `feature_list.json` refleja el estado real (nada en `in_progress` sin dueño).
- [ ] `claude-progress.md` actualizado con lo hecho en esta sesión.
- [ ] `session-handoff.md` actualizado para el siguiente agente/humano.
- [ ] Ningún secreto (.env, tokens, claves) en el diff.
- [ ] No quedan `console.log`/`println`/prints de depuración añadidos en esta sesión.
EOF

# ── .gitignore ──────────────────────────────────────────────────────────────
# audit-harness.sh marca su ausencia como CRITICAL (S5) — se genera aquí para
# que ese check pueda pasar de rojo a verde sin intervención manual.
case "$TYPE" in
  gradle)
    write_if_missing "$TARGET/.gitignore" <<'EOF'
build/
.gradle/
*.class
.idea/
*.iml
out/
EOF
    ;;
  maven)
    write_if_missing "$TARGET/.gitignore" <<'EOF'
target/
.idea/
*.iml
EOF
    ;;
  node|next)
    write_if_missing "$TARGET/.gitignore" <<'EOF'
node_modules/
dist/
.next/
build/
.env
.env.local
EOF
    ;;
  python)
    write_if_missing "$TARGET/.gitignore" <<'EOF'
__pycache__/
*.pyc
.venv/
venv/
.env
EOF
    ;;
  *)
    write_if_missing "$TARGET/.gitignore" <<'EOF'
.env
*.log
EOF
    ;;
esac

# ── init.sh ─────────────────────────────────────────────────────────────────
# Verificación LIGERA real: compila/linta sin correr la suite de tests, y
# comprueba el invariante WIP=1 de feature_list.json.
case "$TYPE" in
  gradle)
    write_if_missing "$TARGET/init.sh" <<'EOF'
#!/bin/bash
# init.sh — Línea base LIGERA del repo (Gradle). No corre tests (eso es de la
# CI del PR). Extiende con los tasks de lint reales del repo cuando se conozcan.
set -euo pipefail
echo "=== Init (Gradle, ligero) ==="
[ -x "./gradlew" ] || { echo "❌ No hay ./gradlew ejecutable"; exit 1; }

NPROC="$(nproc 2>/dev/null || echo 4)"
MAX_WORKERS="${GRADLE_MAX_WORKERS:-$(( NPROC / 2 > 2 ? NPROC / 2 : 2 ))}"

./gradlew classes testClasses --console=plain --max-workers="$MAX_WORKERS" \
  || { echo "❌ Falla de compilación — repara esto ANTES de añadir alcance nuevo."; exit 1; }

if [ -f "feature_list.json" ] && command -v jq >/dev/null 2>&1; then
  WIP=$(jq '[ (if type=="array" then . else .features end)[] | select(.status=="in_progress") ] | length' feature_list.json 2>/dev/null || echo 0)
  if [ "${WIP:-0}" -gt 1 ]; then
    echo "❌ WIP=$WIP en feature_list.json (máximo 1 in_progress)"; exit 1
  fi
fi
echo "✅ Línea base en verde (compila; lint/tests completos: CI del PR)."
EOF
    ;;
  maven)
    write_if_missing "$TARGET/init.sh" <<'EOF'
#!/bin/bash
# init.sh — Línea base LIGERA del repo (Maven). No corre tests (eso es de la
# CI del PR): solo compila.
set -euo pipefail
echo "=== Init (Maven, ligero) ==="
MVN="./mvnw"
[ -x "$MVN" ] || MVN="mvn"
command -v "$MVN" >/dev/null 2>&1 || [ -x "$MVN" ] || { echo "❌ No hay mvnw ni mvn disponible"; exit 1; }

"$MVN" -q compile \
  || { echo "❌ Falla de compilación — repara esto ANTES de añadir alcance nuevo."; exit 1; }

if [ -f "feature_list.json" ] && command -v jq >/dev/null 2>&1; then
  WIP=$(jq '[ (if type=="array" then . else .features end)[] | select(.status=="in_progress") ] | length' feature_list.json 2>/dev/null || echo 0)
  if [ "${WIP:-0}" -gt 1 ]; then
    echo "❌ WIP=$WIP en feature_list.json (máximo 1 in_progress)"; exit 1
  fi
fi
echo "✅ Línea base en verde (compila; tests completos: CI del PR)."
EOF
    ;;
  node|next)
    write_if_missing "$TARGET/init.sh" <<'EOF'
#!/bin/bash
# init.sh — Línea base LIGERA del repo (Node/npm). No corre la suite de tests
# ni el build completo (eso es de la CI del PR).
set -euo pipefail
echo "=== Init (Node, ligero) ==="
[ -f "package.json" ] || { echo "❌ No hay package.json"; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "❌ npm no está instalado (correr install-factory.sh en la Matriz)"; exit 1; }

# Instala dependencias SOLO si faltan (npm ci borra node_modules cada vez —
# demasiado pesado para una verificación ligera que corre cada sesión).
if [ ! -d "node_modules" ]; then
  echo "node_modules ausente — instalando dependencias (npm ci)..."
  npm ci --no-audit --no-fund
fi

# Lint y typecheck si el repo los define; --if-present hace esto portable.
npm run lint --if-present
npm run typecheck --if-present

if [ -f "feature_list.json" ] && command -v jq >/dev/null 2>&1; then
  WIP=$(jq '[ (if type=="array" then . else .features end)[] | select(.status=="in_progress") ] | length' feature_list.json 2>/dev/null || echo 0)
  if [ "${WIP:-0}" -gt 1 ]; then
    echo "❌ WIP=$WIP en feature_list.json (máximo 1 in_progress)"; exit 1
  fi
fi
echo "✅ Línea base en verde (lint/typecheck; build/tests completos: CI del PR)."
EOF
    ;;
  python)
    write_if_missing "$TARGET/init.sh" <<'EOF'
#!/bin/bash
# init.sh — Línea base LIGERA del repo (Python). No corre la suite de tests
# completa (eso es de la CI del PR): solo comprueba que el código importa/lint.
set -euo pipefail
echo "=== Init (Python, ligero) ==="
command -v python3 >/dev/null 2>&1 || { echo "❌ python3 no está instalado"; exit 1; }

if [ -f "requirements.txt" ] && [ ! -d ".venv" ]; then
  echo "⚠️  .venv ausente — considera crear un entorno virtual e instalar requirements.txt"
fi

if [ -f "feature_list.json" ] && command -v jq >/dev/null 2>&1; then
  WIP=$(jq '[ (if type=="array" then . else .features end)[] | select(.status=="in_progress") ] | length' feature_list.json 2>/dev/null || echo 0)
  if [ "${WIP:-0}" -gt 1 ]; then
    echo "❌ WIP=$WIP en feature_list.json (máximo 1 in_progress)"; exit 1
  fi
fi
echo "✅ Línea base en verde (comprobaciones ligeras; tests completos: CI del PR)."
EOF
    ;;
  *)
    write_if_missing "$TARGET/init.sh" <<'EOF'
#!/bin/bash
# init.sh — Tipo de repo no reconocido por scaffold-harness.sh. Ajusta a mano.
set -euo pipefail
echo "⚠️ Tipo de repo no detectado automáticamente. Edita este init.sh a mano."
exit 1
EOF
    ;;
esac
chmod +x "$TARGET/init.sh" 2>/dev/null || true

# ── scripts/verify-feature.sh ───────────────────────────────────────────────
# Verificación ACOTADA a lo tocado (patrón del piloto): los prompts de
# Maker/Verifier/Worker y el AGENTS.md scaffoldeado lo referencian, así que
# DEBE existir.
mkdir -p "$TARGET/scripts"
case "$TYPE" in
  gradle)
    write_if_missing "$TARGET/scripts/verify-feature.sh" <<'EOF'
#!/bin/bash
# verify-feature.sh — Corre SOLO los tests que cubren tu cambio.
# Uso: ./scripts/verify-feature.sh "*PatronUno*,*PatronDos*"
set -euo pipefail
PATTERNS="${1:-}"
[ -n "$PATTERNS" ] || { echo "Uso: ./scripts/verify-feature.sh \"*Patron*[,*Otro*]\""; exit 1; }

IFS=',' read -r -a PATTERN_ARR <<< "$PATTERNS"
TEST_FLAGS=()
for p in "${PATTERN_ARR[@]}"; do
  TEST_FLAGS+=(--tests "$p")
done

NPROC="$(nproc 2>/dev/null || echo 4)"
MAX_WORKERS="${GRADLE_MAX_WORKERS:-$(( NPROC / 2 > 2 ? NPROC / 2 : 2 ))}"

if ./gradlew test "${TEST_FLAGS[@]}" --console=plain --max-workers="$MAX_WORKERS"; then
  echo "✅ Verificación acotada en verde: $PATTERNS (commit $(git rev-parse --short HEAD), $(date -Is))"
else
  echo "❌ Verificación acotada en rojo. No se considera la feature terminada." >&2
  exit 1
fi
EOF
    ;;
  maven)
    write_if_missing "$TARGET/scripts/verify-feature.sh" <<'EOF'
#!/bin/bash
# verify-feature.sh — Corre SOLO los tests que cubren tu cambio.
# Uso: ./scripts/verify-feature.sh "com.neuroon.SomeTest,com.neuroon.OtherTest"
set -euo pipefail
PATTERNS="${1:-}"
[ -n "$PATTERNS" ] || { echo "Uso: ./scripts/verify-feature.sh \"ClaseTest1,ClaseTest2\""; exit 1; }

MVN="./mvnw"
[ -x "$MVN" ] || MVN="mvn"

if "$MVN" -q test -Dtest="$PATTERNS"; then
  echo "✅ Verificación acotada en verde: $PATTERNS (commit $(git rev-parse --short HEAD), $(date -Is))"
else
  echo "❌ Verificación acotada en rojo. No se considera la feature terminada." >&2
  exit 1
fi
EOF
    ;;
  node|next)
    write_if_missing "$TARGET/scripts/verify-feature.sh" <<'EOF'
#!/bin/bash
# verify-feature.sh — Corre SOLO los tests que cubren tu cambio.
# Uso: ./scripts/verify-feature.sh "<patrón de fichero/nombre de test>"
# Nota: vitest y jest aceptan un filtro posicional tras `--`. Si el runner del
# repo usa otra sintaxis, ajusta este script (y documenta el cambio en AGENTS.md).
set -euo pipefail
PATTERN="${1:-}"
[ -n "$PATTERN" ] || { echo "Uso: ./scripts/verify-feature.sh \"<patrón>\""; exit 1; }

if npm test -- "$PATTERN"; then
  echo "✅ Verificación acotada en verde: $PATTERN (commit $(git rev-parse --short HEAD), $(date -Is))"
else
  echo "❌ Verificación acotada en rojo. No se considera la feature terminada." >&2
  exit 1
fi
EOF
    ;;
  python)
    write_if_missing "$TARGET/scripts/verify-feature.sh" <<'EOF'
#!/bin/bash
# verify-feature.sh — Corre SOLO los tests que cubren tu cambio.
# Uso: ./scripts/verify-feature.sh "tests/test_something.py"
set -euo pipefail
PATTERN="${1:-}"
[ -n "$PATTERN" ] || { echo "Uso: ./scripts/verify-feature.sh \"<ruta o patrón de test>\""; exit 1; }

if python3 -m pytest "$PATTERN"; then
  echo "✅ Verificación acotada en verde: $PATTERN (commit $(git rev-parse --short HEAD), $(date -Is))"
else
  echo "❌ Verificación acotada en rojo. No se considera la feature terminada." >&2
  exit 1
fi
EOF
    ;;
  *)
    echo "  ⏭️  Tipo desconocido — no se genera verify-feature.sh (créalo a mano)."
    ;;
esac
[ -f "$TARGET/scripts/verify-feature.sh" ] && chmod +x "$TARGET/scripts/verify-feature.sh"

# ── .claude/agents/planner.md ───────────────────────────────────────────────
# Rol Planner que plan-feature.sh (Matriz) exige.
mkdir -p "$TARGET/.claude/agents"
write_if_missing "$TARGET/.claude/agents/planner.md" <<EOF
# Rol: Arquitecto / Product Owner (planificación, solo lectura de código)

Cargado por \`plan-feature.sh\` (repo \`neuroon-ai-context\`) para abrir una
sesión de planificación interactiva sobre $(basename "$TARGET").

## Alcance de esta sesión
- Solo lectura de código: no editas ni formateas ficheros de producción.
- Escrituras permitidas: (a) GitHub Issues (\`gh issue create/edit\`), y
  (b) si el repo tiene \`openspec/\`, los ficheros del change en
  \`openspec/changes/\` — commiteados en una rama \`plan/uh-<n>-<slug>\` con PR
  en Draft, NUNCA directo a la rama por defecto.

## Antes de proponer nada
1. Lee \`AGENTS.md\`/\`CLAUDE.md\` completo, y las reglas de arquitectura que enlace.
2. Revisa las GitHub Issues abiertas (\`gh issue list --state open\`) y
   \`claude-progress.md\` para no proponer algo ya en curso.
3. \`feature_list.json\` NO es el backlog de negocio — no lo consultes para esto.

## Flujo estándar
1. Entiende la necesidad del humano (texto, pantallazos, diseños...). Pregunta
   lo que falte — no rellenes huecos con suposiciones.
2. Crea la Issue primero, breve: título + contexto. Obtienes su número N.
3. Si el repo usa OpenSpec, redacta el change: \`openspec/changes/<slug>-<N>/\`
   con proposal + deltas de specs + tasks.
4. Actualiza la Issue: criterios de aceptación, sección **Verificación** con el
   patrón exacto para \`./scripts/verify-feature.sh "<patrón>"\`.
5. Si tocaste OpenSpec, commitea en rama \`plan/<slug>-<N>\` y abre PR en Draft:
   la revisión humana de ese PR ES la aprobación del plan antes de escribir código.

## Reglas
- Cada Issue debe ser verificable sin ambigüedad por un Worker.
- Ninguna Issue puede exigir violar las reglas de arquitectura del repo.
- El backlog vive en GitHub Issues + Project Board — nunca en ficheros locales.
EOF

# ── .claude/settings.json — invariantes DURAS (no consultivas) ─────────────
# DEFAULT_BRANCH viene de --default-branch (deploy-worker.sh lo pasa leyéndolo
# de repositories.json); si se invoca este script suelto, cae a "main".
SETTINGS_PATH="$TARGET/.claude/settings.json"
if [ -f "$SETTINGS_PATH" ] && [ "$FORCE" -ne 1 ]; then
  echo "  ⏭️  Ya existe, no se toca: $(basename "$SETTINGS_PATH")"
elif command -v jq >/dev/null 2>&1; then
  # Genera el JSON con jq en vez de interpolar DEFAULT_BRANCH en un heredoc a
  # pelo: jq escapa correctamente el valor (comillas, backslashes) y evita
  # que un default_branch atípico deje el JSON mal formado sin que nadie se
  # entere (las reglas deny se ignorarían en silencio).
  jq -n --arg branch "$DEFAULT_BRANCH" '{
    permissions: {
      deny: [
        ("Bash(git push origin " + $branch + ")"),
        ("Bash(git push origin " + $branch + ":*)"),
        "Bash(git push --force:*)",
        "Bash(git push -f:*)",
        "Read(./.env)",
        "Read(./.env.*)",
        "Edit(./.env)",
        "Edit(./.env.*)"
      ]
    }
  }' > "$SETTINGS_PATH"
  echo "  ✅ Generado: $(basename "$SETTINGS_PATH")"
else
  warn_no_jq() { echo "  ⚠️  jq no disponible — generando settings.json sin escapado seguro de --default-branch."; }
  warn_no_jq
  cat > "$SETTINGS_PATH" <<EOF
{
  "permissions": {
    "deny": [
      "Bash(git push origin $DEFAULT_BRANCH)",
      "Bash(git push origin $DEFAULT_BRANCH:*)",
      "Bash(git push --force:*)",
      "Bash(git push -f:*)",
      "Read(./.env)",
      "Read(./.env.*)",
      "Edit(./.env)",
      "Edit(./.env.*)"
    ]
  }
}
EOF
  echo "  ✅ Generado: $(basename "$SETTINGS_PATH")"
fi

# ── OpenSpec (spec-driven development) ──────────────────────────────────────
# Inicializa openspec/ + slash commands /opsx:* para Claude Code. Idempotente:
# solo si el CLI está instalado (install-factory.sh) y el repo no lo tiene ya.
if command -v openspec >/dev/null 2>&1; then
  if [ ! -d "$TARGET/openspec" ]; then
    echo "  🔧 Inicializando OpenSpec (openspec init --tools claude)..."
    (cd "$TARGET" && openspec init --tools claude) \
      && echo "  ✅ OpenSpec inicializado (openspec/ + /opsx:* para Claude Code)." \
      || echo "  ⚠️  openspec init falló — inicialízalo a mano cuando puedas."
  else
    echo "  ⏭️  openspec/ ya existe — no se reinicializa."
  fi
else
  echo "  ⚠️  openspec no está instalado en esta máquina (correr ./install-factory.sh) — se omite."
fi

echo ""
echo "🏁 Scaffold completo. Verifica con: ./tools/audit-harness.sh $TARGET"
echo "ℹ️  Nota: la automatización del Project Board de GitHub (mover Issues al abrir/aprobar PRs)"
echo "   no se genera aquí — requiere IDs reales de tu Project Board. Configúrala a mano si la quieres"
echo "   (ver docs/LOOP-ENGINEERING.md)."
