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

Service commands run in a non-interactive `sh -lc` inside each tmux pane. Prefer
real commands such as `npm run dev`, `make dev`, or `mise exec -- npm run dev`
over aliases, shell functions, or version-manager setup that only exists in
`.zshrc`.

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
