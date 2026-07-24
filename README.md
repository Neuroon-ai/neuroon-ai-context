# neuroon-ai-context

Matriz de infraestructura y configuración global para la flota de agentes IA de la
**plataforma Neuroon**.

Este repositorio es el **plano de control (control plane)** que permite convertir
cualquier VPS, portátil u ordenador en un **worker** capaz de operar los
repositorios de la plataforma siguiendo Harness Engineering.

## Puesta en marcha (nueva máquina)

```bash
git clone https://github.com/Neuroon-ai/neuroon-ai-context.git
cd neuroon-ai-context

# 1. Provisiona la máquina (instala gh, claude-code, rtk, graphify, claude-mem…)
./install-factory.sh

# 2. Autentícate
gh auth login
claude login

# 3. Sincroniza toda la flota declarada en repositories.json
./sync-fleet.sh

# 4. Arranca un worker sobre un repositorio concreto
./deploy-worker.sh api-search-neuroon
```

## Scripts

| Script | Rol |
|--------|-----|
| `install-factory.sh` | Aprovisiona la máquina Matriz (dependencias globales, una sola vez). |
| `sync-fleet.sh` | Clona/actualiza todos los repos declarados en `repositories.json`. |
| `deploy-worker.sh <repo>` | Despliega un repo (arnés, grafo, MCP) y muestra el comando para arrancar el worker sobre él. |
| `plan-feature.sh <repo>` | Abre una sesión de planificación (Arquitecto/PO) de solo lectura. |
| `init.sh` | Valida la línea base del propio repo Matriz (bash + JSON) y la identidad de Git. |

## Verdad absoluta

`repositories.json` es la fuente de verdad de qué proyectos componen la plataforma
Neuroon. Todo microservicio, frontend o herramienta nueva DEBE registrarse ahí.
