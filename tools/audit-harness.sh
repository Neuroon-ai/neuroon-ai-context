#!/bin/bash
# tools/audit-harness.sh — Auditor de arnés para la flota Neuroon.
# Inspirado (no vendorizado) en walkinglabs/learn-harness-engineering (MIT).
# Zero-dependencia: bash + jq. Sin jq, los checks de JSON degradan a WARN.
#
# Uso:
#   ./tools/audit-harness.sh [ruta]      # audita ./ o la ruta dada
#
# Exit code: 0 si CRITICAL_FAIL=0, 1 en caso contrario.
set -euo pipefail

REPO="${1:-.}"
if [ ! -d "$REPO" ]; then
  echo "❌ No existe el directorio: $REPO"
  exit 1
fi
REPO="$(cd "$REPO" && pwd)"

# MATRIX_ROOT/REPO_NAME: desde que se trabaja con una sesión Claude única en
# la raíz de la Matriz (no un worker por repo), el grafo de código vive
# centralizado fuera del repo (workspaces/.graphify-data/, ver
# tools/sync-graph.sh) — S6 necesita saber dónde está la Matriz para
# encontrarlo, sea cual sea la ruta que se le pase a este script.
MATRIX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_NAME="$(basename "$REPO")"

CRITICAL_FAIL=0
RECOMMENDED_WARN=0
TOTAL=0

pass()          { TOTAL=$((TOTAL+1)); echo "  ✅ PASS  [$1] $2"; }
fail_critical() { TOTAL=$((TOTAL+1)); CRITICAL_FAIL=$((CRITICAL_FAIL+1)); echo "  ❌ FAIL  [$1] $2 (CRITICAL)"; }
warn()          { TOTAL=$((TOTAL+1)); RECOMMENDED_WARN=$((RECOMMENDED_WARN+1)); echo "  ⚠️  WARN  [$1] $2 (RECOMMENDED)"; }
section()       { echo ""; echo "── $1 ──"; }

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# Detecta el tipo de repo por marcadores de build/stack. El orden importa:
# un repo Next.js también tiene package.json, así que "next" se comprueba
# antes que el "node" genérico.
detect_type() {
  if [ -f "$REPO/build.gradle.kts" ] || [ -f "$REPO/build.gradle" ]; then
    echo "gradle"
  elif [ -f "$REPO/pom.xml" ]; then
    echo "maven"
  elif [ -f "$REPO/pyproject.toml" ] || [ -f "$REPO/requirements.txt" ]; then
    echo "python"
  elif [ -f "$REPO/package.json" ]; then
    if ls "$REPO"/next.config.* >/dev/null 2>&1; then
      echo "next"
    else
      echo "node"
    fi
  elif find "$REPO" -maxdepth 2 -iname "*.php" 2>/dev/null | grep -q .; then
    echo "wordpress"
  else
    echo "unknown"
  fi
}

TYPE="$(detect_type)"
echo "=== 🛡️  Audit Harness — $REPO ==="
echo "Tipo de repo detectado: $TYPE"

# ── S1. Contrato del agente (router) ──────────────────────────────────────
section "S1. Contrato del agente"
if [ -f "$REPO/AGENTS.md" ] || [ -f "$REPO/CLAUDE.md" ]; then
  pass "S1" "Existe router de agente (AGENTS.md o CLAUDE.md)"
else
  fail_critical "S1" "Falta AGENTS.md/CLAUDE.md — el agente no tiene contrato de entrada"
fi

# ── S2. Seguimiento de features ───────────────────────────────────────────
section "S2. Seguimiento de features"
if [ -f "$REPO/feature_list.json" ]; then
  if [ "$HAVE_JQ" -eq 1 ]; then
    if jq empty "$REPO/feature_list.json" >/dev/null 2>&1; then
      pass "S2" "feature_list.json es JSON válido"
      # Tolera tanto {"features": [...]} como un array plano en la raíz.
      COUNT=$(jq 'if type=="array" then . else .features end | length' "$REPO/feature_list.json" 2>/dev/null || echo 0)
      if [ "${COUNT:-0}" -gt 0 ]; then
        pass "S2" "feature_list.json tiene $COUNT feature(s) declaradas"
      else
        warn "S2" "feature_list.json existe pero no tiene features declaradas todavía"
      fi
    else
      fail_critical "S2" "feature_list.json existe pero NO es JSON válido"
    fi
  else
    warn "S2" "jq no instalado — omitiendo validación de feature_list.json"
  fi
else
  fail_critical "S2" "Falta feature_list.json"
fi

# ── S3. Continuidad entre sesiones ────────────────────────────────────────
section "S3. Continuidad entre sesiones"
if [ -f "$REPO/claude-progress.md" ]; then
  pass "S3" "Existe claude-progress.md"
  if [ -n "$(find "$REPO/claude-progress.md" -mtime -30 2>/dev/null)" ]; then
    pass "S3" "claude-progress.md actualizado en los últimos 30 días"
  else
    warn "S3" "claude-progress.md no se actualiza hace más de 30 días (posible desincronización)"
  fi
  # Detector de Drift: si el progress declara un HEAD (primer sha corto entre
  # backticks), compáralo con el HEAD real.
  if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BACKTICK='`'
    DECLARED_SHA="$(grep -oE "${BACKTICK}[0-9a-f]{7,40}${BACKTICK}" "$REPO/claude-progress.md" 2>/dev/null | head -1 | tr -d "$BACKTICK" || true)"
    if [ -n "$DECLARED_SHA" ]; then
      if git -C "$REPO" cat-file -e "${DECLARED_SHA}^{commit}" 2>/dev/null; then
        AHEAD="$(git -C "$REPO" rev-list --count "${DECLARED_SHA}..HEAD" 2>/dev/null || echo "?")"
        if [ "$AHEAD" = "0" ]; then
          pass "S3" "Sin drift: el HEAD declarado en claude-progress.md coincide con el real"
        elif [ "$AHEAD" = "?" ]; then
          warn "S3" "No se pudo medir el drift del progress (¿HEAD declarado en otra rama?)"
        elif [ "$AHEAD" -gt 5 ]; then
          fail_critical "S3" "Drift grave: $AHEAD commits desde el HEAD declarado en claude-progress.md sin registro de sesión"
        else
          warn "S3" "Drift: $AHEAD commit(s) desde el HEAD declarado en claude-progress.md — actualizar el registro de sesión"
        fi
      else
        warn "S3" "El sha declarado en claude-progress.md ($DECLARED_SHA) no existe en este clon (¿shallow o rama distinta?)"
      fi
    fi
  fi
else
  fail_critical "S3" "Falta claude-progress.md"
fi
if [ -f "$REPO/session-handoff.md" ]; then
  pass "S3" "Existe session-handoff.md"
else
  warn "S3" "Falta session-handoff.md (recomendado para el traspaso entre agentes)"
fi

# ── S4. Bucle de verificación ──────────────────────────────────────────────
section "S4. Bucle de verificación"
if [ -f "$REPO/init.sh" ]; then
  if [ -x "$REPO/init.sh" ]; then pass "S4" "init.sh existe y es ejecutable"
  else warn "S4" "init.sh existe pero no es ejecutable (chmod +x)"
  fi
else
  fail_critical "S4" "Falta init.sh"
fi
if [ -f "$REPO/scripts/verify-feature.sh" ] || [ -f "$REPO/verify-feature.sh" ]; then
  pass "S4" "verify-feature.sh existe"
else
  warn "S4" "Falta verify-feature.sh (recomendado: cierre explícito por feature)"
fi
case "$TYPE" in
  gradle)
    if [ -x "$REPO/gradlew" ]; then
      pass "S4" "gradlew presente y ejecutable (verificación: ./gradlew check)"
    else
      fail_critical "S4" "Repo Gradle sin gradlew ejecutable"
    fi
    ;;
  maven)
    if [ -x "$REPO/mvnw" ]; then
      pass "S4" "mvnw presente y ejecutable (verificación: ./mvnw verify)"
    else
      warn "S4" "Repo Maven sin mvnw ejecutable (usará mvn del sistema)"
    fi
    ;;
  node|next)
    if [ "$HAVE_JQ" -eq 1 ] && jq -e '.scripts.build or .scripts.test' "$REPO/package.json" >/dev/null 2>&1; then
      pass "S4" "package.json define script build o test"
    else
      warn "S4" "package.json sin script build/test detectable (o jq no disponible)"
    fi
    ;;
  python)
    if [ -f "$REPO/requirements.txt" ] || [ -f "$REPO/pyproject.toml" ]; then
      pass "S4" "Dependencias Python declaradas (requirements.txt/pyproject.toml)"
    fi
    if [ -d "$REPO/tests" ]; then
      pass "S4" "Directorio tests/ presente"
    else
      warn "S4" "No se encontró directorio tests/"
    fi
    ;;
  wordpress)
    warn "S4" "Tipo WordPress/PHP: no hay convención de verificación estándar — define scripts/verify-feature.sh a mano"
    ;;
  *)
    warn "S4" "Tipo de repo no reconocido — no se puede inferir el comando de verificación"
    ;;
esac

# ── S5. Disciplina de estado limpio ───────────────────────────────────────
section "S5. Estado limpio"
if [ -f "$REPO/.gitignore" ]; then
  pass "S5" "Existe .gitignore"
  case "$TYPE" in
    gradle)
      if grep -q "^build/" "$REPO/.gitignore" 2>/dev/null; then pass "S5" ".gitignore cubre build/"; else warn "S5" ".gitignore no cubre build/ explícitamente"; fi
      ;;
    maven)
      if grep -q "^target/" "$REPO/.gitignore" 2>/dev/null; then pass "S5" ".gitignore cubre target/"; else warn "S5" ".gitignore no cubre target/ explícitamente"; fi
      ;;
    node|next)
      if grep -q "node_modules" "$REPO/.gitignore" 2>/dev/null; then pass "S5" ".gitignore cubre node_modules"; else warn "S5" ".gitignore no cubre node_modules explícitamente"; fi
      ;;
    python)
      if grep -qE "__pycache__|\.venv|venv/" "$REPO/.gitignore" 2>/dev/null; then pass "S5" ".gitignore cubre entornos/artefactos Python"; else warn "S5" ".gitignore no cubre __pycache__/venv explícitamente"; fi
      ;;
  esac
else
  fail_critical "S5" "Falta .gitignore"
fi
if [ -f "$REPO/clean-state-checklist.md" ]; then
  pass "S5" "Existe clean-state-checklist.md"
else
  warn "S5" "Falta clean-state-checklist.md"
fi
if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  TRACKED_ENV="$(git -C "$REPO" ls-files | grep -E '(^|/)\.env$' || true)"
  if [ -z "$TRACKED_ENV" ]; then
    pass "S5" "Ningún .env versionado en git"
  else
    fail_critical "S5" "Hay .env versionado en git: $TRACKED_ENV"
  fi
else
  warn "S5" "$REPO no es un repositorio git (no se pudo comprobar secretos versionados)"
fi

# ── S6. Grafo de código (graphify) ────────────────────────────────────────
# graphify-out/ no vive junto al repo: vive centralizado en la Matriz
# (workspaces/.graphify-data/, ver tools/sync-graph.sh) para no ensuciar cada
# PR con diffs de +100k líneas y porque la sesión que lo consulta vive en la
# raíz de la Matriz, no dentro de cada clon. Nadie lo reconstruye solo: no hay
# hook post-commit por repo (un clon aislado no comparte ese estado con la
# Matriz) — la única vía es correr ./sync-fleet.sh o tools/sync-graph.sh
# <clon> a mano. Por eso no basta con que graph.json exista: hay que medir de
# qué commit salió, comparando el sello .built-at-commit contra el HEAD real.
#
# Umbral: >5 commits CON cambios de código es CRITICAL — mismo número que usa
# S3 para el drift de claude-progress.md, una sola noción de "drift grave" en
# todo el arnés. Un desfase sin ficheros de código tocados (commits de
# documentación, de arnés...) no es un fallo: el grafo sigue describiendo el
# código real.
section "S6. Grafo de código"
GRAPH_DIR_S6="$MATRIX_ROOT/workspaces/.graphify-data/$REPO_NAME/graphify-out"
GRAPH_JSON_S6="$GRAPH_DIR_S6/graph.json"
GRAPH_MARCA_S6="$GRAPH_DIR_S6/.built-at-commit"
if command -v graphify >/dev/null 2>&1 && graphify --version >/dev/null 2>&1; then
  pass "S6" "graphify instalado y operativo"
  if [ -f "$GRAPH_JSON_S6" ]; then
    pass "S6" "graph.json presente (caché centralizada: workspaces/.graphify-data/$REPO_NAME/)"
    if [ ! -f "$GRAPH_MARCA_S6" ]; then
      warn "S6" "El grafo no lleva sello .built-at-commit — no se puede saber de qué commit salió (incógnita); correr tools/sync-graph.sh workspaces/$REPO_NAME"
    elif ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      warn "S6" "$REPO no es un repositorio git — no se puede medir la frescura del grafo (incógnita)"
    else
      SELLO_S6="$(tr -d '[:space:]' < "$GRAPH_MARCA_S6")"
      HEAD_S6="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "")"
      if [ -z "$SELLO_S6" ] || [ -z "$HEAD_S6" ]; then
        warn "S6" "Sello o HEAD ilegibles — frescura del grafo desconocida (incógnita)"
      elif ! git -C "$REPO" cat-file -e "${SELLO_S6}^{commit}" 2>/dev/null; then
        warn "S6" "El sello del grafo (${SELLO_S6}) no existe en este clon (¿shallow o rama distinta?) — frescura desconocida"
      else
        DETRAS_S6="$(git -C "$REPO" rev-list --count "${SELLO_S6}..HEAD" 2>/dev/null || echo "?")"
        if [ "$DETRAS_S6" = "?" ]; then
          warn "S6" "No se pudo contar el desfase del grafo (incógnita)"
        elif [ "$DETRAS_S6" = "0" ]; then
          pass "S6" "Grafo al día: sello == HEAD ($(echo "$SELLO_S6" | cut -c1-7))"
        else
          # Extensiones que graphify indexa en esta flota: Java (Spring Boot),
          # Python (api-search-engine), PHP (wordpress-plugin) y TS/JS (los
          # tres frontends: Next.js, Vite, Docusaurus).
          COD_S6="$(git -C "$REPO" diff --name-only "$SELLO_S6" HEAD -- \
            '*.java' '*.py' '*.php' '*.ts' '*.tsx' '*.js' '*.jsx' 2>/dev/null | wc -l | tr -d ' ')"
          if [ "${COD_S6:-0}" -eq 0 ]; then
            pass "S6" "Grafo $DETRAS_S6 commit(s) por detrás del HEAD pero con 0 ficheros de código tocados — sigue describiendo el código real"
          elif [ "$DETRAS_S6" -gt 5 ]; then
            fail_critical "S6" "Grafo desfasado: $DETRAS_S6 commits y $COD_S6 fichero(s) de código cambiados desde el sello ($(echo "$SELLO_S6" | cut -c1-7)) — el grafo miente; correr tools/sync-graph.sh workspaces/$REPO_NAME"
          else
            warn "S6" "Grafo desfasado: $DETRAS_S6 commit(s) y $COD_S6 fichero(s) de código cambiados desde el sello — refrescar con tools/sync-graph.sh workspaces/$REPO_NAME"
          fi
        fi
      fi
    fi
  else
    warn "S6" "Falta $GRAPH_JSON_S6 — sin grafo no hay orientación estructural; correr tools/sync-graph.sh workspaces/$REPO_NAME"
  fi
  if [ "$HAVE_JQ" -eq 1 ] && [ -f "$MATRIX_ROOT/repositories.json" ]; then
    if jq -e --arg n "$REPO_NAME" \
        '.projects[] | select(.name == $n) | .mcp_servers // [] | map(select(startswith("graphify"))) | length > 0' \
        "$MATRIX_ROOT/repositories.json" >/dev/null 2>&1; then
      pass "S6" "graphify declarado en mcp_servers de $REPO_NAME (repositories.json)"
    else
      warn "S6" "graphify no está en mcp_servers de $REPO_NAME en repositories.json — la sesión no sabrá que este repo tiene grafo"
    fi
  else
    warn "S6" "No se pudo comprobar mcp_servers en repositories.json (falta jq o el fichero)"
  fi
else
  warn "S6" "graphify no está instalado/operativo en esta máquina"
fi

# ── S7. Uso real de herramientas ──────────────────────────────────────────
# CLAUDE.md manda "orienta con el grafo/serena, no con grep", pero CLAUDE.md
# es contexto, no configuración: se cumple casi siempre y falla justo tras
# compactación y en subagentes. Aquí se mide, no se aconseja.
#
# La fuente es el JSONL append-only que escribe el hook PostToolUse que
# instala install-factory.sh (configure_tool_audit_hook): un objeto por
# tool-call con ts/session_id/cwd/tool_name.
#
# Severidad WARN a propósito: hay tareas donde grep es legítimamente mejor
# (buscar una cadena literal, contar ocurrencias). Lo que este check señala
# es el patrón caro — sesión larga de Bash sobre un repo con grafo y ni una
# sola consulta estructural — no un pecado por llamada.
section "S7. Uso real de herramientas"
AUDIT_LOG_S7="$HOME/.claude/audit/tool-calls.jsonl"
VENTANA_DIAS_S7=14
UMBRAL_BASH_S7=20
MAX_LINEAS_S7=200000
if [ "$HAVE_JQ" -ne 1 ]; then
  warn "S7" "jq no instalado — no se puede medir el uso de herramientas (incógnita, no verde)"
elif [ ! -f "$AUDIT_LOG_S7" ]; then
  warn "S7" "No existe $AUDIT_LOG_S7 (¿máquina nueva? correr ./install-factory.sh) — uso de herramientas: incógnita, no verde"
else
  # date -v (BSD/macOS) y date -d (GNU) no se solapan; se prueban los dos.
  SINCE_S7="$(date -u -v-${VENTANA_DIAS_S7}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "${VENTANA_DIAS_S7} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  if [ -z "$SINCE_S7" ]; then
    warn "S7" "No se pudo calcular la ventana de $VENTANA_DIAS_S7 días con este date(1) — incógnita"
  else
    # El primer jq filtra línea a línea y se traga una última línea a medio
    # escribir (el hook escribe en paralelo); sin él, un solo registro roto
    # tumbaría el slurp entero y el check mentiría por vacío.
    RESUMEN_S7="$(tail -n "$MAX_LINEAS_S7" "$AUDIT_LOG_S7" 2>/dev/null \
      | jq -c . 2>/dev/null \
      | jq -s -r --arg p "$REPO" --arg rn "$REPO_NAME" --arg since "$SINCE_S7" --argjson umbral "$UMBRAL_BASH_S7" '
          map(select((.ts // "") >= $since))
          | (map(select((.cwd == $p)
                        or ((.cwd // "") | startswith($p + "/"))
                        or ((.tool_input_summary // "") | contains("workspaces/" + $rn))))
             | map(.session_id) | unique) as $sids
          | map(select(.session_id as $s | $sids | index($s)))
          | group_by(.session_id)
          | map({bash: (map(select(.tool_name == "Bash")) | length),
                 est:  (map(select((.tool_name // "") | test("^mcp__(graphify|serena)"))) | length)})
          | (map(select(.bash >= $umbral))) as $densas
          | ($densas | map(select(.est == 0))) as $ciegas
          | "\(length) \($densas | length) \($ciegas | length) \(($ciegas | map(.bash) | add) // 0)"
        ' 2>/dev/null || true)"
    if [ -z "$RESUMEN_S7" ]; then
      warn "S7" "No se pudo agregar $AUDIT_LOG_S7 (¿log corrupto?) — uso de herramientas: incógnita, no verde"
    else
      read -r SES_S7 DENSAS_S7 CIEGAS_S7 BASH_CIEGO_S7 <<< "$RESUMEN_S7"
      if [ "${SES_S7:-0}" -eq 0 ]; then
        warn "S7" "Ninguna sesión atribuible a $REPO_NAME en los últimos $VENTANA_DIAS_S7 días — sin datos que medir (incógnita, no verde)"
      elif [ "${DENSAS_S7:-0}" -eq 0 ]; then
        warn "S7" "$SES_S7 sesión(es) sobre $REPO_NAME pero ninguna con ≥$UMBRAL_BASH_S7 Bash — muestra insuficiente (incógnita, no verde)"
      elif [ "${CIEGAS_S7:-0}" -eq 0 ]; then
        pass "S7" "$DENSAS_S7/$SES_S7 sesión(es) densas en los últimos $VENTANA_DIAS_S7 días y todas usaron grafo/serena"
      else
        warn "S7" "$CIEGAS_S7/$DENSAS_S7 sesión(es) densas sobre $REPO_NAME gastaron $BASH_CIEGO_S7 llamadas Bash con CERO consultas a graphify/serena (últimos $VENTANA_DIAS_S7 días) — el grafo existe y nadie lo mira"
      fi
    fi
  fi
fi

# ── Resumen ────────────────────────────────────────────────────────────────
echo ""
echo "=== Resumen ==="
echo "Checks totales: $TOTAL | CRITICAL fallidos: $CRITICAL_FAIL | RECOMMENDED en warn: $RECOMMENDED_WARN"
if [ "$CRITICAL_FAIL" -eq 0 ]; then
  echo "✅ Arnés en verde (todos los CRITICAL pasan)."
  exit 0
else
  echo "❌ Arnés incompleto: $CRITICAL_FAIL check(s) CRITICAL en fallo."
  exit 1
fi
