#!/bin/bash
# tools/audit-harness.sh — Auditor de arnés para la flota Neuroon.
# Inspirado (no vendorizado) en walkinglabs/learn-harness-engineering (MIT).
# Zero-dependencia: bash + jq. Sin jq, los checks que dependen de él pasan a
# INCÓGNITA (no medir no es verde), no a WARN.
#
# Uso:
#   ./tools/audit-harness.sh [ruta]      # audita ./ o la ruta dada
#
# Exit code:
#   0 = verde (todos los CRITICAL pasan y todo lo demás se pudo medir)
#   1 = algún check CRITICAL en fallo
#   2 = sin CRITICAL en fallo, pero hay checks que NO se pudieron medir
set -euo pipefail

# MATRIX_ROOT/REPO_NAME: desde que se trabaja con una sesión Claude única en
# la raíz de la Matriz (no un worker por repo), el grafo de código vive
# centralizado fuera del repo (workspaces/.graphify-data/, ver
# tools/sync-graph.sh) — S6 necesita saber dónde está la Matriz para
# encontrarlo, sea cual sea la ruta que se le pase a este script.
MATRIX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Raíz de DATOS (workspaces/), distinta de la raíz de CÓDIGO. Sin esto, desde
# un git worktree secundario S6 reportaba "falta graph.json" para repos cuyo
# grafo existe y está al día, y recomendaba reconstruir algo que está bien.
FLEET_ROOT="$MATRIX_ROOT"
if command -v git >/dev/null 2>&1; then
  _main_wt="$( { git -C "$MATRIX_ROOT" worktree list --porcelain 2>/dev/null || true; } \
               | sed -n '1s/^worktree //p' )"
  if [ -n "$_main_wt" ] && [ -d "$_main_wt" ] && [ -f "$_main_wt/repositories.json" ]; then
    FLEET_ROOT="$_main_wt"
  fi
  unset _main_wt
fi

REPO="${1:-.}"
# Un argumento relativo que no exista en el cwd se resuelve contra la raíz de
# DATOS, igual que en tools/sync-graph.sh: si no, el comando que este mismo
# arnés prescribe ("./tools/audit-harness.sh workspaces/<repo>") fallaría con
# "no existe el directorio" justo desde un worktree secundario, que es el
# contexto que todo esto existe para arreglar.
[ -d "$REPO" ] || REPO="$FLEET_ROOT/$REPO"
if [ ! -d "$REPO" ]; then
  echo "❌ No existe el directorio: $REPO"
  exit 1
fi
REPO="$(cd "$REPO" && pwd)"
REPO_NAME="$(basename "$REPO")"

CRITICAL_FAIL=0
RECOMMENDED_WARN=0
INCOGNITAS=0
TOTAL=0

pass()          { TOTAL=$((TOTAL+1)); echo "  ✅ PASS  [$1] $2"; }
fail_critical() { TOTAL=$((TOTAL+1)); CRITICAL_FAIL=$((CRITICAL_FAIL+1)); echo "  ❌ FAIL  [$1] $2 (CRITICAL)"; }
warn()          { TOTAL=$((TOTAL+1)); RECOMMENDED_WARN=$((RECOMMENDED_WARN+1)); echo "  ⚠️  WARN  [$1] $2 (RECOMMENDED)"; }
# Tercera categoría, distinta de WARN a propósito: un check que NO SE PUDO
# MEDIR no es una recomendación pendiente, es un agujero en la medición. Antes
# todo esto era WARN, y como el veredicto final solo miraba CRITICAL_FAIL, una
# máquina sin jq, sin git, sin graphify y sin log de auditoría imprimía
# "✅ Arnés en verde" y salía 0 — la regla que el repo dice no negociar
# ("no pude medir" es una incógnita, nunca un verde), rota en el agregado.
incognita()     { TOTAL=$((TOTAL+1)); INCOGNITAS=$((INCOGNITAS+1)); echo "  ❔ INCÓGNITA [$1] $2 (NO MEDIBLE)"; }
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
    incognita "S2" "jq no instalado — omitiendo validación de feature_list.json"
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
          incognita "S3" "No se pudo medir el drift del progress (¿HEAD declarado en otra rama?)"
        elif [ "$AHEAD" -gt 5 ]; then
          fail_critical "S3" "Drift grave: $AHEAD commits desde el HEAD declarado en claude-progress.md sin registro de sesión"
        else
          warn "S3" "Drift: $AHEAD commit(s) desde el HEAD declarado en claude-progress.md — actualizar el registro de sesión"
        fi
      else
        incognita "S3" "El sha declarado en claude-progress.md ($DECLARED_SHA) no existe en este clon (¿shallow o rama distinta?)"
      fi
    else
      # Antes esta rama y la de abajo no emitían NADA: el detector de drift se
      # saltaba entero y en silencio, y el resumen seguía diciendo verde. S5 y
      # S6 sí avisan en el caso equivalente.
      incognita "S3" "claude-progress.md no declara ningún HEAD entre backticks — no se puede medir el drift"
    fi
  else
    incognita "S3" "$REPO no es un repositorio git — no se puede medir el drift de claude-progress.md"
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
  incognita "S5" "$REPO no es un repositorio git (no se pudo comprobar secretos versionados)"
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
GRAPH_DIR_S6="$FLEET_ROOT/workspaces/.graphify-data/$REPO_NAME/graphify-out"
GRAPH_JSON_S6="$GRAPH_DIR_S6/graph.json"
GRAPH_MARCA_S6="$GRAPH_DIR_S6/.built-at-commit"
if command -v graphify >/dev/null 2>&1 && graphify --version >/dev/null 2>&1; then
  pass "S6" "graphify instalado y operativo"
  if [ -f "$GRAPH_JSON_S6" ]; then
    pass "S6" "graph.json presente (caché centralizada: workspaces/.graphify-data/$REPO_NAME/)"
    if [ ! -f "$GRAPH_MARCA_S6" ]; then
      incognita "S6" "El grafo no lleva sello .built-at-commit — no se puede saber de qué commit salió (incógnita); correr tools/sync-graph.sh workspaces/$REPO_NAME"
    elif ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      incognita "S6" "$REPO no es un repositorio git — no se puede medir la frescura del grafo (incógnita)"
    else
      SELLO_S6="$(tr -d '[:space:]' < "$GRAPH_MARCA_S6")"
      HEAD_S6="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "")"
      if [ -z "$SELLO_S6" ] || [ -z "$HEAD_S6" ]; then
        incognita "S6" "Sello o HEAD ilegibles — frescura del grafo desconocida (incógnita)"
      elif ! git -C "$REPO" cat-file -e "${SELLO_S6}^{commit}" 2>/dev/null; then
        incognita "S6" "El sello del grafo (${SELLO_S6}) no existe en este clon (¿shallow o rama distinta?) — frescura desconocida"
      else
        DETRAS_S6="$(git -C "$REPO" rev-list --count "${SELLO_S6}..HEAD" 2>/dev/null || echo "?")"
        if [ "$DETRAS_S6" = "?" ]; then
          incognita "S6" "No se pudo contar el desfase del grafo (incógnita)"
        elif [ "$DETRAS_S6" = "0" ]; then
          pass "S6" "Grafo al día: sello == HEAD ($(echo "$SELLO_S6" | cut -c1-7))"
        else
          # Extensiones que graphify indexa en esta flota: Java (Spring Boot),
          # Python (api-search-engine), PHP (wordpress-plugin) y TS/JS (los
          # tres frontends: Next.js, Vite, Docusaurus).
          # El rc del pipeline SÍ se comprueba, igual que en
          # tools/guard-graph-fresh.sh y tools/session-brief.sh: `git diff |
          # wc -l` da 0 cuando el diff falla, y aquí 0 significa "el grafo
          # sigue describiendo el código real". Un fallo de medición no puede
          # parecerse a una medición tranquilizadora.
          if ! COD_S6="$(git -C "$REPO" diff --name-only "$SELLO_S6" HEAD -- \
            '*.java' '*.py' '*.php' '*.ts' '*.tsx' '*.js' '*.jsx' 2>/dev/null | wc -l | tr -d ' ')"; then
            incognita "S6" "No se pudo comparar el sello ($(echo "$SELLO_S6" | cut -c1-7)) contra HEAD — frescura del grafo desconocida"
            COD_S6=""
          fi
          if [ -z "$COD_S6" ]; then
            :
          elif [ "${COD_S6:-0}" -eq 0 ]; then
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
    incognita "S6" "No se pudo comprobar mcp_servers en repositories.json (falta jq o el fichero)"
  fi
else
  incognita "S6" "graphify no está instalado/operativo en esta máquina"
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
# La ventana se calcula una sola vez y ANTES de la cadena de ifs: la usan dos
# mediciones independientes (tool-calls.jsonl y symbol-search-misses.log), y
# dejarla dentro de una rama hacía que la segunda dijese "sin ventana
# temporal" cuando el problema real era otro.
# date -v (BSD/macOS) y date -d (GNU) no se solapan; se prueban los dos.
SINCE_S7="$(date -u -v-${VENTANA_DIAS_S7}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "${VENTANA_DIAS_S7} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
if [ "$HAVE_JQ" -ne 1 ]; then
  incognita "S7" "jq no instalado — no se puede medir el uso de herramientas (incógnita, no verde)"
elif [ ! -f "$AUDIT_LOG_S7" ]; then
  incognita "S7" "No existe $AUDIT_LOG_S7 (¿máquina nueva? correr ./install-factory.sh) — uso de herramientas: incógnita, no verde"
else
  if [ -z "$SINCE_S7" ]; then
    incognita "S7" "No se pudo calcular la ventana de $VENTANA_DIAS_S7 días con este date(1) — incógnita"
  else
    # OJO con el saneado: `jq -c .` NO se salta los registros ilegibles, se
    # PARA en el primero y descarta todo lo que venga detrás (medido: 3
    # objetos válidos + 1 basura -> sobrevive 1). En un log append-only lo
    # que se pierde es lo más RECIENTE, justo las sesiones que se quieren
    # medir, y el resultado parcial se presentaría como la ventana entera.
    # Por eso se comprueba su código de salida: un log con basura es una
    # incógnita, no una medición.
    SANEADO_S7="$(mktemp)"
    trap 'rm -f "$SANEADO_S7"' EXIT
    # `RC=$?` detrás de un pipeline DESNUDO no sirve con `set -e` (línea 10):
    # el script muere en el pipeline y esa línea no llega a ejecutarse nunca
    # — el rc queda sin leer y toda la rama de abajo sería código muerto. El
    # `|| RC=$?` mete el pipeline en contexto probado, que es lo que `set -e`
    # respeta. Mismo patrón que sync-fleet.sh y deploy-worker.sh.
    JQ_RC_S7=0
    { tail -n "$MAX_LINEAS_S7" "$AUDIT_LOG_S7" 2>/dev/null | jq -c . > "$SANEADO_S7" 2>/dev/null; } || JQ_RC_S7=$?
    if [ "$JQ_RC_S7" -ne 0 ]; then
      incognita "S7" "$AUDIT_LOG_S7 tiene registros no parseables: jq se para ahí y descarta todo lo posterior, así que la medición sería sobre un prefijo del log, no sobre la ventana de $VENTANA_DIAS_S7 días"
      RESUMEN_S7=""
    else
    RESUMEN_S7="$(jq -s -r --arg p "$REPO" --arg rn "$REPO_NAME" --arg since "$SINCE_S7" --argjson umbral "$UMBRAL_BASH_S7" '
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
        ' < "$SANEADO_S7" 2>/dev/null || true)"
    fi
    rm -f "$SANEADO_S7"
    # El caso jq_rc != 0 ya emitió su propia incógnita: no contarlo dos veces.
    if [ "$JQ_RC_S7" -ne 0 ]; then
      :
    elif [ -z "$RESUMEN_S7" ]; then
      incognita "S7" "No se pudo agregar $AUDIT_LOG_S7 (¿log corrupto?) — uso de herramientas: incógnita, no verde"
    else
      read -r SES_S7 DENSAS_S7 CIEGAS_S7 BASH_CIEGO_S7 <<< "$RESUMEN_S7"
      if [ "${SES_S7:-0}" -eq 0 ]; then
        incognita "S7" "Ninguna sesión atribuible a $REPO_NAME en los últimos $VENTANA_DIAS_S7 días — sin datos que medir (incógnita, no verde)"
      elif [ "${DENSAS_S7:-0}" -eq 0 ]; then
        incognita "S7" "$SES_S7 sesión(es) sobre $REPO_NAME pero ninguna con ≥$UMBRAL_BASH_S7 Bash — muestra insuficiente (incógnita, no verde)"
      elif [ "${CIEGAS_S7:-0}" -eq 0 ]; then
        pass "S7" "$DENSAS_S7/$SES_S7 sesión(es) densas en los últimos $VENTANA_DIAS_S7 días y todas usaron grafo/serena"
      else
        warn "S7" "$CIEGAS_S7/$DENSAS_S7 sesión(es) densas sobre $REPO_NAME gastaron $BASH_CIEGO_S7 llamadas Bash con CERO consultas a graphify/serena (últimos $VENTANA_DIAS_S7 días) — el grafo existe y nadie lo mira"
      fi
    fi
  fi
fi

# El log de avisos de enrutado que escribe tools/guard-symbol-search.sh. Hasta
# ahora nadie lo leía: ese hook, CLAUDE.md y README.md prometían los tres que
# S7 "agrega ese conteo a lo largo de las sesiones, para que se use el MCP de
# verdad sea un número medido y no una impresión", y S7 solo abría
# tool-calls.jsonl. Un número prometido que nadie calcula es un verde por
# ausencia de medición.
MISS_LOG_S7="$HOME/.claude/audit/symbol-search-misses.log"
if [ -z "${SINCE_S7:-}" ]; then
  incognita "S7" "Sin ventana temporal calculada — no se pueden contar los avisos de guard-symbol-search"
elif [ ! -f "$MISS_LOG_S7" ]; then
  incognita "S7" "No existe $MISS_LOG_S7 — avisos de enrutado de guard-symbol-search: no medibles"
else
  # Formato del log: <timestamp ISO-8601 UTC>\t<sufijo de repo>. Comparación
  # lexicográfica, que en ISO-8601 con Z equivale a la cronológica.
  MISSES_S7="$(awk -F'\t' -v s="$SINCE_S7" '$1 >= s {n++} END {print n+0}' "$MISS_LOG_S7" 2>/dev/null || echo "")"
  if [ -z "$MISSES_S7" ]; then
    incognita "S7" "No se pudo contar $MISS_LOG_S7 — avisos de enrutado: incógnita, no verde"
  elif [ "$MISSES_S7" -eq 0 ]; then
    pass "S7" "0 avisos de guard-symbol-search en los últimos $VENTANA_DIAS_S7 días"
  else
    warn "S7" "$MISSES_S7 búsqueda(s) de símbolo por grep/find en toda la flota pudiendo usar serena (últimos $VENTANA_DIAS_S7 días) — ver $MISS_LOG_S7"
  fi
fi

# ── Resumen ────────────────────────────────────────────────────────────────
echo ""
echo "=== Resumen ==="
echo "Checks totales: $TOTAL | CRITICAL fallidos: $CRITICAL_FAIL | RECOMMENDED en warn: $RECOMMENDED_WARN | INCÓGNITAS: $INCOGNITAS"
if [ "$CRITICAL_FAIL" -gt 0 ]; then
  echo "❌ Arnés incompleto: $CRITICAL_FAIL check(s) CRITICAL en fallo."
  exit 1
elif [ "$INCOGNITAS" -gt 0 ]; then
  echo "❔ Arnés SIN VERDE: $INCOGNITAS check(s) no se pudieron medir — no medir no es verde."
  exit 2
else
  echo "✅ Arnés en verde (todos los CRITICAL pasan y todo lo demás se pudo medir)."
  exit 0
fi
