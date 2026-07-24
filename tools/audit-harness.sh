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
      grep -q "^build/" "$REPO/.gitignore" 2>/dev/null && pass "S5" ".gitignore cubre build/" || warn "S5" ".gitignore no cubre build/ explícitamente"
      ;;
    maven)
      grep -q "^target/" "$REPO/.gitignore" 2>/dev/null && pass "S5" ".gitignore cubre target/" || warn "S5" ".gitignore no cubre target/ explícitamente"
      ;;
    node|next)
      grep -q "node_modules" "$REPO/.gitignore" 2>/dev/null && pass "S5" ".gitignore cubre node_modules" || warn "S5" ".gitignore no cubre node_modules explícitamente"
      ;;
    python)
      grep -qE "__pycache__|\.venv|venv/" "$REPO/.gitignore" 2>/dev/null && pass "S5" ".gitignore cubre entornos/artefactos Python" || warn "S5" ".gitignore no cubre __pycache__/venv explícitamente"
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
section "S6. Grafo de código"
if command -v graphify >/dev/null 2>&1 && graphify --version >/dev/null 2>&1; then
  pass "S6" "graphify instalado y operativo"
  if [ -f "$REPO/graphify-out/graph.json" ]; then
    pass "S6" "graph.json presente (graphify-out/)"
    if (cd "$REPO" && graphify hook status 2>/dev/null | grep -q "not installed"); then
      warn "S6" "Hooks de auto-actualización del grafo no instalados (correr tools/sync-graph.sh)"
    else
      pass "S6" "Hooks de auto-actualización instalados (post-commit/post-checkout + merge driver)"
    fi
  else
    warn "S6" "Falta graphify-out/graph.json — correr tools/sync-graph.sh"
  fi
else
  warn "S6" "graphify no está instalado/operativo en esta máquina"
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
