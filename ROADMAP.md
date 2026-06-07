# AI Sandbox — варианты дальнейшего развития

Этот файл — roadmap, не план. Идеи отсортированы по приоритету, но порядок
реализации зависит от того, как проект используется на практике. TASK.md
остаётся источником истины для исходного дизайна; здесь — то, что осталось
из TASK.md плюс новое, что всплыло в текущей итерации.

## Tier 1 — закрытие исходного TASK.md

### NET-01: настоящая сетевая изоляция (iptables / nftables firewall)

**Зачем:** сейчас `default`/`webfetch`/`dev` режимы имеют bridge-network
без L3-фильтра. L7-hook закрывает только Claude tool calls. Codex и любой
user-shell могут открывать сокеты куда угодно. Это главная неполнота
sandbox'а.

**Варианты реализации** (от простого к чистому):

1. **root → setpriv в entrypoint** (Anthropic devcontainer pattern)
   - Плюс: реализуется без архитектурных изменений
   - Минус: ломает rootless Docker / Podman, конфликтует с `--user`,
     усложняет entrypoint, риски `docker exec` без `-u`. Минусы перечислены
     в `IMPLEMENTATION.md`.

2. **Sidecar init-контейнер**
   - Первый `docker run --rm` с `NET_ADMIN` в shared network namespace
     ставит iptables, завершается.
   - Второй контейнер — основной, с `--user`, без caps.
   - Плюс: чистое разделение ролей, `--user` сохраняется.
   - Минус: оркестрация в `run.sh` усложняется (две команды + ожидание +
     namespace shared через `--network=container:<name>`).

3. **DNS-allowlist через unbound/coredns sidecar**
   - Custom bridge network, контейнер использует `--dns=<sidecar-ip>`,
     sidecar отдаёт NXDOMAIN для не-allowed доменов.
   - Плюс: не нужен `NET_ADMIN`; работает в rootless.
   - Минус: тривиально обходится через `getent ahosts` + raw IP,
     или через `--resolver` в curl/wget; защита иллюзорная.

4. **Egress-прокси (mitmproxy/squid) в sidecar**
   - Контейнер получает `HTTP_PROXY`/`HTTPS_PROXY` env, прокси режет по
     host/path allow-list.
   - Плюс: настоящий L7 контроль, работает с TLS через MITM cert
     (доверять только этому cert в контейнере).
   - Минус: ломает приложения, которые игнорируют `HTTP_PROXY` (включая
     возможно сам Claude/Codex для не-HTTP вызовов); MITM на TLS — много
     edge cases.

**Рекомендация для следующей итерации:** вариант 2 (sidecar init-контейнер).
Сохраняет `--user`, не ломает rootless, не усложняет entrypoint.

### UX-01: глобальные API-ключи

Сейчас credentials хранятся в `~/.config/ai-sandbox/credentials.env` —
уже наполовину реализовано. Доработка из TASK.md:

- Каскад: проектный `.ai-sandbox/.env` поверх глобального
- Шаблон `.env.example` при первом запуске
- Глобальная директория `~/.ai-sandbox/` для общих данных (отдельно от
  per-project state)

### UX-02: master prompt

Стандартный `~/.ai-sandbox/master-prompt.md`, который рендерится в
`CLAUDE.md` целевого проекта и `instructions_file` для Codex. Описано
подробно в TASK.md §UX-02.

### OPS-01: HEALTHCHECK в Dockerfile

Тривиально:
```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --retries=2 \
  CMD [ "bash", "-c", "echo ok" ]
```

### OPS-02 → README — частично сделано. Оставшееся:

- Скриншоты / asciicast первого запуска
- Раздел "FAQ" по реальным вопросам пользователей (придёт по факту)
- Версионирование самого шаблона (CHANGELOG.md)

## Tier 2 — улучшения качества кода

### Тесты на сам sandbox

Сейчас верификация — ручные команды в IMPLEMENTATION.md. Можно сделать
`bats` (Bash Automated Testing System) suite:

- `test/test_install.bats` — install.sh в tmpdir, проверка идемпотентности
- `test/test_run_smoke.bats` — `./.ai-sandbox/run.sh -- true` (smoke)
- `test/test_ro_mounts.bats` — попытка записи в RO mount → blocked
- `test/test_offline.bats` — `--mode offline` блокирует сеть
- `test/test_limits.bats` — `--memory` применяется

CI через GitHub Actions с `docker-in-docker`.

### Multi-arch образы

Сейчас образ собирается под архитектуру билд-хоста. Для Apple Silicon
+ amd64 серверов:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ai-sandbox:... \
  --push .
```

Опубликовать pre-built образы (e.g., `ghcr.io/<owner>/ai-sandbox`),
чтобы пользователям не нужно было собирать локально. `run.sh` мог бы
делать `docker pull` если образ не найден.

### Rootless Docker / Podman first-class support

Подтвердить, что текущая конфигурация работает в:
- Rootless Docker (Linux)
- Podman (драйвер crun)
- Docker Desktop (macOS / Windows)

Если есть расхождения — добавить mode-detection в `run.sh`.

### Pre-commit hook для allow-list

Скрипт `.ai-sandbox/check-allowed-domains.sh`, который:
- Проверяет, что все строки в `allowed-domains.txt` — валидные доменные
  имена (без `://`, без путей, без портов)
- Резолвит каждый — предупреждает, если не резолвится
- Можно подключить как git pre-commit hook в шаблоне

## Tier 3 — расширения функциональности

### Поддержка `--mode custom`

Пользователь указывает свой `.claude/settings.json.template` и
`config.toml.template` — `run.sh` их рендерит. Сейчас режимы захардкожены
в `render_claude_local_settings`. Шаблонизация через `envsubst` или
простой `cat`.

### Логирование blocked-запросов

`net-guard.sh` уже знает что блокирует, но не пишет лог. Добавить:
- Лог в `${HOME}/.ai-sandbox/blocked.log` (внутри контейнера)
- Опционально — отправка JSON-event на stderr хоста (через bind-mounted
  unix socket)
- Можно потом анализировать: какие домены агент часто пытается
  использовать → кандидаты на allow-list

### Recording / playback сессий

Опциональная фича: записывать stdin/stdout всей сессии (через `script`
или `asciinema`) в `.ai-sandbox/home/sessions/<timestamp>.cast`.
Полезно для аудита и отладки.

### Несколько одновременных моделей в одной сессии

Сейчас Codex MCP запускается один и использует одну модель. Расширение —
несколько MCP-серверов в `.mcp.json` под разные модели (gpt-5.5,
claude через API, локальная llama через ollama). Сами модели — выбор
пользователя, sandbox просто должен корректно мапить env-keys.

### Веб-UI для конфигурации

Очень опционально: маленькое `cmd-app`, которое:
- Редактирует `allowed-domains.txt` с автоподсказками (резолвинг)
- Показывает текущие лимиты / режим
- Открывает credentials.env в editor с маскированными значениями

Не делать пока пользователи не запросят.

## Tier 4 — отдельные направления

### Sandbox для не-AI инструментов

Текущая архитектура (`run.sh` + image + permission JSON) обобщается:
любой CLI, требующий ограниченного окружения, может использовать ту же
оснастку. Можно вынести нижний слой в библиотеку `lib-sandbox/`,
а `ai-sandbox/` — частный случай.

### Кэш в зависимостях

`/home/sandbox/.cache/npm`, `pip`, `cargo` сейчас изолированы per-project.
Можно добавить опциональный shared volume `~/.ai-sandbox/cache/<lang>/`,
чтобы повторные `npm ci` / `pip install` шли из локального кэша. Риск:
кэш-троян из одного проекта в другой. По умолчанию — выключено.

### MCP-серверы по требованию

`.mcp.json` сейчас прописывает Codex статично. Добавить registry MCP-
серверов в `~/.ai-sandbox/mcp-registry.json` и mode-флаги вида
`--mcp codex,github,filesystem` — `run.sh` динамически собирает финальный
`.mcp.json` на старте.

## Что НЕ делать

Антипаттерны, которых стоит избегать:

- **Не превращать в general-purpose container orchestration.** Это
  per-repo sandbox; если нужно несколько связанных контейнеров — это
  работа docker-compose / k8s, не наша.
- **Не добавлять автоматический `--pull always`.** Image должен быть
  воспроизводим из `versions.env`; auto-pull — путь к "у меня работает".
- **Не хардкодить cloud-credentials в config.** AWS/GCP-ключи — отдельный
  каскад, не миксовать с OPENAI_API_KEY в одном файле.
- **Не делать `--privileged` режим, даже для отладки.** Если нужно —
  пользователь явно запускает `docker run` напрямую.

## Открытые вопросы

- Стоит ли публиковать pre-built образы на GHCR? Зависит от того,
  публичный это проект или нет.
- Нужен ли Windows-native (без WSL2) support? Большинство пайплайнов
  всё равно через WSL, нативный Windows — много работы за маленький
  выхлоп.
- Имеет ли смысл интеграция с `act` (локальный GitHub Actions runner)?
  Sandbox мог бы быть платформой для запуска CI workflows локально с
  теми же ограничениями.
