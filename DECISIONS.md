# Architecture Decision Records

Краткие записи о ключевых решениях: что выбрано, что отвергнуто, почему.
Формат — упрощённый ADR (один номер = одно решение). При изменении
решения старая запись помечается `Superseded by #N` — не удаляется.

---

## ADR-001: Базовый образ — `node:22-bookworm-slim`

**Статус:** принято

**Контекст:** нужен образ, в который ставятся `@openai/codex` и
`@anthropic-ai/claude-code` (оба npm). Кандидаты: Alpine, Debian
bookworm, Ubuntu.

**Решение:** `node:22-bookworm-slim`.

**Обоснование:**
- glibc-based (Alpine на musl ломает некоторые native npm-модули)
- `bookworm-slim` существенно меньше полного `bookworm` (~80MB vs ~200MB)
- Node 22 LTS — соответствует требованиям свежих Claude/Codex CLI
- Debian имеет `libnss-wrapper` из коробки (нужно для запуска под
  host UID)

**Отвергнуто:**
- Alpine — нет `libnss-wrapper` без отдельного билда; musl-ABI ломает
  некоторые native-аддоны (sharp, sqlite3)
- Ubuntu — больше weight чем bookworm, без преимуществ
- Distroless — нет shell, ломает interactive use case

---

## ADR-002: Пиннинг версий через `versions.env` + ARG

**Статус:** принято

**Контекст:** воспроизводимость билдов; нельзя зависеть от `@latest`.

**Решение:** хранить версии в отдельном файле `versions.env`,
прокидывать в Dockerfile через `--build-arg`, использовать в теге
образа (`ai-sandbox:codex-X_claude-Y`).

**Обоснование:**
- Один источник истины (`versions.env`)
- Тег образа отражает версии — старые билды не теряются
- `update.sh` правит один файл и пересобирает
- Без изменения Dockerfile

**Отвергнуто:**
- Хардкод версий прямо в Dockerfile — каждое обновление = git diff Dockerfile
- npm shrinkwrap — overkill для двух пакетов, ещё один файл

**Не решено:** пиннинг digest base image (`node:22-bookworm-slim@sha256:...`)
— рассмотреть отдельно.

---

## ADR-003: Layout `.ai-sandbox/` поддиректория

**Статус:** принято (итерация 2026-05-28)

**Контекст:** проект — шаблон для вендоринга в чужие проекты. Нужно
выбрать layout.

**Решение:** все sandbox-файлы в поддиректории `.ai-sandbox/` целевого
проекта. В корне целевого — только то, что ожидается там (`.claude/`,
`.mcp.json`, `.gitignore`).

**Обоснование:**
- Один префикс для всего sandbox — легко найти, легко удалить
- `.ai-sandbox/` соответствует de facto convention (`.devcontainer/`,
  `.github/`, `.vscode/`)
- `.claude/settings.json` и `.mcp.json` обязаны быть в корне (это
  требование Claude Code и MCP)
- Минимизирует загрязнение workspace

**Отвергнуто:**
- Файлы в корне репо — слишком много top-level
- `.config/ai-sandbox/` — нестандартно для проектных файлов
- Бинарь+config (`~/.local/bin/ai-sandbox`) — теряет per-project
  изоляцию

---

## ADR-004: Хранение API-ключей в `~/.config/ai-sandbox/credentials.env`

**Статус:** принято

**Контекст:** ключи должны быть доступны всем проектам пользователя, не
храниться в репо.

**Решение:** один файл `~/.config/ai-sandbox/credentials.env`,
прокидывается через `--env-file`.

**Обоснование:**
- XDG-совместимый путь (`$XDG_CONFIG_HOME`)
- Один файл = одно место для ротации
- `--env-file` нативный механизм Docker, не требует mount

**Отвергнуто:**
- Per-project `.env` файлы — дублирование ключей
- Host keyring (secret-tool, security) — сложнее, не работает в headless
- Vault / 1Password CLI — внешняя зависимость

**Открытое:** UX-01 в TASK.md описывает каскадный override (глобальный
+ per-project) — отложено.

---

## ADR-005: Read-only rootfs + RO bind поверх rw workspace

**Статус:** принято (итерация 2026-05-28)

**Контекст:** агент не должен модифицировать собственные правила
(`run.sh`, `Dockerfile`, `settings.json`), но `/workspace` должен быть
rw для нормальной работы.

**Решение:** `/workspace` mounted rw, поверх — file-over-file bind
mounts конкретных конфигов как `:ro`.

**Обоснование:**
- Linux корректно обрабатывает RO mount поверх rw parent
- Не требует разделения на два mount-point'а с copy
- Защита **физическая** — даже агент с deny-list bypass не запишет

**Отвергнуто:**
- `chattr +i` (immutable) — не работает в overlayfs/некоторых FS, требует
  CAP_LINUX_IMMUTABLE
- Mount workspace целиком RO — ломает основной use case
- OverlayFS с readonly lowerdir — сложнее, эффект тот же

---

## ADR-006: `--user $UID:$GID` + libnss_wrapper

**Статус:** принято

**Контекст:** контейнер не должен запускаться как root (риск privesc,
файлы создаются как root на хосте).

**Решение:** `docker run --user "$(id -u):$(id -g)"` + libnss_wrapper
для эмуляции `/etc/passwd` entry под этот UID.

**Обоснование:**
- Файлы в bind-mounts имеют корректного владельца на хосте
- Privesc внутри контейнера затруднён
- Стандартный security pattern Docker

**Отвергнуто:**
- Хардкод UID 1000 — ломается если на хосте UID не 1000
- User namespaces (`--userns-remap`) — Docker-демон setup, не per-container
- `useradd` при билде с UID хоста — фиксирует один UID на образ

**Связано:** ADR-009 (отказ от root→setpriv для firewall).

---

## ADR-007: Пять режимов работы

**Статус:** принято (итерация 2026-05-28)

**Контекст:** пользователю нужны разные уровни ограничений для разных
задач (полная изоляция / нормальная разработка / отладка).

**Решение:** 5 режимов через `--mode`: `default`, `webfetch`, `dev`,
`open`, `offline`. Каждый рендерит `settings.local.json`, opt-in для
hook'ов, разный network access.

**Обоснование:**
- Покрывает основные сценарии
- Явный выбор пользователя — не магия
- Шаблонизация через `cat <<JSON` простая

**Отвергнуто:**
- Один режим с флагами (`--web`, `--bash-net`, ...) — combinatorial,
  трудно объяснить
- Двухступенчатая модель (`safe` / `unsafe`) — недостаточно гранулярна

**Связанные:** ADR-008 (offline mode → `--network=none`).

---

## ADR-008: `offline` mode = `--network=none`

**Статус:** принято (итерация 2026-05-28)

**Контекст:** нужен режим **полной** сетевой изоляции (для аудита кода,
анализа untrusted содержимого).

**Решение:** `--mode offline` добавляет `--network=none` к docker run.

**Обоснование:**
- Тривиально, работает на любом Docker
- Полностью отрезает сеть на L3 — никакие обходы невозможны
- Прозрачно — пользователь знает, что в offline ничего не выйдет наружу

**Отвергнуто:**
- iptables firewall как только offline — см. ADR-009 (отложен)
- Network namespace с loopback only — то же самое, просто Docker-syntax

---

## ADR-009: Не делать iptables-firewall в этой итерации

**Статус:** отложено (итерация 2026-05-28)

**Контекст:** настоящая L3-фильтрация в default/webfetch/dev режимах —
заявленная цель TASK.md NET-01. Anthropic-паттерн (init-firewall.sh)
требует root в контейнере + `setpriv` для drop.

**Решение:** в этой итерации не реализовывать. Только `offline` mode для
полной изоляции; default/webfetch/dev имеют bridge network.

**Обоснование отказа:**
- Старт как root → setpriv ломает `--user` (см. ADR-006)
- Не работает в rootless Docker / Podman (NET_ADMIN бесполезен)
- Усложняет entrypoint (~60 строк вместо 27)
- Риск файлов с uid=0 на хосте при ошибках до setpriv
- `docker exec` без `-u` даёт root внутри контейнера

**Принято вместо:** L7 hook (`net-guard.sh`) для Claude tool calls +
deny-list для grubых обходов (`nc`, `socat`, ...).

**Откладывается:** настоящий NET-01 через **sidecar-pattern** (рекоммендован
в ROADMAP) — отдельный init-контейнер с NET_ADMIN ставит iptables в
shared netns, основной контейнер запускается с `--user` без caps.

**Документировано как ограничение:** README.md §"Known limitations",
THREAT-MODEL.md, IMPLEMENTATION.md, ROADMAP.md.

---

## ADR-010: Codex как MCP server для Claude

**Статус:** принято

**Контекст:** проект называется "Claude Code + Codex". Можно запускать
обоих параллельно, но дешевле — Codex доступен Claude'у как tool.

**Решение:** `.mcp.json` регистрирует Codex как stdio MCP server.

**Обоснование:**
- Claude получает Codex tools без отдельной сессии
- Один Docker контейнер на сессию
- MCP протокол стандартизован, Codex его поддерживает

**Отвергнуто:**
- Параллельные shell-сессии — нужно два контейнера, sync state
- Только Claude или только Codex — теряем мультимодельность

**Открытое:** multi-MCP registry в ROADMAP.

---

## ADR-011: Лимиты ресурсов через env-overrides

**Статус:** принято (итерация 2026-05-28)

**Контекст:** memory/cpu лимиты должны быть настраиваемыми без правки
скриптов.

**Решение:** `AI_SANDBOX_MEMORY` (default 4g), `AI_SANDBOX_CPUS` (default 2),
`AI_SANDBOX_PIDS` (default 1024) — env vars, читаемые `run.sh`.

**Обоснование:**
- 4g/2cpu — разумный default для типового npm/build workload
- Env override проще, чем конфиг-файл
- `--memory-swap = --memory` (закрытие swap escape) — не настраивается,
  принципиальное решение

**Отвергнуто:**
- Per-mode лимиты — не нужно усложнять, override уже даёт гибкость
- Глобальный конфиг в `~/.config/` — следующая итерация (UX-01)

---

## ADR-012: arm64 поддержка через ldconfig lookup + arch-aware fallback

**Статус:** принято (итерация 2026-05-28)

**Контекст:** исходный entrypoint хардкодил `/usr/lib/x86_64-linux-gnu/...`
— ломается на Apple Silicon / arm64 хостах.

**Решение:** сначала `ldconfig -p` (находит библиотеку на любой
архитектуре), потом fallback цикл по amd64 и arm64 путям.

**Обоснование:**
- `ldconfig` всегда есть в Debian-based образах
- Fallback покрывает редкий случай отсутствия ldconfig cache
- Не требует multi-arch image (но и не мешает)

**Отвергнуто:**
- Полностью multi-arch image через buildx — отдельная задача (ROADMAP)
- Установка только нужной arch через apt — apt уже даёт правильную arch

---

## ADR-013: Defense-in-depth deny-list в `.claude/settings.json`

**Статус:** принято (итерация 2026-05-28)

**Контекст:** L7 hook ловит сетевые обращения через Bash, но только если
URL виден в командной строке. `python3 -c 'import urllib...'` или
`node -e 'fetch(...)'` обходят hook (URL внутри строкового аргумента,
не URL-формата).

**Решение:** в `.claude/settings.json` добавлены deny на эти ad-hoc
формы (`nc`, `socat`, `python3 -c *urllib*`, и т.п.).

**Обоснование:**
- Defense in depth — не основная защита, но отсекает грубые обходы
- Простая JSON-строка, без кода
- Pattern matching Claude'а покрывает большинство наивных вариантов

**Известное ограничение:**
- Pattern-deny обходится сменой кавычек, переменными, base64-encoded
  кодом. Это **L1 защита**, не **гарантия**. THREAT-MODEL.md явно это
  отмечает.

**Отвергнуто:**
- Полный список всех возможных обходов — невозможно, лучше явная
  network isolation (NET-01, отложено).

---

## ADR-014: `install.sh` идемпотентен, не клобит user-files

**Статус:** принято (итерация 2026-05-28)

**Контекст:** install.sh должен поддерживать повторный запуск
(обновление шаблона в существующем проекте).

**Решение:**
- `.ai-sandbox/` всегда перезаписывается (`cp -r src/. dst/`)
- `.claude/settings.json` и `.mcp.json` копируются **только если
  отсутствуют** (с пометкой `= kept existing` в выводе)
- `.gitignore` — merge через `grep -qxF` (не дублирует)

**Обоснование:**
- Шаблон обновляется свободно
- Кастомизации пользователя в `.claude/settings.json` / `.mcp.json` —
  его собственность
- `.gitignore` — merge без потерь

**Отвергнуто:**
- Полная перезапись всех файлов — теряет пользовательские правки
- Отказ обновлять `.ai-sandbox/` при изменениях — не позволяет
  обновляться без удаления

---

## Шаблон для новых решений

```markdown
## ADR-NNN: <короткий заголовок>

**Статус:** принято / отвергнуто / отложено / superseded by #M

**Контекст:** что вынудило принимать решение.

**Решение:** что выбрано.

**Обоснование:** почему.

**Отвергнуто:** какие альтернативы рассматривались и почему отброшены.

**Связано:** ссылки на другие ADR / задачи.
```
