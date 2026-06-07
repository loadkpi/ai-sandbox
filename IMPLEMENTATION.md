# AI Sandbox — отчёт об итерации

Дата: 2026-05-28
Ветка: `main`
Базовый коммит: `180d215`

## Контекст

Репозиторий `ai-sandbox` — шаблон Docker-sandbox для Claude Code + Codex CLI,
который должен вендориться в целевые проекты как поддиректория `.ai-sandbox/`.
До итерации он был нерабочим:

- Все сандбокс-файлы лежали в корне репо, а скрипты ссылались на
  `${ROOT}/.ai-sandbox/...` (`ROOT = parent of script dir`) — пути не
  существовали.
- `.gitignore` содержал опечатку `/.ai_sandbox/` вместо `.ai-sandbox/` —
  локальный state с ключами/историей AI коммитился бы.
- README обрезан mid-codeblock на строке 46.
- Не было инструкции по установке шаблона в чужой проект.
- TASK.md описывал критичные security-улучшения (NET-01, MEM-01, SEC-01,
  BUILD-01, SEC-03), но они не были реализованы.

## Решения пользователя

| Развилка | Решение |
|----------|---------|
| Layout | Переносим всё в `.ai-sandbox/` (это шаблон для вендоринга) |
| Установка | Три способа в README: manual copy / git submodule / `install.sh` |
| Scope итерации | Блокеры + security (без NET-01) |
| NET-01 (iptables firewall) | Отложен. Минусы root→setpriv (см. ниже) перевесили. Только `--mode offline` (`--network=none`) для полной изоляции |
| Codex модель | `gpt-5.5` (новее `gpt-5.4`); верифицировать после билда |
| Веб-поиск во время планирования | Разрешён |

### Почему NET-01 отложен

Iptables-firewall в Anthropic-style требует старта контейнера как root +
`setpriv` для drop-down. Минусы, на которые пользователь не согласился:

1. Файлы могут случайно создаться от root до setpriv.
2. Если init-firewall.sh падает — рискованное частично-применённое состояние.
3. `docker exec` без `-u` даёт root внутри контейнера.
4. Rootless Docker / Podman перестают работать (NET_ADMIN бесполезен).
5. `setpriv --clear-groups` обрезает supplementary groups.
6. Усложнение entrypoint (~60 строк вместо 27).
7. CI/CD pipelines конфликтуют с нашей логикой `--user`.
8. На read-only rootfs + root любой `apt install` / `/etc` модификация
   фейлится, что удивит пользователей.

## План

1. Layout: `git mv` / `mv` всех сандбокс-файлов в `.ai-sandbox/`
2. Починить `.gitignore`
3. Dockerfile: COPY path (контекст теперь `.ai-sandbox/`)
4. run.sh: лимиты + RO mounts + offline mode + uniq name + codex marker + gpt-5.5
5. build.sh: сузить контекст до `.ai-sandbox/`
6. entrypoint.sh: arm64 libnss fallback
7. `.ai-sandbox/.dockerignore` — новый
8. `.claude/settings.json` — расширенный deny-list
9. README.md — полная переписка
10. `install.sh` — новый, в корне репо
11. Верификация

Полный план: `/home/kip/.claude/plans/dapper-tinkering-breeze.md`.

## Что сделано

### 1. Layout
```
Dockerfile         → .ai-sandbox/Dockerfile         (git mv)
run.sh             → .ai-sandbox/run.sh             (git mv)
entrypoint.sh      → .ai-sandbox/entrypoint.sh      (mv)
build.sh           → .ai-sandbox/build.sh           (mv)
update.sh          → .ai-sandbox/update.sh          (mv)
check-updates.sh   → .ai-sandbox/check-updates.sh   (mv)
versions.env       → .ai-sandbox/versions.env       (mv)
allowed-domains.txt → .ai-sandbox/allowed-domains.txt (mv)
hooks/net-guard.sh → .ai-sandbox/hooks/net-guard.sh (mv)
```
В корне остались: `.claude/`, `.mcp.json`, `README.md`, `TASK.md`,
`.gitignore`, `install.sh` (новый), `IMPLEMENTATION.md` (этот файл).

### 2. `.gitignore`
```gitignore
/.ai-sandbox/home/
/.claude/settings.local.json
/.idea/
/.vscode/
/.env
/.env.*
```
Опечатка `_` → `-` исправлена. `settings.local.json` теперь игнорируется.

### 3. Dockerfile
Изменён только `COPY`:
- было: `COPY .ai-sandbox/entrypoint.sh /usr/local/bin/ai-sandbox-entrypoint`
- стало: `COPY entrypoint.sh /usr/local/bin/ai-sandbox-entrypoint`
Контекст билда теперь сам `.ai-sandbox/`.

### 4. run.sh (главные изменения)
- Добавлены env-overrides: `AI_SANDBOX_MEMORY` (4g), `AI_SANDBOX_CPUS` (2),
  `AI_SANDBOX_PIDS` (1024)
- Добавлен режим `offline` в валидатор и `render_claude_local_settings`
- `render_codex_config` стал idempotent: marker
  `# managed-by: ai-sandbox/run.sh — DO NOT EDIT (regenerated each run)`
  на первой строке; если файл существует без marker — не трогаем
- Модель Codex: `gpt-5.4` → `gpt-5.5`
- `include_only` для shell_environment_policy расширен:
  `GITHUB_TOKEN`, `GH_TOKEN`, `NPM_TOKEN`, `PIP_INDEX_URL`
- `--name` теперь `ai-sandbox-<basename>-$$` (PID) — снимает конфликт
  параллельных сессий
- `DOCKER_ARGS` дополнен:
  - `--memory ${AI_SANDBOX_MEMORY}`
  - `--memory-swap ${AI_SANDBOX_MEMORY}` (= memory; закрывает swap escape)
  - `--cpus ${AI_SANDBOX_CPUS}`
  - `--pids-limit ${AI_SANDBOX_PIDS}`
  - RO bind-mounts (over rw `/workspace`):
    - `.ai-sandbox/run.sh`
    - `.ai-sandbox/build.sh`
    - `.ai-sandbox/update.sh`
    - `.ai-sandbox/check-updates.sh`
    - `.ai-sandbox/Dockerfile`
    - `.ai-sandbox/entrypoint.sh`
    - `.ai-sandbox/versions.env`
    - `.ai-sandbox/hooks/` (директория)
    - `.ai-sandbox/allowed-domains.txt`
    - `.claude/settings.json`
    - `.mcp.json`
- `case "${MODE}" in offline) DOCKER_ARGS+=( --network=none ) ;; esac`

### 5. build.sh
Последний аргумент `"${ROOT}"` → `"${ROOT}/.ai-sandbox"`. Build context
сужен до сандбокс-директории.

### 6. entrypoint.sh
Захардкоженный fallback `/usr/lib/x86_64-linux-gnu/libnss_wrapper.so`
заменён на arch-aware цикл:
```bash
LIB="$(ldconfig -p 2>/dev/null | awk '/libnss_wrapper\.so/{print $NF; exit}')"
if [[ -z "${LIB}" ]]; then
  for cand in /usr/lib/x86_64-linux-gnu/libnss_wrapper.so \
              /usr/lib/aarch64-linux-gnu/libnss_wrapper.so; do
    [[ -e "${cand}" ]] && LIB="${cand}" && break
  done
fi
export LD_PRELOAD="${LIB}"
```

### 7. `.ai-sandbox/.dockerignore` (новый)
```
home/
*.md
.git
```

### 8. `.claude/settings.json`
К существующему `Read(...)`-deny-list добавлены:
- `Edit/Write` для `./.ai-sandbox/**`, `.claude/settings.json`, `.mcp.json`
- `Bash(nc *)`, `Bash(ncat *)`, `Bash(socat *)`
- `Bash(python[3] -c *urllib*|*requests*|*socket*|*http.client*)`
- `Bash(node -e *fetch*|*http*|*https*|*net*)`
- `Bash(perl -e *Socket*)`, `Bash(perl -MIO::Socket*)`
Defense-in-depth поверх RO bind-mounts и L7 hook.

### 9. README.md (полная переписка)
Структура:
1. Что это и зачем
2. Что вы получаете (фичи)
3. Prerequisites + credentials.env
4. Install — 3 способа (A: install.sh, B: manual copy, C: git submodule)
5. First run
6. **Modes** — таблица 5 режимов × 4 колонки
7. Security model (FS / caps / limits / user / network / Claude managed)
8. **Known limitations** — явно отмечено что NET-01 будет позже
9. Customizing allow-list
10. Updating CLI versions
11. Troubleshooting (cgroups, submodule, name conflicts, codex model, arm64)
12. Files table

### 10. install.sh (новый, в корне репо)
```bash
./install.sh [target-dir]
```
- Идемпотентен (`cp -r .../.` для `.ai-sandbox/`)
- Не клобит существующий `.claude/settings.json` / `.mcp.json`
- Merge `.gitignore`: добавляет недостающие строки, не дублирует
- Отказывается ставиться в шаблон сам в себя
- Печатает `+` / `=` для каждого файла

### 11. Верификация (без Docker)
- `bash -n` всех 7 shell-скриптов — OK
- `jq .` на `settings.json`, `.mcp.json` — OK
- `install.sh` в `mktemp -d`, два прогона:
  - Первый: 13 файлов скопированы, `.gitignore` создан с 2 строками
  - Второй: `.ai-sandbox/` обновлён, user-files сохранены
    (`= kept existing`), `.gitignore` не задублирован
- `grep` ключевых правок в run.sh — все на месте
  (`gpt-5.5`, `managed-by`, `GITHUB_TOKEN`, `--memory`, `--cpus`, `offline`)

## Что НЕ сделано (известные ограничения)

### NET-01 — сетевая изоляция за рамками `offline`
В режимах `default`/`webfetch`/`dev`/`open` контейнер имеет полный bridge-
доступ в интернет. L7 hook `net-guard.sh` фильтрует **только** Claude tool
calls; Codex и любой пользовательский shell могут открывать сокеты куда
угодно. Defense-in-depth (deny-list в settings.json для `nc`/`socat`/etc.)
прикрывает банальные обходы, но не атакующего с unique payload.

**Полная изоляция доступна только через `--mode offline`** (`--network=none`).

Следующая итерация: iptables-firewall с правильной обработкой root→setpriv
или sidecar-pattern.

### Docker верификация
Sandbox harness, в котором я работал, запретил `docker` команды.
Рекомендуется выполнить локально:

```bash
# Билд (должен быть быстрым — контекст ~ десятки KB)
./.ai-sandbox/build.sh

# Лимиты памяти/CPU
./.ai-sandbox/run.sh -- bash -lc 'cat /sys/fs/cgroup/memory.max; nproc'
# ожидаем 4294967296, 2

AI_SANDBOX_MEMORY=2g AI_SANDBOX_CPUS=1 ./.ai-sandbox/run.sh -- \
  bash -lc 'cat /sys/fs/cgroup/memory.max; nproc'
# ожидаем 2147483648, 1

# RO mounts блокируют запись
./.ai-sandbox/run.sh -- bash -lc '
  echo x >> /workspace/.ai-sandbox/run.sh && echo WROTE || echo blocked
  echo x >> /workspace/.claude/settings.json && echo WROTE || echo blocked
'
# оба — blocked

# Workspace остаётся writable
./.ai-sandbox/run.sh -- bash -lc 'echo ok > /workspace/scratch && cat /workspace/scratch && rm /workspace/scratch'

# Offline — нет сети
./.ai-sandbox/run.sh --mode offline -- bash -lc \
  'curl -sS --max-time 3 https://api.anthropic.com/ || echo blocked'

# Default — сеть есть
./.ai-sandbox/run.sh --mode default -- bash -lc \
  'curl -sS --max-time 5 https://api.anthropic.com/ -o /dev/null -w "%{http_code}\n"'

# Codex модель валидна
./.ai-sandbox/run.sh -- bash -lc 'codex --version'

# Параллельные сессии — не должно падать на --name conflict
./.ai-sandbox/run.sh -- sleep 60 &
./.ai-sandbox/run.sh -- bash -lc 'hostname'
wait
```

### Codex модель `gpt-5.5`
Поставил по рекомендации Plan-агента, который ссылался на
`developers.openai.com/codex/models`. Не верифицировано на живом билде.
Если Codex CLI не примет — два варианта в `.ai-sandbox/home/.codex/config.toml`:

1. Удалить строку `# managed-by: ...` (отключит регенерацию), затем
   правка `model = "gpt-5.4"` или удаление строки `model = ...`
2. Откатить в `.ai-sandbox/run.sh` функцию `render_codex_config`:
   `model = "gpt-5.5"` → `model = "gpt-5.4"`

README.md содержит этот fallback в troubleshooting.

### Что не трогалось

- `.ai-sandbox/hooks/net-guard.sh` — корректен, переиспользуется как есть
- `.ai-sandbox/versions.env` — формат пиннинга работает
- `.ai-sandbox/update.sh`, `.ai-sandbox/check-updates.sh` — пути корректны после mv
- `.mcp.json` — синтаксис `${OPENAI_API_KEY}` подтверждён рабочим в Claude Code docs
- `disableBypassPermissionsMode: "disable"` — строка корректна (подтверждено в docs)
- `TASK.md` — оставлен как roadmap для будущих итераций (UX-01/02, OPS-01/02, NET-01)

## Изменённые файлы

| Файл | Действие |
|------|----------|
| `Dockerfile` → `.ai-sandbox/Dockerfile` | mv + COPY path fix |
| `run.sh` → `.ai-sandbox/run.sh` | mv + расширенная переработка (см. §4) |
| `entrypoint.sh` → `.ai-sandbox/entrypoint.sh` | mv + arm64 fallback |
| `build.sh` → `.ai-sandbox/build.sh` | mv + контекст |
| `update.sh` → `.ai-sandbox/update.sh` | mv (без правок) |
| `check-updates.sh` → `.ai-sandbox/check-updates.sh` | mv (без правок) |
| `versions.env` → `.ai-sandbox/versions.env` | mv (без правок) |
| `allowed-domains.txt` → `.ai-sandbox/allowed-domains.txt` | mv (без правок) |
| `hooks/net-guard.sh` → `.ai-sandbox/hooks/net-guard.sh` | mv (без правок) |
| `.ai-sandbox/.dockerignore` | новый |
| `.gitignore` | переписан |
| `.claude/settings.json` | расширенный deny-list |
| `README.md` | полная переписка |
| `install.sh` | новый в корне репо |
| `IMPLEMENTATION.md` | этот файл |
