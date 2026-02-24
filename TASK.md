# Улучшения ai-sandbox

## Критические

### NET-01: Два режима сети — изолированный и обычный

**Проблема:** Контейнер запускается с полным сетевым доступом. AI может делать произвольные
HTTP-запросы, эксфильтровать данные из workspace. При этом полное отключение сети
непрактично — нужен доступ к API Claude/OpenAI и часто к npm/pip/git.

**Решение:** Два режима запуска через флаг в `run.sh`.

Изменения в `run.sh`:
- Добавить парсинг аргументов: `--offline` включает `--network=none`
- По умолчанию — с сетью (для работы с API)
- В режиме `--offline` — полная сетевая изоляция
- Переменная `AI_SANDBOX_NETWORK_MODE` для программного управления

Опционально (продвинутый вариант):
- Третий режим `--restricted` с Docker network + iptables/firewall, разрешающий
  только whitelisted домены: `api.anthropic.com`, `api.openai.com`,
  `registry.npmjs.org`, `github.com` (по аналогии с
  [официальным devcontainer](https://code.claude.com/docs/en/devcontainer))
- Реализуется через отдельный скрипт `setup-firewall.sh` или docker-compose
  с sidecar-прокси

Файлы: `run.sh`

---

### MEM-01: Лимиты памяти и CPU

**Проблема:** Нет ограничений памяти. AI-процесс или порождённые им команды могут
израсходовать всю RAM хоста и вызвать OOM killer.

**Решение:** Добавить в `docker run` в `run.sh`:
```
--memory=4g
--memory-swap=4g
--cpus=2
```

Сделать настраиваемым через переменные окружения:
```bash
AI_SANDBOX_MEMORY="${AI_SANDBOX_MEMORY:-4g}"
AI_SANDBOX_CPUS="${AI_SANDBOX_CPUS:-2}"
```

Файлы: `run.sh`

---

## Высокие

### SEC-01: Защитить конфиг-файлы от перезаписи изнутри контейнера

**Проблема:** Весь `$WORKSPACE` смонтирован read-write. AI может перезаписать:
- `run.sh` — изменить параметры безопасности при следующем запуске
- `Dockerfile` — внедрить код в образ
- `.claude/settings.json` — убрать deny-правила
- `.mcp.json` — добавить вредоносный MCP-сервер

**Решение:** Разделить монтирование на два:

1. Рабочая директория AI (read-write) — отдельная поддиректория или весь workspace
2. Конфиг-файлы — монтировать отдельно как read-only:

```bash
--mount "type=bind,src=$WORKSPACE,dst=/workspace"
--mount "type=bind,src=$WORKSPACE/.claude/settings.json,dst=/workspace/.claude/settings.json,readonly"
--mount "type=bind,src=$WORKSPACE/.mcp.json,dst=/workspace/.mcp.json,readonly"
--mount "type=bind,src=$WORKSPACE/run.sh,dst=/workspace/run.sh,readonly"
--mount "type=bind,src=$WORKSPACE/Dockerfile,dst=/workspace/Dockerfile,readonly"
```

Примечание: bind mount файла поверх директории перезаписывает — файл будет read-only
даже внутри read-write parent mount.

Дополнительно: добавить `run.sh` и `Dockerfile` в deny-список `.claude/settings.json`:
```json
"Edit(./run.sh)",
"Edit(./Dockerfile)",
"Edit(./.claude/settings.json)",
"Edit(./.mcp.json)",
"Write(./run.sh)",
"Write(./Dockerfile)",
"Write(./.claude/settings.json)",
"Write(./.mcp.json)"
```

Файлы: `run.sh`, `.claude/settings.json`

---

### BUILD-01: Добавить `.dockerignore`

**Проблема:** При `docker build` весь контекст (`$SCRIPT_DIR`) копируется в daemon,
включая `.git/`, `.ai-sandbox/home/` (который может содержать кэши, историю).
Это замедляет сборку и может случайно включить чувствительные данные в build context.

**Решение:** Создать `.dockerignore`:
```
.git
.ai-sandbox
.claude
.mcp.json
*.md
.env
.env.*
secrets/
```

Файлы: новый файл `.dockerignore`

---

### BUILD-02: Пиннинг версий npm-пакетов

**Проблема:** `@latest` в Dockerfile означает, что:
- Сборки нерепродуцируемы — каждый `docker build` может дать разный образ
- Обновление с breaking changes может сломать sandbox без предупреждения
- Нельзя откатиться к известному рабочему состоянию

**Решение:** В `Dockerfile` зафиксировать конкретные версии:
```dockerfile
ARG CODEX_VERSION=0.1.2504262326
ARG CLAUDE_CODE_VERSION=1.0.16
RUN npm install -g @openai/codex@${CODEX_VERSION} && npm cache clean --force
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} && npm cache clean --force
```

Преимущества:
- `ARG` позволяет обновлять версии через `--build-arg` без правки Dockerfile
- Версии зафиксированы — сборка воспроизводима
- Обновление — осознанное действие

**Механизм обновления:**

1. Скрипт `update.sh` — проверяет новые версии и пересобирает образ:
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Текущие зафиксированные версии из Dockerfile
CURRENT_CODEX=$(grep -oP 'ARG CODEX_VERSION=\K.*' "$SCRIPT_DIR/Dockerfile")
CURRENT_CLAUDE=$(grep -oP 'ARG CLAUDE_CODE_VERSION=\K.*' "$SCRIPT_DIR/Dockerfile")

# Последние доступные версии
LATEST_CODEX=$(npm view @openai/codex version 2>/dev/null)
LATEST_CLAUDE=$(npm view @anthropic-ai/claude-code version 2>/dev/null)

echo "codex:       $CURRENT_CODEX -> $LATEST_CODEX"
echo "claude-code: $CURRENT_CLAUDE -> $LATEST_CLAUDE"

if [ "$CURRENT_CODEX" = "$LATEST_CODEX" ] && [ "$CURRENT_CLAUDE" = "$LATEST_CLAUDE" ]; then
  echo "Всё актуально."
  exit 0
fi

read -rp "Обновить и пересобрать? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  exit 0
fi

# Обновить версии в Dockerfile
sed -i "s/^ARG CODEX_VERSION=.*/ARG CODEX_VERSION=$LATEST_CODEX/" "$SCRIPT_DIR/Dockerfile"
sed -i "s/^ARG CLAUDE_CODE_VERSION=.*/ARG CLAUDE_CODE_VERSION=$LATEST_CLAUDE/" "$SCRIPT_DIR/Dockerfile"

# Пересобрать без кэша для слоёв npm install
docker build --no-cache -t ai-sandbox:latest "$SCRIPT_DIR"

echo "Обновлено. Новые версии:"
echo "  codex:       $LATEST_CODEX"
echo "  claude-code: $LATEST_CLAUDE"
```

2. Быстрое обновление одного пакета без правки Dockerfile (через `--build-arg`):
```bash
docker build \
  --build-arg CLAUDE_CODE_VERSION=1.0.20 \
  --no-cache \
  -t ai-sandbox:latest .
```
Это переопределяет `ARG` на время сборки, но не меняет Dockerfile.
Удобно для тестирования новой версии перед фиксацией.

3. В `run.sh` добавить подкоманду `update`:
```bash
case "${1:-}" in
  update)
    exec "$SCRIPT_DIR/update.sh"
    ;;
esac
```
Это позволяет вызывать `./run.sh update` как единую точку входа.

4. Проверка версий внутри контейнера (для диагностики):
```bash
./run.sh claude --version
./run.sh codex --version
```

Файлы: `Dockerfile`, новый `update.sh`, `run.sh`

---

## Средние

### SEC-02: Безопасная передача API-ключей

**Поглощена задачей UX-01** (глобальные переиспользуемые ключи).
Реализация `--env-file` с каскадом глобальный/проектный описана там.

Дополнительно к UX-01:
- Убедиться, что `.ai-sandbox/` в `.gitignore`
- Убедиться, что `~/.ai-sandbox/.env` имеет права `600` (только владелец)
- В README предупредить, что ключи видны через `/proc/self/environ` внутри контейнера

Файлы: `run.sh`, `.gitignore`

---

### FIX-01: Исправить синтаксис `${@:-bash}` в run.sh

**Проблема:** Строка 88 `run.sh`:
```bash
"${@:-bash}"
```
`$@` — это массив, а `:-` работает только со скалярными переменными.
В bash это сработает для пустого `$@` но поведение не по POSIX и может
давать неожиданные результаты в разных shell-версиях.

**Решение:** Заменить на явную проверку:
```bash
if [ $# -eq 0 ]; then
  set -- bash
fi

exec docker run --rm -it \
  ...
  "$IMAGE_NAME" \
  "$@"
```

Файлы: `run.sh`

---

### SEC-03: Расширить deny-список в settings.json

**Проблема:** Текущий deny-list обходится:
- `Bash(curl *)` не блокирует `python3 -c "import urllib.request; ..."`
- `Bash(wget *)` не блокирует `node -e "fetch('...')"`
- Нет запрета на `nc`, `ncat`, `socat` (socat установлен в образе!)

**Решение:** Добавить в deny-список:
```json
"Bash(nc *)",
"Bash(ncat *)",
"Bash(socat *)",
"Bash(python3 -c *import*urllib*)",
"Bash(python3 -c *import*requests*)",
"Bash(python3 -c *import*socket*)",
"Bash(node -e *fetch*)",
"Bash(node -e *http*)",
"Bash(node -e *net*)"
```

Примечание: deny-list — это defense-in-depth, а не основная защита.
Полноценное решение — сетевая изоляция (NET-01). Deny-list дополняет,
но не заменяет её.

Файлы: `.claude/settings.json`

---

### UX-01: Глобальные переиспользуемые API-ключи

**Проблема:** Сейчас `STATE_DIR` (`$WORKSPACE/.ai-sandbox/home`) локален для каждого
проекта. При копировании sandbox в новый проект нужно заново настраивать API-ключи.
Ключи дублируются в каждом проекте — неудобно и небезопасно.

**Решение:** Ввести глобальную директорию `~/.ai-sandbox/` на хосте для общих данных,
а проектную `.ai-sandbox/` оставить для per-project state.

Структура:
```
~/.ai-sandbox/                      # глобальная (на хосте)
  ├── .env                          # API-ключи (ANTHROPIC_API_KEY, OPENAI_API_KEY)
  ├── master-prompt.md              # стандартный системный промпт
  └── codex/
      └── config.toml               # глобальный конфиг Codex

$WORKSPACE/.ai-sandbox/             # per-project
  ├── home/                         # HOME контейнера (кэши, история)
  ├── .env                          # переопределение ключей для проекта (опционально)
  └── prompt.md                     # переопределение промпта для проекта (опционально)
```

Изменения в `run.sh`:

1. Определить глобальную директорию:
```bash
GLOBAL_DIR="${AI_SANDBOX_GLOBAL_DIR:-$HOME/.ai-sandbox}"
mkdir -p "$GLOBAL_DIR"
```

2. Каскадная загрузка `.env` — проектный поверх глобального:
```bash
DOCKER_ENV_ARGS=""
if [ -f "$GLOBAL_DIR/.env" ]; then
  DOCKER_ENV_ARGS="--env-file $GLOBAL_DIR/.env"
fi
if [ -f "$WORKSPACE/.ai-sandbox/.env" ]; then
  DOCKER_ENV_ARGS="$DOCKER_ENV_ARGS --env-file $WORKSPACE/.ai-sandbox/.env"
fi
```
Docker `--env-file` при повторном указании переменной берёт последнее значение,
поэтому проектный `.env` корректно переопределяет глобальный.

3. Монтировать глобальную директорию read-only:
```bash
--mount "type=bind,src=$GLOBAL_DIR,dst=/home/sandbox/.ai-sandbox-global,readonly"
```

4. Создать `~/.ai-sandbox/.env.example` при первом запуске:
```bash
if [ ! -f "$GLOBAL_DIR/.env" ] && [ ! -f "$GLOBAL_DIR/.env.example" ]; then
  cat > "$GLOBAL_DIR/.env.example" <<'EOF'
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
EOF
  echo "Создан $GLOBAL_DIR/.env.example — заполните и переименуйте в .env"
fi
```

Файлы: `run.sh`

Примечание: эта задача заменяет SEC-02, расширяя её до полноценного
глобального конфига.

---

### UX-02: Стандартный master prompt

**Проблема:** Нет единого системного промпта, который задаёт стиль работы AI
во всех проектах. При каждом новом проекте приходится заново объяснять контекст,
правила и ограничения.

**Решение:** Файл `master-prompt.md` загружается как system prompt для Claude
через `CLAUDE.md` и как `base-instructions` для Codex.

Структура промпта (`~/.ai-sandbox/master-prompt.md`):
```markdown
# AI Sandbox — системные инструкции

## Роль
Ты работаешь в изолированном Docker-контейнере (ai-sandbox).

## Ограничения
- Не пытайся обходить сетевые ограничения
- Не модифицируй файлы конфигурации sandbox (run.sh, Dockerfile, .claude/settings.json)
- Не пытайся читать API-ключи из переменных окружения
- Не устанавливай пакеты без явного разрешения пользователя

## Стиль работы
- Объясняй что делаешь перед выполнением
- При ошибках предлагай варианты решения
- Не делай изменений за пределами рабочей директории
```

Механизм подключения — в `run.sh`:

1. Каскад: глобальный `master-prompt.md` + проектный `prompt.md`:
```bash
PROMPT_FILE=""
if [ -f "$GLOBAL_DIR/master-prompt.md" ]; then
  PROMPT_FILE="$GLOBAL_DIR/master-prompt.md"
fi
if [ -f "$WORKSPACE/.ai-sandbox/prompt.md" ]; then
  PROMPT_FILE="$WORKSPACE/.ai-sandbox/prompt.md"
fi
```

2. Для Claude Code — генерировать `CLAUDE.md` в workspace:
```bash
CLAUDE_MD="$WORKSPACE/CLAUDE.md"
if [ ! -f "$CLAUDE_MD" ] || [ "$PROMPT_FILE" -nt "$CLAUDE_MD" ]; then
  {
    if [ -f "$GLOBAL_DIR/master-prompt.md" ]; then
      cat "$GLOBAL_DIR/master-prompt.md"
    fi
    if [ -f "$WORKSPACE/.ai-sandbox/prompt.md" ]; then
      echo ""
      echo "---"
      echo ""
      cat "$WORKSPACE/.ai-sandbox/prompt.md"
    fi
  } > "$CLAUDE_MD"
fi
```

3. Для Codex — передавать через `base-instructions` при MCP-вызове
   или записывать в `$STATE_DIR/.codex/instructions.md` и указывать в config.toml:
```toml
instructions_file = "/home/sandbox/.ai-sandbox-global/master-prompt.md"
```

4. Создать шаблон при первом запуске:
```bash
if [ ! -f "$GLOBAL_DIR/master-prompt.md" ]; then
  cat > "$GLOBAL_DIR/master-prompt.md" <<'EOF'
# AI Sandbox — системные инструкции
# Отредактируйте этот файл под свои нужды
EOF
fi
```

Файлы: `run.sh`, шаблон `master-prompt.md`

---

## Низкие

### OPS-01: Добавить HEALTHCHECK в Dockerfile

**Решение:** Простая проверка, что shell доступен:
```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --retries=2 \
  CMD [ "bash", "-c", "echo ok" ]
```

Файлы: `Dockerfile`

---

### OPS-02: Добавить README.md

**Содержание:**
- Что это и зачем (1 абзац)
- Требования: Docker, API-ключи
- Быстрый старт: 3-4 команды
- Режимы сети: обычный, `--offline`, (опционально `--restricted`)
- Передача API-ключей через `.env`
- Настройки безопасности: что запрещено и почему
- Codex как MCP-сервер для Claude: что это даёт
- Кастомизация: как изменить лимиты, добавить пакеты

Файлы: новый `README.md`
