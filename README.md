# zask

![dashboard](https://github.com/user-attachments/assets/47a720b8-bf98-4b92-ac51-4fee14fc79e7)

A tmux-native process manager for local development, written in Zig.

zask opens a project-local tmux workspace for your API, workers, frontend, and Docker Compose. Start, stop, restart, inspect, and jump to services from one project-local config.

## Concept

> tmux-native / Project-local / Process-aware / Zig native / Built for daily dev loops

API servers, frontend dev servers, workers, and Docker Compose run while you code. zask treats those processes as the development environment.

It creates a persistent tmux workspace from local project configuration. Each service gets a predictable window, the dashboard and monitor stay in the same session, and common lifecycle actions can be run from outside tmux or from an attached client.

zask focuses on the running local environment: open it once, observe what is alive, restart one service, jump to logs, and close everything cleanly when you are done.

Unlike plain tmux session managers, zask knows about service groups, startup order, Docker Compose, ports, and running pane state. It is a local dev process manager that uses tmux as the runtime UI.

## Features

![switch pane](https://github.com/user-attachments/assets/64214681-3a0d-4d15-ac01-c3d26671d70a)

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
- **Startup order** - Run Docker, commands, and service groups in a predictable order
- **Docker Compose integration** - Start and stop Compose from the project directory
- **Health inputs** - Track service ports and healthcheck metadata in the same config
- **Runtime commands** - Prefix service commands with runtimes like `npm`, `pnpm`, `bun`, or `cargo`

## Installation

Download a prebuilt binary from GitHub Releases and place it on your `PATH`:

```bash
tar -xf zask-<target>.tar.gz
install -m 0755 zask ~/.local/bin/zask
```

Or build from source:

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
    "root": "."
  },
  "docker": {
    "compose": "compose.yaml"
  },
  "groups": [
    {
      "name": "backend",
      "services": [
        {"name": "api", "dir": "backend", "command": "serve", "port": 18080},
        {"name": "worker", "dir": "backend", "command": "work"}
      ]
    },
    {
      "name": "frontend",
      "services": [
        {"name": "web", "dir": "frontend", "runtime": "npm", "command": "run dev", "port": 5173}
      ]
    }
  ],
  "startup_order": [
    {"docker": true},
    {"group": "backend", "wait_ports": [18080]},
    {"group": "frontend"}
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

Initialize the current project once, then run zask from that project directory:

```bash
zask init
zask open
zask status
zask logs web
zask close
```

Service commands run in a non-interactive `sh -lc` inside each tmux pane. Prefer
real commands such as `npm run dev`, `make dev`, or `mise exec -- npm run dev`
over aliases, shell functions, or version-manager setup that only exists in
`.zshrc`.

You can still use a named project config from outside the project directory:

```bash
zask demo open
zask demo list
zask demo status
zask demo start backend
zask demo stop --all
```

## Commands

```text
zask <command>
zask <project> <command>
zask --config <file> <command>

zask init [project] [--root <path>] [--force]
zask open [--docker|--<profile>]
zask attach
zask list
zask status
zask logs <service>
zask start <--all|svc|group|docker>
zask stop <--all|svc|group|docker>
zask restart <svc|group|docker>
zask re
zask close

zask <project> open [--docker|--<profile>]
zask <project> attach
zask <project> list
zask <project> status
zask <project> logs <service>
zask <project> start <--all|svc|group|docker>
zask <project> stop <--all|svc|group|docker>
zask <project> restart <svc|group|docker>
zask <project> re
zask <project> close
```

Use `zask --config <file> <command>` to run against an explicit config file.
Inside an initialized project directory, use `zask <command>`. If that directory
also has `zask.json` or `.zask.json`, the local file takes precedence.

## Requirements

- tmux
- Zig 0.16.0 to build from source
- Docker with Docker Compose, when the config has a `docker` section

## License

Copyright 2026 riii111.

zask is licensed under the Apache License, Version 2.0.

## Development

With Nix:

```bash
direnv allow
zig build test
zig build test-all
```

Without direnv:

```bash
nix develop
```

## Showcase Fixture

The repository includes a fictional Receipt Lab workspace for public
screenshots and local behavior checks. It models a web console, BFF, backend
APIs, workers, and optional Docker-backed infrastructure without using any
private project names.

```bash
zig build run -- --config testdata/showcase/receipt-lab/zask.json list
zig build run -- --config testdata/showcase/receipt-lab/zask.json open --dashboard
```
