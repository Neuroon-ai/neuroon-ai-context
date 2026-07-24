# Loop Engineering — Flota Neuroon

> ⚠️ **DISEÑO ONLY.** Este documento describe un diseño. NO hay ningún cron ni
> GitHub Action activado a partir de este documento. Activar cualquier
> automatización real (Automations, L4+) requiere aprobación explícita
> posterior, por ser una acción de mayor alcance/riesgo que documentar.

## 1. ¿Qué es un `/goal` en esta flota?

Un `/goal` tiene 4 partes obligatorias: **objetivo**, **verificación**,
**condición de parada**, y **quién comprueba** (nunca el mismo agente que hizo
el trabajo).

### Ejemplo concreto (api-search-neuroon)

> **Objetivo:** implementar una Issue concreta del backlog de GitHub Issues de
> `api-search-neuroon` (p. ej. un ajuste de un endpoint de búsqueda).
>
> **Verificación:** (a) `./mvnw verify` en verde en la CI del PR Y (b) el PR de
> la Issue pasa de Draft a Ready for review (`gh pr ready`) Y (c) los tests
> existentes que cubren el área tocada siguen verdes sin relajar ninguna
> aserción.
>
> **Condición de parada:** máximo 3 iteraciones maker→checker. Si en la 3ª
> iteración el Verifier sigue rechazando, el loop se PARA y escala a un
> humano — nunca se relaja el checker para forzar un PASS, y nunca se
> reintenta indefinidamente (eso es exactamente el coste silencioso de
> "token blowout", ver §5).
>
> **Quién comprueba:** un agente Verifier distinto del Maker que implementó
> el cambio (ver §2).

## 2. Maker / Checker: de planner a 3 roles

`plan-feature.sh` ya formaliza la mitad del patrón: un **Planner** de solo
lectura de código que solo escribe en GitHub Issues. Este diseño lo extiende
a 3 roles separados, cada uno con su propio prompt y su propia superficie de
escritura:

| Rol | Script/prompt | Lee | Escribe |
|---|---|---|---|
| **Planner** | `plan-feature.sh` (ya existe) | código (solo lectura) | GitHub Issues |
| **Maker** | `templates/maker-prompt.md` | código + Issue asignada | código, en su propia rama/worktree; PR |
| **Verifier** | `templates/verifier-prompt.md` | el PR del Maker, desde cero | veredicto (PR review + comentario en la Issue) — NUNCA código |

**Regla dura: el Verifier nunca corrige.** Si encuentra un problema, lo
reporta y el Maker (en una iteración nueva) lo arregla. Si el Verifier
empezara a parchear código, dejaría de ser un checker independiente — sería
un segundo Maker sin nadie que lo revise.

El **estado externo** que sincroniza a los 3 roles sin que compartan contexto
conversacional es **GitHub Issues + el estado del PR** (Draft → Ready for
review), NO `feature_list.json` (que en este arnés solo trackea el bootstrap
del propio arnés, nunca el backlog de negocio). Transiciones: Issue abierta →
PR en Draft (Maker) → PR Ready for review (Maker, tras verificación acotada en
verde) → CI completa en verde (gate automático) → PR aprobado/rechazado +
Issue comentada (Verifier). Solo el Verifier aprueba el PR. Solo un humano
decide un `ESCALATE` (pregunta de dominio que ningún agente debe adivinar) y
el merge final.

## 3. Las 6 primitivas aplicadas a esta flota

| Primitiva | En esta flota, HOY (diseño) |
|---|---|
| **Automations** | Ninguna activa. Futuro candidato: cron que dispare `deploy-worker.sh` + maker/checker sobre una sola feature `pending` de un repo ya con harness en verde sostenido. **No activado.** |
| **Worktrees** | El Maker trabaja siempre en una rama/worktree propia por feature; nunca en la rama por defecto del repo. El Verifier siempre parte de un checkout limpio del PR, nunca reutiliza el worktree del Maker. |
| **Skills** | Futuras candidatas: `scaffold-harness`, `audit-harness` como skills invocables directamente por los agentes, en vez de solo scripts de la Matriz. |
| **Connectors** | `gh` CLI (Issues, PRs), nada más por ahora — sin Slack/Jira/etc. |
| **Sub-agents** | Planner, Maker, Verifier — 3 prompts/roles distintos, nunca fusionados. |
| **External State** | GitHub Issues + Project Board (backlog real) + estado del PR (Draft/Ready) + `claude-progress.md` + `session-handoff.md` + `claude-mem` (memoria conversacional complementaria, no autoritativa). `feature_list.json` solo trackea el bootstrap del arnés, nunca el backlog. |

## 4. Nivel de madurez recomendado para EMPEZAR

Escalera (de menor a mayor autonomía):

- **L1** — sesión manual, un agente, el humano conduce cada paso, sin `/goal`.
- **L2** — sesión estructurada con estado externo (`feature_list.json` +
  `claude-progress.md`) y un `/goal` explícito (objetivo+verificación+parada),
  un solo agente, disparo humano por sesión.
- **L3** — par Maker/Checker (2 agentes/sesiones), disparo humano en cada
  etapa, el traspaso es el estado externo (transiciones de `feature_list.json`).
- **L4** — loop programado (cron/Automations) sin supervisión por ejecución,
  acotado a una zona de bajo riesgo ya verde; PRs nunca se auto-mergean.
- **L5** — flota de loops autónomos multi-repo con escalado/aviso automático,
  mínima intervención humana.

**Recomendación: empezar en L3 esta ronda. No activar L4 todavía.**

Justificación:
- Partimos de cero en cron/automatización — ningún repo de la flota tiene hoy
  loop/progress-tracking automatizado ni Automations activas.
- `tools/audit-harness.sh` aún no tiene historial: ningún repo de la flota ha
  demostrado un baseline CRITICAL-verde sostenido todavía (ver
  `repositories.json` → `harness_ready`/`harness_notes` por proyecto).
- La flota mezcla stacks muy distintos (Java/Maven, Python, PHP/WordPress,
  TypeScript) — un loop desatendido necesita evidencia de que el Verifier
  atrapa errores reales en CADA stack antes de confiar en él, no solo en uno.

**Antes de siquiera PEDIR aprobación para L4**, esta lista debe cumplirse:
- [ ] `tools/audit-harness.sh` en verde (0 CRITICAL) de forma sostenida en el repo objetivo.
- [ ] Al menos varios ciclos manuales de Maker/Checker (L3) con el Verifier
      rechazando trabajo real del Maker al menos una vez (evidencia de que
      no es un sello de goma).
- [ ] El loop se restringe a repos/áreas ya con red de tests real — nunca a
      áreas sin cobertura sin rediseño previo.
- [ ] Rama protegida + PR obligatorio — ningún loop tiene permiso de push
      directo a la rama por defecto.

## 5. Los 4 costes silenciosos, aplicados aquí

**Deuda de verificación.** "CI en verde" no es lo mismo que "correcto según lo
que el negocio necesita" — una regla de negocio mal codificada puede pasar
todos los tests si nadie escribió el test que la codifica. El Verifier debe
comprobar explícitamente contra las reglas documentadas del repo (si existen),
no solo contra el exit code de `./init.sh`/`./scripts/verify-feature.sh`.

**Comprehension rot.** El modelo mental compartido de cada repo (qué hace cada
servicio, qué convenciones sigue) vive en gran parte en la cabeza de quien lo
escribió y en su `AGENTS.md`/`CLAUDE.md`. Si un loop mergea muchos cambios
pequeños sin que un humano vuelva a leer las actualizaciones a esa
documentación, el mapa se desincroniza del código.

**Rendición cognitiva.** El riesgo es que la disciplina mecánica (lint+tests
obligatorios) sea tan fuerte que un revisor humano acabe aprobando un PR
"porque está todo en verde" sin revisar la corrección real. Loop engineering
no debe reintroducir esto dejando que un Verifier en solitario "autoapruebe"
cambios sensibles sin sign-off humano.

**Token blowout.** Los repos con más dependientes/mayor superficie (el backend
de búsqueda, el motor Python) son exactamente las zonas donde un agente
desatendido intentaría trazar dependencias cruzadas sin converger, quemando
tokens sin producir progreso. Por eso el diseño apunta primero a repos/áreas
pequeñas y ya probadas — no a los de mayor fan-in/fan-out todavía.

---

> ⚠️ Recordatorio: diseño only. Nada de esto se activa sin aprobación
> explícita posterior (cron real, GitHub Action real, o cualquier ejecución
> desatendida).
