# Сравнение с альтернативами

Когда стоит выбрать этот sandbox, а когда — другой подход.

## TL;DR

| Когда                                            | Что использовать          |
|--------------------------------------------------|---------------------------|
| Запустить Claude/Codex локально с защитой        | **этот sandbox**          |
| Полноценное IDE-окружение с Claude               | devcontainer / Codespaces |
| Лёгкий experiment без security-concerns          | `npm install -g` напрямую |
| Анализ untrusted кода / malware                  | Firecracker VM / gVisor   |
| Удалённый dev-env с GUI                          | Codespaces / Gitpod       |
| CI-pipeline                                      | GitHub Actions / GitLab CI|

## Подробности

### vs. `npm install -g @anthropic-ai/claude-code` (без isolation)

| Параметр                | Этот sandbox            | Прямая установка          |
|-------------------------|-------------------------|---------------------------|
| Защита `~/.ssh`         | ✓ (deny + не смонтирован)| ✗ (полный доступ)        |
| Защита `~/.aws`         | ✓                       | ✗                         |
| Лимиты памяти/CPU       | ✓ (`--memory`, `--cpus`) | ✗                         |
| Read-only rootfs        | ✓                       | ✗                         |
| Защита от prompt-injection| частично (deny-list + RO)| ✗                       |
| Изоляция от других проектов| ✓ (per-project home) | ✗ (общий `~`)            |
| Setup сложность         | docker run + 1 файл     | npm install              |
| Скорость (cold start)   | ~2-5s (после билда)     | мгновенно                |

**Выбирать прямую установку, если:** вы доверяете модели и проекту,
работаете в одиночку, security-concerns низкие.

**Выбирать sandbox, если:** работаете с untrusted кодом, чувствительные
данные на машине, хотите воспроизводимость, нужны разные режимы под разные
задачи.

### vs. Docker DevContainer (`.devcontainer/`)

| Параметр                | Этот sandbox             | DevContainer             |
|-------------------------|--------------------------|--------------------------|
| Целевая аудитория       | CLI-агенты               | IDE (VS Code, JetBrains) |
| IDE integration         | нет                      | ✓ (LSP, debugger, etc.)  |
| Spec compliance         | свой формат              | devcontainer.json (стандарт) |
| Per-mode isolation      | ✓ (5 режимов)            | ✗ (один конфиг)         |
| RO bind поверх workspace| ✓                        | ✗ (обычно)              |
| Network firewall        | offline mode             | в Anthropic example есть iptables |
| Setup сложность         | install.sh + run.sh       | требует IDE + spec      |
| Vendoring               | submodule / cp           | submodule / cp           |

**Выбирать devcontainer, если:** используете VS Code/JetBrains и хотите
полную IDE-интеграцию с lint/debug/test внутри контейнера.

**Выбирать sandbox, если:** работаете в terminal, нужна гибкость режимов
безопасности, не привязаны к конкретной IDE.

Они **не взаимоисключающие** — можно иметь оба в одном проекте, использовать
devcontainer для IDE, sandbox для CLI sessions.

### vs. GitHub Codespaces / Gitpod

| Параметр                | Этот sandbox        | Codespaces / Gitpod          |
|-------------------------|---------------------|------------------------------|
| Где работает            | локально            | удалённо в облаке            |
| Стоимость               | бесплатно           | платно (счёт за compute time)|
| Доступ к локальным файлам| ✓                  | нет (только git push/pull)   |
| Offline-режим           | ✓                   | ✗ (нужен интернет всегда)    |
| Setup сложность         | install.sh          | пара кликов в браузере       |
| Доступ из любого места  | нет (привязан к машине)| ✓ (браузер)               |
| API-ключи               | свои локально       | secrets manager сервиса      |

**Выбирать Codespaces/Gitpod, если:** работаете с разных машин/устройств,
не хотите ставить Docker, готовы платить, имеете стабильный интернет.

**Выбирать sandbox, если:** работаете локально, хотите offline,
не хотите платить за compute, чувствительные данные не должны улетать в облако.

### vs. `docker run` напрямую с claude-code

```bash
docker run --rm -it \
  -v $PWD:/workspace \
  -w /workspace \
  -e ANTHROPIC_API_KEY=... \
  node:22 bash -c 'npm i -g @anthropic-ai/claude-code && claude'
```

| Параметр                | Этот sandbox    | Прямой docker run     |
|-------------------------|-----------------|-----------------------|
| Setup строк             | install.sh + 1  | ~10                    |
| Воспроизводимость       | pinned versions | latest каждый раз     |
| Защита workspace        | RO bind         | ничего                 |
| Лимиты ресурсов         | ✓               | ничего                 |
| Caps drop               | ✓               | ничего                 |
| User UID                | host UID        | root                   |

**Выбирать прямой docker run, если:** одноразовый experiment, не нужна
защита.

**Выбирать sandbox, если:** регулярно используете и хотите защиту по
умолчанию.

### vs. Firecracker / KVM (полноценная VM)

| Параметр                | Этот sandbox       | Firecracker VM        |
|-------------------------|--------------------|-----------------------|
| Кernel isolation        | shared (Docker)    | отдельное ядро         |
| Время старта            | ~1s                | ~100ms (Firecracker)  |
| Escape risk             | Docker 0-days      | сильно ниже            |
| Setup сложность         | install.sh         | значительно сложнее   |
| Подходит для malware    | нет                | ✓                     |
| Подходит для AI агентов | ✓                  | overkill              |

**Выбирать VM, если:** анализируете untrusted код, готовы tradeoff
сложность за hard isolation.

**Выбирать sandbox, если:** обычный workflow с AI-агентом, доверяете
модели как минимум на уровне "не активный злоумышленник".

### vs. gVisor / runsc

| Параметр                | Этот sandbox       | gVisor                |
|-------------------------|--------------------|-----------------------|
| Kernel attack surface   | full Linux         | userspace re-impl     |
| Compatibility           | 100% (нативный Linux)| 95% (некоторые syscalls n/a) |
| Setup сложность         | install.sh         | runtime install      |
| Performance overhead    | минимальный        | заметный (10-50%)     |

**Выбирать gVisor, если:** хотите hard kernel isolation без полной VM.

**Выбирать sandbox, если:** не нужен такой уровень + хотите простоту.

### vs. Anthropic official devcontainer example

Anthropic публикует [official devcontainer](https://code.claude.com/docs/en/devcontainer)
с `init-firewall.sh` (iptables allowlist).

| Параметр                | Этот sandbox       | Anthropic devcontainer |
|-------------------------|--------------------|------------------------|
| Network firewall (L3)   | ✗ (отложено)       | ✓ (iptables/ipset)    |
| RO config overlay       | ✓                  | ✗                      |
| Multi-mode              | ✓ (5)              | ✗ (один)              |
| `--user` сохранён       | ✓                  | ✗ (root в контейнере) |
| Rootless Docker         | работает           | ломается (нужен NET_ADMIN)|
| IDE integration         | ✗                  | ✓ (devcontainer)      |
| Vendoring               | submodule / cp     | spec-driven           |

**Когда выбрать Anthropic devcontainer:** если основная боль — сетевой
firewall, не нужен rootless, привязка к VS Code OK.

**Когда выбрать этот sandbox:** если нужна protection самого конфига
(SEC-01), несколько режимов под разные задачи, rootless Docker, не
привязка к конкретной IDE.

См. ADR-009 для подробного обоснования откладывания NET-01 в этой
итерации.

## Можно ли комбинировать?

Да:

- **Sandbox + devcontainer**: devcontainer для IDE-разработки, sandbox
  для terminal AI sessions
- **Sandbox + Codespaces**: установить sandbox внутри Codespace
  (двойная изоляция, но платите за compute)
- **Sandbox + Firecracker**: запускать sandbox внутри Firecracker VM для
  hardened isolation (overkill для типичного workflow)

## Не подходит для

- **Production deployments** — sandbox это dev tool, не runtime
- **Real-time GPU compute** — overhead Docker + отсутствие GPU passthrough
  по умолчанию
- **Многоконтейнерные сценарии** — один контейнер на сессию by design
- **Headless CI с persistent state** — CI обычно ephemeral, sandbox
  основные защиты дублируют то, что CI уже делает

## Резюме выбора

```
Нужна локальная защита Claude/Codex?
├── Готов вкладываться в setup? → этот sandbox
└── Нужна IDE? → devcontainer
    └── Также нужен L3 firewall? → Anthropic devcontainer
        └── Также cloud? → Codespaces

Untrusted code execution? → Firecracker / VM
Просто хочу попробовать? → npm install -g
```
