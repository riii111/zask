# zask

![dashboard](https://github.com/user-attachments/assets/47a720b8-bf98-4b92-ac51-4fee14fc79e7)

A tmux-native process manager for local development, written in Zig.

zask opens a project-local tmux workspace for your API, workers, frontend, and Docker Compose. Start, stop, restart, inspect, and jump to services from one project-local config.

## Concept

> Keep the local development environment visible, repeatable, and boring.

zask started from project-local tmux scripts that were useful enough to keep,
but too implicit to share or maintain. It keeps that workflow: local config,
predictable tmux windows, and commands that operate on the processes you
actually use while coding.

## Features

![switch pane](https://github.com/user-attachments/assets/64214681-3a0d-4d15-ac01-c3d26671d70a)

- Create a persistent tmux session with dashboard, monitor, service windows, and optional Docker Compose.
- Control one service, a service group, Docker, or the whole workspace from the project root.
- Track startup order, ports, health metadata, and running pane state in local project config.
- Jump between logs and services without turning tmux session management into shell scripts.

## Installation

Install the latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/riii111/zask/main/install.sh | sh
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

Initialize the current project once, then run zask from that project directory:

```bash
zask init
zask open
zask status
zask logs web
zask close
```

Run `zask help` for the full command list.
Commands exit with `1` for runtime or environment failures, and `2` for usage or config errors.

### Status as JSON

`zask status --json` prints exactly one JSON document to stdout for scripts and
agents. On exit `0` it describes the workspace, including when the session is
not running:

```json
{"schema_version":1,"project":"demo","session":"active","docker":null,"services":[
  {"name":"api","group":"backend","state":"running","health":"ready","port":18080,
   "listen":"passed","http":"not_configured","exit_code":null,
   "uptime":{"state":"known","seconds":42}}]}
```

- `session`: `active` or `missing`.
- `state`: `running`, `stopped`, `exited`, `window_missing`, `session_missing`, or `unavailable`.
- `health`: `ready`, `waiting` (port not listening yet), `degraded` (HTTP check failing), `no_check`, `not_running`, or `unavailable`.
- `port` is the configured port; `listen` and `http` are the probe results: `passed`, `failed`, `not_configured`, `not_observed`, or `unavailable` (probe command missing).
- `exit_code` is set only for `exited`.
- `uptime.state` is `known` with `seconds`, `unknown` when the start time is not recorded (e.g. a session opened by an older zask), or `not_running`.
- `docker` is `null` without a `docker` section; otherwise it has `state`, `compose` (`running`, `empty`, `unavailable`, `not_observed`), `exit_code`, and `uptime`.

On failure the document is `{"schema_version":1,"error":{"code":...,"message":...,"config":...,"diagnostics":[...]}}`
with exit `1` (`tmux_unavailable`) or `2` (`config_not_found`, `ambiguous_config`,
`invalid_config_syntax`, `invalid_config`, `config_too_large`). Invalid
arguments still print usage text and exit `2`.

### Waiting for services

`zask wait api && npm run e2e` runs the next command only after `api` is ready.
Pass several services or groups to wait for all of them; `--timeout <seconds>`
(default `180`) bounds the whole wait; each check gives up after about a second,
so a wait ends at most that much past the limit.

- A service with a `port` is ready once the port listens and, with an `http`
  healthcheck, the HTTP check passes.
- A service without a `port` counts as ready as soon as its process is running.
- `wait` never starts or restarts anything. It exits `1` at once if a target is
  not running or exits while waiting, if the session is not running, or if
  readiness cannot be checked (`tmux`, `nc`, or `curl` unavailable); it exits `1`
  on timeout and `2` for an unknown service or group.

Named configs are stored under the same name as `project.name`. For example,
`zask demo open` loads the `demo` config, and that config must set
`"project": {"name": "demo", ...}`.

Service commands run in a non-interactive `sh -lc` inside each tmux pane. Prefer
real commands such as `npm run dev`, `make dev`, or `mise exec -- npm run dev`
over aliases, shell functions, or version-manager setup that only exists in
`.zshrc`.

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
    {"group": "backend", "wait_ports": [18080], "port_wait_timeout_seconds": 240},
    {"group": "frontend"}
  ]
}
```

`env_file` loads `KEY=value` files before a service command. Put it at the
project or group level for project-root-relative files, or on a service for a
file relative to that service directory:

```json
{
  "env_file": ".env",
  "groups": [
    {
      "name": "backend",
      "env_file": "backend/.env",
      "services": [
        {"name": "api", "dir": "backend", "command": "serve", "env_file": ".env.local"}
      ]
    }
  ]
}
```

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
