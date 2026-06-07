# AI Sandbox — текущая архитектура

Снимок состояния после итерации 2026-05-28. Описывает то, как проект
устроен сейчас, не то, как мог бы быть устроен.

## Общая идея

Это **шаблон**, который вендорится в целевые проекты как поддиректория
`.ai-sandbox/` плюс несколько файлов в корне (`.claude/`, `.mcp.json`,
`.gitignore`-rules). После установки пользователь запускает Claude Code и
Codex CLI внутри Docker-контейнера, который:

- использует пиннутые версии CLI (воспроизводимость)
- ограничен ресурсами (память, CPU, PIDs, файлы)
- работает на read-only rootfs с минимальными capabilities
- имеет read-only оверлеи поверх собственных конфигов (агент не может
  модифицировать свои правила)
- управляется одним скриптом `run.sh` с пятью режимами

## Топология

```
HOST (developer machine)
├── ~/.config/ai-sandbox/credentials.env       (API keys, 0600)
└── <project>/                                 (рабочий каталог пользователя)
    ├── .ai-sandbox/                           (вендорится из шаблона)
    │   ├── Dockerfile
    │   ├── versions.env
    │   ├── run.sh         ───┐
    │   ├── build.sh          │ скрипты на хосте
    │   ├── update.sh         │
    │   ├── check-updates.sh  │
    │   ├── entrypoint.sh  ───┘ внутри контейнера
    │   ├── allowed-domains.txt
    │   ├── hooks/net-guard.sh
    │   ├── .dockerignore
    │   └── home/                              (HOME контейнера, persistent)
    │       ├── .codex/config.toml             (генерируется run.sh)
    │       └── .config/                       (Claude/Codex state)
    ├── .claude/
    │   ├── settings.json                      (committed, deny-list)
    │   └── settings.local.json                (regenerated per mode, gitignored)
    ├── .mcp.json                              (Codex как MCP server)
    └── .gitignore                             (включает /.ai-sandbox/home/)

DOCKER DAEMON
└── ai-sandbox:codex-<X>_claude-<Y>            (image, pinned tag)
    └── runtime container (ephemeral, --rm)
        ├── /workspace                          ← bind mount <project> (rw)
        │   ├── .ai-sandbox/run.sh:ro          (file-over-file overlay)
        │   ├── .ai-sandbox/Dockerfile:ro
        │   ├── ...                            (все sandbox-конфиги ro)
        │   ├── .claude/settings.json:ro
        │   └── .mcp.json:ro
        ├── /home/sandbox                       ← bind mount <project>/.ai-sandbox/home (rw)
        ├── /tmp                                 ← tmpfs, 1024m, noexec
        ├── /run                                 ← tmpfs, 64m
        └── /                                    ← read-only rootfs
```

## Жизненный цикл

### Установка в целевой проект

Три эквивалентных способа (см. README §Install). Все приводят к одной
конфигурации файлов в целевом проекте.

```
install.sh / manual cp / git submodule
        │
        ▼
target-project/
  ├── .ai-sandbox/          (полная копия шаблона)
  ├── .claude/settings.json (если не было)
  ├── .mcp.json             (если не было)
  └── .gitignore            (добавлены 2 строки)
```

`install.sh` идемпотентен и не клобит существующие `.claude/settings.json`
и `.mcp.json`.

### Первый запуск

```
./.ai-sandbox/run.sh -- claude
        │
        ▼
run.sh
  ├── source versions.env                       (Codex/Claude/Node версии)
  ├── parse --mode flag                          (default|webfetch|dev|open|offline)
  ├── mkdir -p .ai-sandbox/home/.codex .claude
  ├── render_claude_local_settings              (генерация settings.local.json)
  ├── render_codex_config                       (idempotent с marker)
  ├── docker image inspect ai-sandbox:X_Y       (есть ли образ?)
  │       └── НЕТ → build.sh
  │                  └── docker build -f Dockerfile ".ai-sandbox/"
  └── exec docker run [DOCKER_ARGS] image bash
```

После билда — образ кэшируется по тегу, повторные запуски пропускают билд.

### Внутри контейнера

```
tini (PID 1)
  └── /usr/local/bin/ai-sandbox-entrypoint
        ├── id -u / id -g  (от --user, host UID:GID)
        ├── создать .nss_wrapper/{passwd,group}  (юзер "sandbox" → host UID)
        ├── найти libnss_wrapper.so
        │     ├── ldconfig -p
        │     └── fallback: amd64 → arm64
        ├── export LD_PRELOAD, NSS_WRAPPER_*
        ├── PATH=$HOME/.local/bin:$PATH
        └── exec "$@"        (claude / codex / bash)
```

`libnss_wrapper` нужен потому, что мы запускаемся как UID хоста, которого
нет в `/etc/passwd` контейнера. Wrapper подменяет `getpwuid()` и т.п., и
инструменты (git, ssh, sudo) видят валидного пользователя.

### Codex как MCP server для Claude

```
Claude Code (внутри контейнера)
      │ читает .mcp.json
      ▼
{ "mcpServers": { "codex": { "command": "codex", "args": ["mcp-server"], ... } } }
      │
      ▼
spawn codex mcp-server                          (через stdio)
      │
      ▼
Claude может вызывать tools/* от Codex
```

`OPENAI_API_KEY` пробрасывается из `--env-file credentials.env` через
substitution `${OPENAI_API_KEY}` в `.mcp.json`.

## Слои защиты (defense in depth)

Снизу вверх:

```
┌─────────────────────────────────────────────────────────────────┐
│ 6. Claude managed settings (image-level)                        │
│    /etc/claude-code/managed-settings.json                       │
│    disableBypassPermissionsMode: "disable"                      │
│    → агент не может включить --dangerously-skip-permissions     │
├─────────────────────────────────────────────────────────────────┤
│ 5. Project deny-list (.claude/settings.json)                    │
│    Read(./.env*, secrets, *.pem, *.key, ~/.ssh, ~/.aws)         │
│    Edit/Write(./.ai-sandbox/**, settings.json, .mcp.json)       │
│    Bash(sudo, docker, nsenter, mount, nc, socat, python -c ...)│
│    → отсечение очевидных bypass-векторов                        │
├─────────────────────────────────────────────────────────────────┤
│ 4. Mode-specific local-settings (.claude/settings.local.json)   │
│    регенерируется run.sh под выбранный режим                    │
│    WebFetch/WebSearch/Bash(curl|wget|ssh|scp) deny              │
│    + L7 hook для разрешённых host'ов (webfetch/dev режимы)      │
├─────────────────────────────────────────────────────────────────┤
│ 3. RO bind-mounts поверх /workspace                             │
│    Несмотря на rw-маунт /workspace, конкретные файлы помечены ro│
│    → даже root внутри не перепишет run.sh / Dockerfile / ...    │
├─────────────────────────────────────────────────────────────────┤
│ 2. Container constraints                                        │
│    --read-only rootfs                                           │
│    --cap-drop=ALL                                               │
│    --security-opt no-new-privileges                             │
│    --memory / --memory-swap / --cpus / --pids-limit             │
│    --tmpfs /tmp,/run (noexec,nosuid,nodev)                      │
├─────────────────────────────────────────────────────────────────┤
│ 1. Docker user namespace / cgroups (host kernel)                │
│    --user $UID:$GID + libnss_wrapper                            │
│    → процессы в контейнере = непривилегированный hostside-юзер  │
└─────────────────────────────────────────────────────────────────┘
```

Сеть отдельно — см. ниже.

## Сетевая модель

| Mode       | Docker network       | Claude WebFetch  | Bash curl/wget | Codex network |
|------------|----------------------|------------------|----------------|---------------|
| `default`  | bridge (default)     | deny             | deny           | deny          |
| `webfetch` | bridge               | L7 hook allowlist| deny           | deny          |
| `dev`      | bridge               | L7 hook allowlist| L7 hook allowlist| allow       |
| `open`     | bridge               | allow            | allow          | allow         |
| `offline`  | **none**             | deny             | deny           | deny          |

**Важно:** L3 (Docker network) фильтрация есть только в `offline`. В
остальных режимах L7-hook (`net-guard.sh`) применяется **только к Claude
tool calls**. Codex и user-shell могут открывать сокеты в любое место.

### L7 hook (net-guard.sh)

```
Claude собирается вызвать tool
      │
      ▼
settings.local.json: PreToolUse matcher
      │
      ▼
net-guard.sh < {tool_name, tool_input}
      │
      ├── WebFetch  → парсит URL → проверяет host против allowed-domains.txt
      ├── WebSearch → deny
      └── Bash      → парсит командную строку через python3:
                       извлекает http(s)://, ssh://, git@host: URLs
                       → каждый host против allow-list
      │
      ▼
allowed? → exit 0 (пропустить)
denied?  → JSON с hookSpecificOutput.permissionDecision="deny"
```

Hook **L7-only**: видит то, что Claude собирается вызвать. Если агент
пишет `curl_url="https://evil.com"; eval "curl $curl_url"`, hook это
обнаружит. Если пишет `python3 myscript.py` где URL внутри файла —
не обнаружит (URL не в командной строке).

### Allowlist format (allowed-domains.txt)

- Одна строка на хост
- Точное совпадение: `github.com`
- Все поддомены: `.github.com` (соответствует apex + любой subdomain)
- Glob-форма: `*.githubusercontent.com`
- `#`-комментарии и пустые строки игнорируются

Текущий allowlist разрешает: OpenAI/Anthropic API, GitHub/GitLab,
npm/pypi/rubygems registries.

## Сборка образа

```
build.sh
  │
  ├── source versions.env                  → ${CODEX_VERSION}, ${CLAUDE_VERSION}, ${NODE_IMAGE}
  └── docker build
        --build-arg NODE_IMAGE / CODEX_VERSION / CLAUDE_VERSION
        -t ai-sandbox:codex-X_claude-Y
        -f ${ROOT}/.ai-sandbox/Dockerfile
        ${ROOT}/.ai-sandbox                ← build context (минимальный)
                  │
                  └── .dockerignore: home/, *.md, .git
```

Контекст билда — `.ai-sandbox/` целиком (несколько KB), не родительский
проект. Это:
- ускоряет билд (нет копирования `node_modules` и т.п.)
- не утечёт пользовательские секреты в build context
- `home/` (state) исключён через `.dockerignore`

### Dockerfile стадии

```
node:22-bookworm-slim                       (base image)
      │
      ▼
apt: bash, ca-certs, git, jq, libnss-wrapper, python3, ripgrep, tini
      │
      ▼
npm: @openai/codex@<X>, @anthropic-ai/claude-code@<Y>
      │
      ▼
/etc/claude-code/managed-settings.json      (baked at build, не из mount)
      │
      ▼
COPY entrypoint.sh /usr/local/bin/
      │
      ▼
WORKDIR /workspace
ENTRYPOINT [tini, --, ai-sandbox-entrypoint]
CMD [bash]
```

Образ stateless. Все state'ы (Claude/Codex history, кэши) — в
`/home/sandbox`, который mounted с хоста и persistent.

## Обновление CLI

```
./.ai-sandbox/check-updates.sh              → npm view, сравнить с pinned
./.ai-sandbox/update.sh [--codex X --claude Y]
        │
        ├── без аргументов — обновить обоих до latest
        ├── переписать versions.env (с backup .bak)
        └── build.sh                          (rebuild image)
```

После update тег образа меняется (`ai-sandbox:codex-X_claude-Y`), старый
образ остаётся в локальном Docker — можно откатиться через ручной
`docker tag` или повторный `update.sh --codex <старая> --claude <старая>`.

## Где хранится state

| Путь                                         | Persistence       | Назначение                          |
|----------------------------------------------|-------------------|-------------------------------------|
| `~/.config/ai-sandbox/credentials.env`       | host (vendor-independent) | API keys, shared между проектами |
| `<project>/.ai-sandbox/home/.codex/`         | bind-mount, persistent | Codex config + history          |
| `<project>/.ai-sandbox/home/.config/`        | bind-mount, persistent | Claude config + auth state      |
| `<project>/.claude/settings.local.json`     | host, regenerated per run | Mode-specific Claude restrictions |
| `<project>/.claude/settings.json`            | host, committed   | Project-level deny-list             |
| `<project>/.mcp.json`                        | host, committed   | MCP server registration             |
| Docker image                                 | Docker storage    | Pinned CLI versions                 |
| `/tmp`, `/run` в контейнере                  | tmpfs, ephemeral  | Сбрасывается при выходе             |

## Структура `run.sh` (логические блоки)

```
1. CONFIG          (lines 1–13)
   ROOT, CREDS_FILE, IMAGE_TAG, AI_SANDBOX_MEMORY/CPUS/PIDS

2. CLI parsing     (lines 15–48)
   --mode, --help, -- end-of-options

3. RENDER          (lines 50–195)
   render_claude_local_settings (5 mode-specific templates)
   render_codex_config (idempotent с marker)

4. BUILD CHECK     (lines 197–199)
   docker image inspect, fallback к build.sh

5. DOCKER_ARGS     (lines 201–234)
   Constraints: read-only, cap-drop, no-new-privileges, limits, tmpfs
   Env: HOME, XDG_*, AI_SANDBOX_*, telemetry-off
   Mounts: workspace rw, home rw, конфиги ro

6. MODE-OVERRIDES  (lines 236–240)
   case offline → --network=none

7. CREDENTIALS     (lines 242–244)
   --env-file если credentials.env существует

8. EXEC            (lines 246–250)
   default $@ → bash
   exec docker run [...] image $@
```

## Что НЕ делает архитектура

Сознательные ограничения, заложенные в дизайн:

- **Не оркеструет несколько контейнеров.** Один контейнер на сессию.
  Для multi-service — отдельный docker-compose.
- **Не управляет ключами в облаке.** Credentials — файл на хосте,
  владелец — пользователь.
- **Не делает auto-update.** Обновление CLI — явное действие через
  `update.sh`.
- **Не препятствует пользователю напрямую запустить `docker run`.**
  Sandbox — это `run.sh`. Если пользователь обходит, он осознанно
  обходит.
- **Не верифицирует подписи npm-пакетов.** Доверяет npm-registry.
  Воспроизводимость — через version pinning.
- **Не предоставляет L3-сеть-фильтр кроме offline.** Это **сознательная
  дыра** в текущей версии, см. ROADMAP.md §NET-01.
