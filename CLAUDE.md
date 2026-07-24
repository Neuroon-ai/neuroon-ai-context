# Neuroon AI Context — Fleet Management & DevOps

Estás en el repositorio **Matriz** (`neuroon-ai-context`). Este repositorio NO contiene código de negocio (ni Java, ni React). Es el centro de control de la infraestructura y gestión de agentes de IA de Neuroon.

---

## Patrón Operativo (Harness Engineering - DevOps)

1. **Tu rol:** Eres un Agente DevOps/SRE experto en bash, automatización y gestión del entorno de Claude Code.
2. **Read Before Write:** Nunca edites un script sin leerlo antes.
3. **Validación:** Tras modificar cualquier archivo, debes ejecutar `./init.sh` para comprobar que la sintaxis de bash (ShellCheck) y JSON (jq) es correcta, y que la identidad de Git de la máquina está configurada.

## Gestión de la Flota (Fleet Management)

Los proyectos que conforman la plataforma Neuroon están declarados como la "Verdad Absoluta" en el archivo `repositories.json`.
- Si se añade un nuevo microservicio o frontend a la empresa, DEBE registrarse en `repositories.json`.
- El script `./sync-fleet.sh` lee ese JSON y clona o actualiza todos los repositorios automáticamente en la máquina, dentro de `./workspaces`.

## Memoria Persistente entre Sesiones (Claude-Mem)

Esta máquina Matriz instala `claude-mem` a nivel global (transversal a todos los Workers de todos los repositorios).
- Captura automáticamente cada herramienta usada durante una sesión, genera resúmenes semánticos y los inyecta en la siguiente sesión de ese mismo repo/proyecto.
- No sustituye a `claude-progress.md` ni a `feature_list.json` (que siguen siendo la fuente de verdad estructurada del arnés). Es una capa complementaria de continuidad conversacional (decisiones, errores repetidos, contexto informal).
- No requiere configuración por proyecto: se instala una única vez en la máquina con `./install-factory.sh`.

## Reglas Estrictas de Scripts
1. **Idempotencia:** Todo script Bash (`.sh`) debe ser seguro para ejecutarse múltiples veces. Si instala un paquete, debe verificar primero si ya está instalado. Si clona un repo, debe verificar si el directorio ya existe.
2. **Cero Secretos:** NUNCA introduzcas tokens de GitHub, URLs privadas o API Keys en los scripts. Si el script necesita secretos, debe leerlos del entorno (`$ENV_VAR`).
3. **Manejo de Errores:** Todos los scripts deben empezar con `set -euo pipefail` para fallar rápidamente si un comando intermedio falla o si se usa una variable no definida.
4. **Rama por defecto:** Cada proyecto declara su propia rama por defecto en el campo `default_branch` de `repositories.json` — NO asumas que toda la flota usa `main` (ej. `api-search-neuroon` usa `develop`). Los scripts que actualizan repos (`sync-fleet.sh`, `deploy-worker.sh`) deben leer ese campo por proyecto y nunca hacer `pull` sobre una rama de trabajo distinta a la declarada, para no pisar el trabajo en curso de un worker.

## Convenciones de la plataforma

- Backend de búsqueda (`api-search-neuroon`): Java + Spring Boot, Maven (`mvnw`).
- Backend del motor (`api-search-engine`): Python.
- Frontends (`app-search-neuroon`, `app-search-widget-neuroon`, `docs-search-widget-neuroon`): TypeScript/Node.js (Next.js, Vite, Docusaurus).
- Plugin (`wordpress-plugin-neuroon-search`): WordPress/PHP.
- La máquina worker necesita por tanto: `java` (JDK), `mvn`/`mvnw`, `node`/`npm`, `python3`, `docker`, `gh`, `jq`.
