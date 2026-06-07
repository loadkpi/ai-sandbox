# FAQ

Вопросы, которые часто возникают про этот sandbox. Растёт по факту.

## Общие

### Зачем это, если есть `.devcontainer/`?

Devcontainer создавался для IDE-интеграции (VS Code, JetBrains) и
выполнения dev-workflow в контейнере. Этот sandbox:

- ориентирован на CLI-агентов, не IDE
- ставит более жёсткие security-ограничения (read-only rootfs, RO bind
  оверлеи, deny-list)
- работает с любым shell, не привязан к редактору
- предоставляет режимы isolation на лету (`--mode offline` для аудита)

См. [COMPARISON.md](./COMPARISON.md) для подробностей.

### Это same as devcontainer + Claude Code recipe?

Нет. Anthropic publish'ит официальный `.devcontainer/` пример с
iptables-firewall — он более фокусирован на network isolation и менее
на RO-mount защите конфигов. Наш sandbox делает ставку на:

- per-repository vendoring (как submodule / copy)
- режимы через единый `run.sh`
- protection sandbox-конфигов от самой модели

NET-01 (iptables-firewall) у нас отложен — см. ADR-009.

### Почему не использовать просто `docker run` напрямую?

Можно. `run.sh` — это удобная обёртка с разумными default'ами. Если
нужны другие — посмотрите в `run.sh` и адаптируйте. Sandbox не
препятствует прямому `docker run`.

### Это open source?

Если в репо нет LICENSE — это **не** open source по умолчанию. По
умолчанию all rights reserved. Если хотите использовать в чужих
проектах — спросите автора или добавьте LICENSE.

## Установка / setup

### Можно ли поставить sandbox глобально, а не per-project?

Сейчас — нет, layout per-project (`.ai-sandbox/` в каждом проекте). Это
сознательное решение, чтобы:
- per-project allowed-domains.txt
- per-project deny-list
- state каждого проекта в своём home

Можно поставить шаблон в `~/` и symlink'ать `.ai-sandbox` в проектах,
но это hack. Глобальные настройки (master prompt, общий config) — в
ROADMAP §UX-01/02.

### Как обновить sandbox в десятке проектов сразу?

См. [OPERATIONS.md §Массовое обновление](./OPERATIONS.md). Кратко:
loop install.sh или `git submodule update --remote` если использовали
submodule.

### Можно ли использовать без credentials.env?

Да, файл опционален. Если его нет — sandbox запустится, но Claude/Codex
не смогут авторизоваться к API. Полезно если ключи берёте из другого
источника (например, OAuth flow первого запуска Codex / `claude /login`).

### MacOS / Windows работает?

- **macOS (Docker Desktop)**: работает. arm64 (Apple Silicon) поддержан.
- **Windows (WSL2)**: работает внутри WSL дистрибутива.
- **Native Windows (без WSL)**: не тестировался. Bind mounts путей с
  обратными слэшами проблематичны.

## Сеть

### Почему Codex не может качать пакеты?

В `default`/`webfetch` режимах `network_access = false` в Codex config —
сознательно. Используйте `--mode dev` для разработки с network.

Не путать с глобальным network контейнера — в default режиме сеть на
уровне Docker есть (bridge), это Codex-config её обрезает.

### Можно ли добавить хосты в allowlist?

Да:
```bash
echo "myapi.example.com" >> .ai-sandbox/allowed-domains.txt
```

Перезапустить контейнер. Wildcards (`*.example.com`) поддержаны.

### Где живёт DNS-резолвер контейнера?

Docker embedded resolver на 127.0.0.11. Передаётся всем контейнерам по
умолчанию. В `--mode offline` (`--network=none`) DNS тоже отключён.

### Почему `nslookup evil.com` работает даже в default mode?

Потому что DNS (UDP/53) не блокируется на L3. NET-01 (iptables firewall)
закрыл бы это, но он отложен. См. THREAT-MODEL.md §"Эксфильтрация через DNS".

### Можно ли использовать корпоративный прокси?

Не из коробки. Workaround:
- Добавить в `.ai-sandbox/home/.codex/config.toml`:
  ```toml
  [shell_environment_policy]
  include_only = [..., "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"]
  ```
- В `~/.config/ai-sandbox/credentials.env`:
  ```
  HTTP_PROXY=http://proxy.corp:8080
  HTTPS_PROXY=http://proxy.corp:8080
  NO_PROXY=localhost,127.0.0.1
  ```

## Доступ к ресурсам

### Можно ли пробросить GPU?

Не из коробки. `--gpus all` нужно вручную добавить в `run.sh` плюс
установить nvidia-container-toolkit на хосте. Это не типовой use case
для Claude Code / Codex (они LLM-API, не локальный inference).

### Можно ли пробросить кастомный порт?

Добавить `-p <host>:<container>` в `DOCKER_ARGS`. Используйте для
локальных серверов разработки.

### Почему `~/.ssh/` не доступен?

By design. См. THREAT-MODEL.md. Если нужны SSH-ключи для git push —
рассмотрите:
- Использовать HTTPS вместо SSH для git remote
- ssh-agent forwarding (`-v $SSH_AUTH_SOCK:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent`)
- GitHub CLI с personal access token (более controllable)

### Почему Codex не видит мой `GITHUB_TOKEN`?

После итерации 2026-05-28 — должен видеть. `shell_environment_policy.include_only`
включает `GITHUB_TOKEN`, `GH_TOKEN`, `NPM_TOKEN`, `PIP_INDEX_URL`.
Должны быть в credentials.env или env родительского shell.

Если не видит — проверить:
```bash
./.ai-sandbox/run.sh -- env | grep -E 'GITHUB|GH_TOKEN'
```

Если в env есть, но Codex не использует — проблема с самим Codex config.
Проверить `.ai-sandbox/home/.codex/config.toml`.

## Production / shared usage

### Можно ли использовать в CI?

Технически — да, sandbox это просто docker. Но CI обычно уже
изолированный environment; основные slои защиты sandbox'а (RO mounts,
deny-list) дублируют то, что CI уже делает (clean checkout, нет персистент
state). Конкретные lim'ы (memory/cpu) могут пригодиться.

### Можно ли использовать sandbox для production deploys?

**Нет.** Это dev tool. Sandbox даёт reasonable изоляцию для prompt
injection и user errors. Для prod-исполнения untrusted code нужна VM
(Firecracker, gVisor) или подобный уровень.

### Multi-user (несколько разработчиков на одной машине)

Не предусмотрено. Каждый разработчик использует свой `~/.config/ai-sandbox/`
и свои проектные клоны. Sandbox `--user $(id -u):$(id -g)` обеспечивает,
что файлы создаются под текущим UID.

## Codex / Claude специфичное

### Что значит "Codex как MCP server"?

Codex может работать в режиме MCP server (`codex mcp-server`). В этом
режиме Claude Code обнаруживает Codex через `.mcp.json` и может вызывать
его как набор tools (например, для генерации кода через GPT-модель).

То есть: один сеанс Claude, но внутри доступны Codex tools.

### Можно ли отключить MCP?

Да, удалить `.mcp.json` или закомментировать `codex` server в нём.

### Почему модель `gpt-5.5`? Откуда взяли?

Это значение по умолчанию в текущем `render_codex_config`. Установлено
на основании [официальной документации Codex](https://developers.openai.com/codex/models)
по состоянию на дату итерации. Если ваш Codex CLI не принимает — см.
README.md §Troubleshooting.

### Можно ли использовать другую модель?

Да:
```bash
# Удалить marker, чтобы run.sh не перезатёр
sed -i '/^# managed-by:/d' .ai-sandbox/home/.codex/config.toml
# Поправить
$EDITOR .ai-sandbox/home/.codex/config.toml
```

`run.sh` уважает отсутствие marker.

## Безопасность

### Это full sandboxing? Можно запускать malware?

Нет, см. THREAT-MODEL.md. Sandbox даёт защиту от случайных и грубых
атак, но не от targeted exploit. Для malware-анализа — VM (KVM,
Firecracker, gVisor).

### Что если Anthropic / OpenAI compromised?

Sandbox не защищает от самих API-провайдеров. Если они скомпрометированы
— ваши данные, прошедшие через API, могут утечь. Это вопрос **trust в
вендора**, не sandbox.

### Видны ли API-ключи внутри контейнера?

Да, через `/proc/self/environ` или `env`. По дизайну — Claude/Codex
нужно их использовать. Но они **не** видны:
- В bash history (если ключи в env, не в командах)
- В `/workspace/` (они только в env)

### Логирует ли sandbox то, что делает агент?

Сам sandbox — нет. State хранится Claude/Codex CLI в
`.ai-sandbox/home/.config/claude/` и `.ai-sandbox/home/.codex/sessions/`.
Просмотр истории — стандартными командами этих CLI.

## Что-то ломается

### "Permission denied" при первом запуске install.sh

```bash
chmod +x install.sh
```

### Docker daemon не отвечает

```bash
# Linux
sudo systemctl status docker
sudo systemctl start docker

# macOS / Windows: открыть Docker Desktop
```

### Образ собирается 10 минут

Первый билд — это нормально (apt + npm install глобальных пакетов).
Последующие — секунды (cache hit). Если каждый раз 10 минут — что-то
с Docker layer cache:
```bash
docker system df         # сколько кэша
docker builder prune     # очистить если переполнено
```

### Где задавать вопросы, не описанные тут

Соберите минимальный repro (что пытались, что увидели) и:
- Issue в репозитории шаблона
- ROADMAP.md / OPERATIONS.md / THREAT-MODEL.md — возможно уже описано
- README.md §Troubleshooting
