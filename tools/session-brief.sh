#!/bin/bash
# tools/session-brief.sh — hook SessionStart de la Matriz.
#
# Por qué existe: la documentación oficial es explícita en que CLAUDE.md es
# CONTEXTO, no configuración, y en campo se mide que las sesiones vuelven a
# bash/grep sobre todo (a) tras una compactación y (b) en subagentes. Un
# fichero que se lee una vez al arrancar no sobrevive a eso; un hook
# SessionStart con matcher `compact` sí se vuelve a ejecutar.
#
# Qué hace: imprime el estado REAL de la flota (HEAD, frescura del grafo) y
# la tabla tarea→herramienta, y lo devuelve como additionalContext. Solo
# mide, no decide: si algo no se puede medir se dice, nunca se da por bueno.
#
# Nunca falla duro: un hook roto no puede impedir trabajar. Pero "no fallar
# duro" NO es lo mismo que callarse: si este script no puede generar el
# brief, emite un JSON válido que lo DICE, en vez de un {} que deja a la
# sesión sin estado y sin saber que le falta.
set -uo pipefail

MATRIX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Raíz de DATOS (workspaces/, .env), distinta de la raíz de CÓDIGO/config.
# Un git worktree secundario no tiene workspaces/ ni .env (gitignorados, no
# viajan), así que anclar los datos en $0 hacía que este brief afirmara en
# positivo que los 6 repos NO están clonados y que los 4 tokens están
# VACÍOS, siendo ambas cosas falsas. `git worktree list --porcelain` lista
# SIEMPRE el worktree principal el primero y en ruta absoluta. Sin git, fuera
# de un repo, o si el candidato no valida, se queda en MATRIX_ROOT.
FLEET_ROOT="$MATRIX_ROOT"
if command -v git >/dev/null 2>&1; then
  _main_wt="$( { git -C "$MATRIX_ROOT" worktree list --porcelain 2>/dev/null || true; } \
               | sed -n '1s/^worktree //p' )"
  if [ -n "$_main_wt" ] && [ -d "$_main_wt" ] && [ -f "$_main_wt/repositories.json" ]; then
    FLEET_ROOT="$_main_wt"
  fi
  unset _main_wt
fi

WORKSPACES="$FLEET_ROOT/workspaces"

# Los repos de código salen de repositories.json (la "Verdad Absoluta" según
# CLAUDE.md), no de una lista escrita a mano: un repo nuevo declarado en el
# manifiesto tiene que aparecer aquí solo. Son los que declaran un servidor
# graphify-*; "status" (Upptime) no tiene código propio y queda fuera.
repos_de_codigo() {
  command -v jq >/dev/null 2>&1 || return 1
  jq -r '.projects[]
         | select((.mcp_servers // []) | map(select(startswith("graphify"))) | length > 0)
         | .name' "$MATRIX_ROOT/repositories.json" 2>/dev/null
}

# Dónde viven las decisiones ya cerradas. Se miden DOS cosas por separado: las
# que están en la rama por defecto y las que solo existen en una rama remota
# sin mergear. Un documento que decide y no está en el árbol de trabajo es una
# decisión invisible: no aparece por grep, y quien no la ve construye encima.
decisiones_cerradas() {
  local repo ruta rama doc encontrados sueltos
  encontrados=""
  sueltos=""
  for repo in $(repos_de_codigo); do
    ruta="$WORKSPACES/$repo"
    [ -e "$ruta/.git" ] || continue
    rama="$(git -C "$ruta" symbolic-ref --quiet --short HEAD 2>/dev/null || echo HEAD)"
    for doc in $(git -C "$ruta" ls-tree -r --name-only HEAD 2>/dev/null \
                 | grep -E '^docs/(adr|superpowers/specs)/.*\.md$' | head -12); do
      encontrados="${encontrados}  - $repo [$rama]: $doc"$'\n'
    done
    # Ficheros AUSENTES de HEAD que existen en alguna rama remota. Con `git diff`
    # salían también los que están en ambos lados y solo difieren: un aviso con
    # falsos positivos se acaba ignorando, que es lo contrario de lo que esta
    # sección busca. Se comparan las dos listas de nombres.
    for doc in $(comm -13 \
                   <(git -C "$ruta" ls-tree -r --name-only HEAD 2>/dev/null \
                     | grep -E '^docs/(adr|superpowers/specs)/.*\.md$' | sort -u) \
                   <(git -C "$ruta" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null \
                     | while read -r ref; do
                         git -C "$ruta" ls-tree -r --name-only "$ref" 2>/dev/null \
                           | grep -E '^docs/(adr|superpowers/specs)/.*\.md$'
                       done | sort -u) | head -8); do
      sueltos="${sueltos}  - $repo: $doc — DECIDE algo y NO está en tu árbol (vive en una rama remota)"$'\n'
    done
  done
  [ -n "$encontrados" ] && printf '%s' "$encontrados"
  if [ -n "$sueltos" ]; then
    printf '\n  DECISIONES QUE NO VES DESDE AQUÍ:\n%s' "$sueltos"
  fi
  [ -n "$encontrados$sueltos" ] || echo "  - INCÓGNITA: no se pudo listar ningún documento de decisiones"
}

estado_de_los_grafos() {
  local repo ruta head sello desfase codigo lista
  lista="$(repos_de_codigo)"
  if [ -z "$lista" ]; then
    echo "  - INCÓGNITA: no se pudo leer la lista de repos de $MATRIX_ROOT/repositories.json (¿falta jq?) — el estado de los grafos es DESCONOCIDO, no vacío"
    return
  fi
  for repo in $lista; do
    ruta="$WORKSPACES/$repo"
    if [ ! -e "$ruta/.git" ]; then
      echo "  - $repo: NO CLONADO en $ruta (corre ./sync-fleet.sh)"
      continue
    fi
    head="$(git -C "$ruta" rev-parse HEAD 2>/dev/null || echo "")"
    sello="$(cat "$WORKSPACES/.graphify-data/$repo/graphify-out/.built-at-commit" 2>/dev/null || echo "")"
    if [ -z "$head" ]; then
      echo "  - $repo: HEAD ilegible — INCÓGNITA, no asumas nada"
    elif [ -z "$sello" ]; then
      # Sin sello no hay nada que comparar, haya o no graph.json: se pide
      # construir. Este caso va ANTES que el de "solo está el sello" porque un
      # repo recién nacido (sin código indexable todavía) no tiene ni sello ni
      # grafo, y antes se anunciaba "solo está el sello" de un sello que no
      # existía.
      echo "  - $repo: HEAD ${head:0:7} · grafo SIN CONSTRUIR -> ./tools/sync-graph.sh workspaces/$repo"
    elif [ ! -f "$WORKSPACES/.graphify-data/$repo/graphify-out/graph.json" ]; then
      # El sello por sí solo no basta: si el graph.json no está, comparar
      # sellos diría "al día" de un grafo que no existe. Y graphify-mcp
      # arranca igual sin él y devuelve el error con isError=false (medido),
      # así que nada más lo delataría. Misma guarda que guard-graph-fresh.sh.
      echo "  - $repo: HEAD ${head:0:7} · el grafo NO EXISTE (solo está el sello) -> ./tools/sync-graph.sh workspaces/$repo"
    elif [ "$sello" = "$head" ]; then
      echo "  - $repo: HEAD ${head:0:7} · grafo al día"
    elif ! git -C "$ruta" cat-file -e "${sello}^{commit}" 2>/dev/null; then
      # Sello huérfano (rebase/force, o el centinela "sin-git" de una versión
      # vieja de sync-graph.sh). Sin este caso, el `git diff` de abajo falla,
      # `wc -l` cuenta 0, y un grafo IMPOSIBLE de comparar se anunciaba como
      # "sirve igual". No medir no es verde.
      echo "  - $repo: HEAD ${head:0:7} · el sello ${sello:0:7} NO existe en este clon (rebase/force) — INCÓGNITA, no se puede medir la frescura -> ./tools/sync-graph.sh workspaces/$repo"
    else
      desfase="$(git -C "$ruta" rev-list --count "$sello".."$head" 2>/dev/null || echo "?")"
      if ! codigo="$(git -C "$ruta" diff --name-only "$sello" "$head" -- '*.java' '*.py' '*.php' '*.ts' '*.tsx' '*.js' '*.jsx' 2>/dev/null | wc -l | tr -d ' ')"; then
        echo "  - $repo: HEAD ${head:0:7} · no se pudo comparar contra el sello ${sello:0:7} — INCÓGNITA, no verde -> ./tools/sync-graph.sh workspaces/$repo"
      elif [ "${codigo:-0}" -gt 0 ]; then
        echo "  - $repo: HEAD ${head:0:7} · grafo ${sello:0:7}, $desfase commit(s) y $codigo fichero(s) de código por detrás -> RECONSTRUIR antes de fiarte"
      else
        echo "  - $repo: HEAD ${head:0:7} · grafo ${sello:0:7}, $desfase commit(s) por detrás pero SIN cambios de código: sirve igual"
      fi
    fi
  done
}

# MCPs de infraestructura (.mcp.json + .env). Del token solo se mide su
# PRESENCIA — su valor no se imprime jamás, solo su longitud. Ademas se
# comprueban los prerrequisitos que hacen fallar el arranque (docker para los
# que corren en contenedor): con el token puesto y el prerrequisito roto, el
# server muere y la sesion se queda sin sus tools. Aun asi esto NO prueba que
# arranque: la prueba es que las tools aparezcan (ToolSearch).
estado_de_la_infra() {
  local nombre server var largo cuenta ENV_FILE
  if ! command -v jq >/dev/null 2>&1 || ! jq -e . "$MATRIX_ROOT/.mcp.json" >/dev/null 2>&1; then
    echo "  - INCÓGNITA: no se pudo leer $MATRIX_ROOT/.mcp.json (¿falta jq o el JSON está roto?) — el estado de los MCP de infra es DESCONOCIDO, no vacío"
    return
  fi
  # El .env vive con los datos, no con el código: .mcp.json lo carga por ruta
  # absoluta, así que medir el del worktree diría "vacío" de tokens que sí
  # están puestos.
  ENV_FILE="$FLEET_ROOT/.env"
  for entrada in "coolify:COOLIFY_MCP_TOKEN:Coolify oficial (read; exige instancia >=4.1 + toggle MCP)" \
                 "coolify-ops:COOLIFY_ACCESS_TOKEN:Coolify ops StuMason (restart/deploy/logs)" \
                 "hetzner:HETZNER_API_TOKEN:Hetzner Cloud lazyants (snapshot/reboot/firewall)" \
                 "stripe:STRIPE_RESTRICTED_KEY:Stripe oficial mcp.stripe.com (restricted key, sin conector)" \
                 "sonarqube:SONARQUBE_TOKEN:SonarQube oficial en contenedor (quality gate, issues y HOTSPOTS de una PR)"; do
    server="${entrada%%:*}"
    var="$(echo "$entrada" | cut -d: -f2)"
    nombre="${entrada#*:*:}"
    if ! jq -e ".mcpServers.\"$server\"" "$MATRIX_ROOT/.mcp.json" >/dev/null 2>&1; then
      echo "  - $server: NO declarado en .mcp.json — $nombre"
      continue
    fi
    if [ ! -f "$ENV_FILE" ]; then
      echo "  - $server: declarado, pero no encuentro $ENV_FILE — INCÓGNITA: no se puede saber si $var tiene valor (NO asumas que está vacío)"
      continue
    fi
    largo="$(awk -F= -v k="$var" 'index($0, k"=") == 1 {v=substr($0, length(k)+2); gsub(/^['"'"'"]|['"'"'"]$/, "", v); print length(v); exit}' "$ENV_FILE" 2>/dev/null)"
    if [ "${largo:-0}" -gt 0 ]; then
      # Un token puesto NO implica que el server arranque. Los que corren en
      # contenedor mueren sin daemon de docker, y el 2026-08-17 eso dejo a la
      # sesion sin las tools de Sonar mientras el brief las daba por buenas.
      if [ "$server" = "sonarqube" ] && ! docker info >/dev/null 2>&1; then
        echo "  - $server: $var relleno, pero el DAEMON DE DOCKER no responde — corre en contenedor, asi que NO levantara"
        continue
      fi
      echo "  - $server: declarado y $var relleno en .env — $nombre"
    else
      echo "  - $server: declarado pero $var VACÍO en .env — no levantará; rellena .env (ver .env.example) y reinicia"
    fi
  done
  if jq -e '.mcpServers.gcloud' "$MATRIX_ROOT/.mcp.json" >/dev/null 2>&1; then
    cuenta="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
    if [ -n "$cuenta" ]; then
      echo "  - gcloud: declarado y gcloud autenticado ($cuenta) — Cloud Build/Artifact Registry vía allowlist (tools/gcloud-mcp-allow.json)"
    else
      echo "  - gcloud: declarado pero SIN cuenta gcloud activa — corre 'gcloud auth login' y reinicia"
    fi
  else
    echo "  - gcloud: NO declarado en .mcp.json"
  fi
  echo "  (esto mide credenciales y prerrequisitos, no que el server haya arrancado: si necesitas uno, comprueba"
  echo "   con ToolSearch que sus tools existen antes de darlo por disponible)"
}

# Los servidores declarados se MIDEN leyendo .mcp.json. Antes había aquí un
# párrafo fechado a mano ("Estado real de los MCP (2026-08-07)") en medio de
# un brief que se define a sí mismo como "solo mide, no decide": justo la
# clase de dato que CLAUDE.md ordena medir y no redactar.
SERVIDORES="$(jq -r '.mcpServers | keys | join(", ")' "$MATRIX_ROOT/.mcp.json" 2>/dev/null || true)"
[ -n "$SERVIDORES" ] || SERVIDORES="INCÓGNITA: no se pudo leer $MATRIX_ROOT/.mcp.json"

BRIEF="$(cat <<EOF
# Estado de la flota Neuroon (medido por tools/session-brief.sh)

Raíz de datos medida (workspaces/, .env): $FLEET_ROOT
Raíz de código/config (scripts, .mcp.json): $MATRIX_ROOT

$(estado_de_los_grafos)

# MCPs de infraestructura (medido: declaración + credencial + prerrequisitos)

$(estado_de_la_infra)

# Enrutado obligatorio de tarea → herramienta

Tienes MCPs que rinden mucho más que grep/bash para estas tareas. Úsalos:

| Si la tarea es… | Usa | No uses |
|---|---|---|
| Entender la forma de un repo que no conoces | \`mcp__graphify-<repo>__graph_stats\`, \`god_nodes\` | leer ficheros al azar |
| Saber a qué afecta tocar un símbolo | \`mcp__graphify-<repo>__get_community\`, \`get_neighbors\` | grep a ciegas |
| Localizar/renombrar un símbolo, CONTAR sus usos | \`mcp__serena-<repo>__find_symbol\`, \`find_referencing_symbols\`, \`rename_symbol\` (ver nota de abajo) | sed, edición a mano |
| Verificar un cambio en api-search-neuroon o neuroon-customer-api | \`./mvnw verify\` dentro de workspaces/<repo> | dar por bueno que compila |
| Verificar un cambio en un frontend (Next.js/Vite/Docusaurus) | \`npm run build\`/\`npm test\` dentro de ese repo | dar por bueno que compila |
| Verificar api-search-engine (Python) | \`pytest\` dentro de workspaces/api-search-engine | dar por bueno que corre |
| Buscar texto literal, contar ocurrencias | grep / rg | el grafo (subreporta, ver abajo) |
| Ver qué hay desplegado en la plataforma (apps, estado, deploys) | \`mcp__coolify__*\` (oficial, read) | SSH, curl a la API a mano |
| Operar la plataforma (restart, redeploy, logs, envs) | \`mcp__coolify-ops__*\` | SSH a pelo |
| La máquina Hetzner (snapshot pre-update, reboot, firewall) | \`mcp__hetzner__*\` | CLI (decidido: no se usa) |
| Consultar Stripe live (suscripciones, invoices, webhooks, prices) | \`mcp__stripe__*\` (oficial, restricted key) | el conector de claude.ai (deprecado aquí), curl a mano |
| El pipeline de deploys en GCP (builds, logs, Artifact Registry) | \`mcp__gcloud__*\` (allowlist builds/artifacts; --format SIN espacios) | gcloud a pelo en Bash |

**SSH al servidor es break-glass**, no gestión: solo si el SO está roto y
ningún MCP llega, y siempre contándoselo al humano primero.

**Sufijo por repo**: \`-api\` = api-search-neuroon · \`-app\` = app-search-neuroon ·
\`-widget\` = app-search-widget-neuroon · \`-docs\` = docs-search-widget-neuroon ·
\`-wp\` = wordpress-plugin-neuroon-search · \`-engine\` = api-search-engine ·
\`-cdp\` = neuroon-customer-api (el CDP, Spring Boot como el monolito).
Además, \`serena\` a secas apunta al código de la propia Matriz.

**Servidores declarados ahora mismo en \`.mcp.json\`** (medido, no redactado):
$SERVIDORES

**Si no ves un servidor que esta lista nombra**, tu sesión es anterior a su
alta: los MCP se fijan al arrancar y no se aplican en caliente. Compruébalo
con ToolSearch antes de concluir que está roto, y si falta, reinicia la
sesión en vez de buscarte la vida con bash.

**El grafo tiene límites, no lo cites a ciegas**: sirve para forma,
comunidades y radio de impacto — no para CONTAR o localizar llamadores con
precisión (la inyección de dependencias vía constructor, muy usada en
api-search-neuroon, no siempre se ve en el grafo). Para eso, grep o
\`find_referencing_symbols\` de serena.

# Reglas que no se negocian

1. Toda afirmación sobre código existente lleva fichero:línea verificado en ESTA sesión.
2. \`feature_list.json\` solo admite \`verified\` si TÚ ejecutaste la verificación y la viste pasar.
3. "No pude medir" es una incógnita, nunca un verde.
4. Ante ambigüedad de producto, pregunta al humano en vez de elegir por él.
5. **Antes de proponer o implementar arquitectura, LEE las decisiones ya cerradas** de la lista de arriba —
   enteras, no en diagonal, y las de las ramas remotas también. Proponer algo que un documento ya descartó
   cuesta más que no proponer nada: se construye encima y deshacerlo sale caro. Si una decisión falta,
   pregunta; si la vas a contradecir, dilo explícitamente y justifícalo.

# Decisiones ya cerradas — dónde viven (medido, no redactado)

$(decisiones_cerradas)
EOF
)"

# Si el encoder falla (falta python3, etc.) NO se emite {}: eso dejaba a la
# sesión sin estado de flota y sin ningún aviso, y la ausencia de avisos se
# lee como "todo bien". "Un hook roto no puede impedir trabajar" se cumple
# con cualquier JSON válido; no obliga a callar.
printf '%s' "$BRIEF" | python3 -c '
import json,sys
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.stdin.read()}}))
' 2>/dev/null || printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"session-brief.sh no pudo generar el brief (falta python3 o fallo del encoder). El estado de la flota es DESCONOCIDO en esta sesion: no asumas que los grafos estan al dia ni que los MCP estan arriba, y no des por buena ninguna afirmacion sobre la flota sin medirla tu. Arregla el arnes antes de fiarte de nada."}}'
