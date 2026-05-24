# zask

A tmux-native process manager for local development.

zask opens a project-local tmux workspace, starts your local services inside named windows, and lets you attach, stop, restart, inspect, and focus them without rebuilding the workspace by hand.

## Concept

> tmux-native / Project-local / Process-aware / Built for daily dev loops

API servers, frontend dev servers, workers, and Docker Compose run while you code. zask treats those processes as the development environment.

It creates a persistent tmux workspace from local project configuration. Each service gets a predictable window, the dashboard and monitor stay in the same session, and common lifecycle actions can be run from outside tmux or from an attached client.

zask focuses on the running local environment: open it once, observe what is alive, restart one service, jump to logs, and close everything cleanly when you are done.

Unlike plain tmux session managers, zask knows about service groups, startup phases, Docker Compose, ports, and running pane state. It's closer to a local dev process manager that uses tmux as the runtime UI.

## Features

### Workspace

- **Open workspace** - Create a tmux session with dashboard, monitor, service windows, and an optional Docker window
- **Attach** - Attach from a normal shell or switch clients when already inside tmux
- **Restart session** - Tear down and reopen the workspace with one command
- **Close cleanly** - Stop configured resources before killing the tmux session

### Process lifecycle

- **Start / stop / restart** - Control all services, Docker, one service, or a configured service group
- **Status** - Show Docker Compose state and per-service pane state
- **Logs focus** - Jump directly to a service window
- **Startup profiles** - Open only the services needed for a workflow

### Project configuration

- **Service groups** - Address related services together, like backend or frontend
- **Startup phases** - Run Docker, command, and service phases in a predictable order
- **Docker Compose integration** - Start and stop Compose from the project directory
- **Health inputs** - Track service ports and healthcheck metadata in the same config
- **Runtime commands** - Prefix service commands with runtimes like `npm`, `pnpm`, `bun`, or `cargo`

## Installation

zask is currently built from source.

```bash
git clone https://github.com/riii111/zask
cd zask
zig build install
```

With Nix:

```bash
direnv allow
zig build install
```

## Quick Start

Create a project config:

```json
{
  "project": {
    "name": "demo",
    "root": "~/src/demo",
    "session_name": "demo"
  },
  "docker": {
    "enabled": true,
    "dir": "infra",
    "compose_file": "compose.yaml"
  },
  "group_aliases": {
    "backend": ["api", "worker"],
    "frontend": ["web"]
  },
  "services": [
    {"name": "api", "dir": "backend", "command": "serve", "port": 18080, "group": "backend"},
    {"name": "worker", "dir": "backend", "command": "work", "group": "backend"},
    {"name": "web", "dir": "frontend", "runtime": "npm", "command": "run dev", "port": 5173, "group": "frontend"}
  ]
}
```

Run zask with an explicit config:

```bash
zask --config ./config.json open
zask --config ./config.json status
zask --config ./config.json restart api
zask --config ./config.json logs web
zask --config ./config.json close
```

Or use a named project config from the zask config directory:

```bash
zask demo open
zask demo status
zask demo start backend
zask demo stop --all
```

## Commands

```text
zask <project> open [--docker|--<profile>]
zask <project> attach
zask <project> status
zask <project> logs <service>
zask <project> start <--all|svc|group|docker>
zask <project> stop <--all|svc|group|docker>
zask <project> restart <svc|group|docker>
zask <project> re
zask <project> close
```

Use `zask --config <file> <command>` to run against an explicit config file.

## Requirements

- tmux
- Zig 0.16.0 to build from source
- Docker with Docker Compose, when `docker.enabled` is true

## Development

With Nix:

```bash
direnv allow
zig build test
zig build test-tmux
```

Without direnv:

```bash
nix develop
```
