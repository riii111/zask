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

### Shell completion

Commands, services, groups, and `open --<profile>` names complete from the
same config the command would load. Run the line for your shell once, then open
a new shell:

```bash
# zsh
echo 'eval "$(zask completion zsh)"' >> ~/.zshrc
# bash
echo 'eval "$(zask completion bash)"' >> ~/.bashrc
# fish
echo 'zask completion fish | source' >> ~/.config/fish/config.fish
```

`zask completion` prints the same lines.

## Quick Start

Initialize the current project once, then run zask from that project directory:

```bash
zask init
zask check
zask open
zask status
zask logs web
zask close
```

If the project already has a Procfile, `zask init --from Procfile.dev` imports
each `name: command` line as a service in a `procfile` group instead of guessing a
package script. Blank lines and `#` comments are skipped, and commands are not
run during import. Services run from the Procfile's directory, and Docker
Compose detection still applies. An invalid line or duplicate name stops init
with its `Procfile.dev:<line>` location, before any config is written.

Run `zask help` for the full command list.
`zask check` lists config mistakes and missing configured paths without opening a session.
Commands exit with `1` for runtime or environment failures, and `2` for usage or config errors.

zask reads `zask.json`, `.zask.json`, `zask.jsonc`, or `.zask.jsonc` from the
current directory. Named configs live at
`${XDG_CONFIG_HOME:-~/.config}/zask/<project>/config.json` or `config.jsonc`. If more than one candidate exists in the same place, zask
lists them and stops; pass `--config <file>` to choose one.

`.jsonc` files accept `//` and `/* */` comments. `.json` files stay strict JSON,
so a comment there is reported as an error. Trailing commas are rejected in
both. Syntax errors report the line and column.

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
(default `180`, at least `1`) bounds the whole wait, including checks still
running when it expires.

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

`services` can also be an object keyed by service name. A string value is the
command and uses the defaults for every other setting, such as `dir` at the
project root. An object value takes the same settings as an array entry except
`name`. Both forms can be used in one config:

```json
{
  "groups": [
    {
      "name": "backend",
      "services": {
        "api": "cargo run",
        "web": {"dir": "web", "runtime": "npm", "command": "run dev", "port": 5173}
      }
    }
  ]
}
```

`watch` restarts a service when files under its directory change. Patterns
follow `.gitignore` style, and changes are batched until they pause for
`debounce_ms`:

```json
{"name": "api", "dir": "backend", "command": "serve",
 "watch": {"paths": ["src"], "include": ["*.go"], "exclude": ["*_test.go"]}}
```

The `zask-watch` window runs the watcher for the whole session, so it keeps
going after you close the monitor or detach, and stops with `zask close`. It
shows each change and restart, and the service window prints the reason before
the command starts again. A service stopped with `zask stop` stays stopped,
even while it is still shutting down; one stopped with Ctrl-C in its window
stays stopped once it exits. If a service keeps changing its own watched files
right after each restart, restarts pause until the changes stop; add those
files to `exclude`. The service name `zask-watch` is reserved for this window.

`restart_on_failure` restarts a service that exits with a non-zero status or is
killed by a signal. Without it, zask leaves exited services alone:

```json
{"name": "worker", "command": "bin/worker",
 "restart_on_failure": {"max_retries": 3, "delay_ms": 1000}}
```

Both keys are optional; `{}` uses the values above. The same `zask-watch`
window waits `delay_ms` after each failure, prints the exit status and attempt,
and restarts the service; the service window prints the reason before the
command starts again. After `max_retries` restarts in a row, zask leaves the
service stopped and says so. A run that lasts 30 seconds, or a start by `zask
start`, `zask restart`, or a file change, starts the count over. A service that
exits with status 0 or is stopped with `zask stop`, Ctrl-C in its window, or
`zask close` is not restarted.

[`schema/zask.schema.json`](schema/zask.schema.json) describes the config for
editors that support JSON Schema. Point a top-level `"$schema"` key at it to get
completion, descriptions, and diagnostics for keys, types, and allowed values,
in `.json` and `.jsonc` files alike; zask ignores the value. References between groups, services, and aliases,
duplicate and reserved names, and paths that leave the project root are checked only when
zask loads the config.

zask carries the schema of the version you run. `zask init` writes it to
`~/.config/zask/zask.schema.json` (under `$XDG_CONFIG_HOME` when set) and adds
`"$schema": "../zask.schema.json"` to the generated config, so the reference
resolves without network access. Commands that load a named config rewrite that
file when it differs from the running zask, so upgrading zask also updates what
the editor checks. For a project-local `zask.json`, point `"$schema"` at that
file or at a copy of `schema/zask.schema.json`. Configs without `$schema` keep
working.

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
