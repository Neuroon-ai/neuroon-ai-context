# Worker Startup Flow — {{REPO_NAME}}

Sigue estos pasos EN ORDEN, sin saltarte ninguno, antes de escribir una sola línea de código.

1. `pwd` — confirma que estás dentro de {{REPO_NAME}}, no en la Matriz.
2. Lee `claude-progress.md` completo.
3. Revisa las **GitHub Issues abiertas** (`gh issue list --state open`) — ahí
   vive el backlog real, NO en `feature_list.json` (que solo trackea el
   bootstrap del arnés, ver `AGENTS.md`).
4. `git log --oneline -10` — confirma que el histórico real coincide con lo
   que dice claude-progress.md.
5. Ejecuta `./init.sh`. Si falla, DETENTE y repáralo antes de seguir — no hay
   verificación posible sobre una línea base rota.
6. Verifica la línea base (antes de tocar nada): el comando de verificación
   LIGERO del repo (compile+lint, o lo que diga `AGENTS.md`/`CLAUDE.md`). Debe
   estar en verde ANTES de que empieces. El suite completo (tests) lo corre la
   CI del PR, no tu sesión local.
7. Elige EXACTAMENTE UNA Issue (la asignada, o la de mayor prioridad sin
   bloquear entre las abiertas). Crea rama `tipo/gh-ID` y abre el PR en
   **Draft inmediatamente** (`gh pr create --draft --title "WIP: <título>"
   --body "Resolves #<ID>"`) — no esperes a tener el código terminado.
8. Implementa siguiendo las reglas del repo (las que enlace `AGENTS.md`/
   `CLAUDE.md`: reglas de ingeniería, guía de estilo, etc., si existen). Si la
   Issue enlaza un spec de OpenSpec (`openspec/changes/<slug>/`), su
   `tasks.md` es el contrato de implementación — márcalo paso a paso, y al
   cerrar la Issue `openspec archive` forma parte del Definition of Done
   (fusiona los deltas en `openspec/specs/`).
9. Verifica tu trabajo de forma ACOTADA a lo que tocaste
   (`scripts/verify-feature.sh "<patrón>"` o equivalente), no el suite
   completo.
10. Cuando tu verificación acotada esté en verde, saca el PR de Draft (`gh pr
    ready`). Eso NO es un veredicto de "passing" — lo decide un Verifier
    separado (u otro humano) tras revisar el PR; la CI completa del PR es el
    gate automático antes de esa revisión.
11. Actualiza `claude-progress.md` y `session-handoff.md`.
12. Nunca push directo a la rama por defecto del repo. Nunca marques tú mismo
    la Issue/PR como aprobado o mergeado — eso lo decide el Verifier o un
    humano.

Fecha de este despliegue: {{DATE}}.
