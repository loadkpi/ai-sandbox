# Operations Runbook

Что делать когда что-то пошло не так. Расширяет раздел Troubleshooting
из README — более глубокие сценарии, восстановление после сбоев,
рутинные операции.

## Где что искать

| Симптом                              | Куда смотреть первым делом                    |
|--------------------------------------|-----------------------------------------------|
| Контейнер не стартует                | `docker logs <name>` + `./.ai-sandbox/run.sh --help` |
| Билд падает                          | `./.ai-sandbox/build.sh` (без redirect)       |
| Claude/Codex ошибки                  | `.ai-sandbox/home/.config/*` (state)          |
| Сетевые ошибки                       | `.ai-sandbox/allowed-domains.txt` + mode      |
| "command not found"                  | `versions.env` + `docker image inspect`       |

## Стандартные операции

### Полная переустановка sandbox в проекте

```bash
# Snapshot state на всякий случай
tar czf /tmp/ai-sandbox-home-$(date +%s).tgz .ai-sandbox/home/

# Удалить шаблон
rm -rf .ai-sandbox/
rm .claude/settings.json .mcp.json

# Поставить заново
/path/to/template/install.sh .

# Восстановить state если нужно
tar xzf /tmp/ai-sandbox-home-*.tgz -C .
```

### Сброс пользовательских настроек Codex

`.ai-sandbox/home/.codex/config.toml` регенерируется `run.sh`, **если**
содержит marker `# managed-by: ai-sandbox/run.sh ...`. Если удалили marker
ради ручной правки и теперь хотите вернуть default:

```bash
rm .ai-sandbox/home/.codex/config.toml
./.ai-sandbox/run.sh -- true   # перерендерит
```

### Принудительный пересбор образа

```bash
# Удалить кешированный образ
source .ai-sandbox/versions.env
docker rmi "ai-sandbox:codex-${CODEX_VERSION}_claude-${CLAUDE_VERSION}"

# Пересобрать без кэша
docker build --no-cache \
  --build-arg NODE_IMAGE="${NODE_IMAGE}" \
  --build-arg CODEX_VERSION="${CODEX_VERSION}" \
  --build-arg CLAUDE_VERSION="${CLAUDE_VERSION}" \
  -t "ai-sandbox:codex-${CODEX_VERSION}_claude-${CLAUDE_VERSION}" \
  -f .ai-sandbox/Dockerfile \
  .ai-sandbox
```

Или короче:

```bash
docker rmi $(docker image ls 'ai-sandbox:*' -q)
./.ai-sandbox/build.sh
```

### Обновление до latest CLI версий

```bash
./.ai-sandbox/check-updates.sh    # увидеть что новее
./.ai-sandbox/update.sh           # обновить обоих + rebuild
```

Если хочется обновить только один:

```bash
./.ai-sandbox/update.sh --claude 2.1.150        # только Claude
./.ai-sandbox/update.sh --codex 0.140.0         # только Codex
```

После update старый образ остаётся локально (другой тег) — можно
откатиться:

```bash
docker image ls 'ai-sandbox:*'    # увидеть все версии
./.ai-sandbox/update.sh --codex 0.133.0 --claude 2.1.142   # откат
```

### Массовое обновление в нескольких проектах

Если шаблон установлен в N проектов и нужно обновить везде:

```bash
# Обновить шаблон
cd /path/to/template
git pull

# Для каждого проекта — переустановить
for proj in ~/projects/*/; do
  if [ -d "$proj/.ai-sandbox" ]; then
    /path/to/template/install.sh "$proj"
  fi
done
```

Альтернатива (если использовался git submodule):

```bash
for proj in ~/projects/*/; do
  if [ -d "$proj/.ai-sandbox-template" ]; then
    (cd "$proj" && git submodule update --remote .ai-sandbox-template)
  fi
done
```

### Ротация API-ключей

```bash
# 1. Сгенерировать новый ключ в OpenAI/Anthropic dashboard
# 2. Заменить в credentials.env
chmod 600 ~/.config/ai-sandbox/credentials.env
$EDITOR ~/.config/ai-sandbox/credentials.env

# 3. Любая новая сессия подхватит — старая продолжает работать со старым
#    значением env (Docker --env-file читает на старте)

# 4. Revoke старый ключ в dashboard
```

Если подозрение, что старый ключ утёк — revoke **сразу**, до замены.

### Очистка state

Полная: `rm -rf .ai-sandbox/home/`
Только Codex: `rm -rf .ai-sandbox/home/.codex/`
Только Claude: `rm -rf .ai-sandbox/home/.config/`

При следующем запуске инструменты попросят повторную авторизацию.

### Резервная копия проектных данных

`/workspace` (= корень проекта) — обычные файлы пользователя, бэкап
обычным `tar`/`rsync`/git.

`.ai-sandbox/home/` — state контейнера. **Содержит auth tokens.** При
бэкапе:
- НЕ загружать на публичные хостинги
- Шифровать (`gpg`, `age`)
- Использовать только для миграции на новую машину

## Сценарии восстановления

### Сценарий 1: Sandbox перестал стартовать после обновления

```
Error: ai-sandbox-entrypoint: command not found
```

Возможные причины и проверки:

1. **Образ не пересобрался после `update.sh`**
   ```bash
   docker image ls 'ai-sandbox:*'
   source .ai-sandbox/versions.env
   # Совпадает ли последний образ с текущим тегом?
   ```
   Решение: `./.ai-sandbox/build.sh`

2. **`versions.env` корруптнут** (например, после `.bak` rollback)
   ```bash
   cat .ai-sandbox/versions.env
   # Ожидаем 3 строки: CODEX_VERSION=, CLAUDE_VERSION=, NODE_IMAGE=
   ```
   Решение: восстановить из шаблона или `versions.env.bak`.

3. **`entrypoint.sh` потерял exec бит**
   ```bash
   ls -la .ai-sandbox/entrypoint.sh
   # Ожидаем -rwxr-xr-x
   chmod +x .ai-sandbox/entrypoint.sh
   ```

### Сценарий 2: "permission denied" внутри контейнера

Скорее всего пытаетесь писать в read-only место.

```bash
# Проверить, что reading работает
./.ai-sandbox/run.sh -- ls -la /workspace/.ai-sandbox/run.sh
# должен видеть файл, ro overlay не мешает read

# Проверить writability /workspace
./.ai-sandbox/run.sh -- bash -lc 'echo x > /workspace/test && rm /workspace/test'
# должно работать

# Если не работает — проверить host-side права
ls -la $PWD
# Должен быть владелец = ваш user, права на запись
```

Если пишет в `/workspace/.ai-sandbox/something` — это **by design** ro.
Изменения в шаблоне делаются на хосте, не через контейнер.

### Сценарий 3: Codex/Claude не видят `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`

```bash
# Проверить, что credentials.env существует и читается
ls -la ~/.config/ai-sandbox/credentials.env
# Должно быть 600 (только владелец), не пусто

# Внутри контейнера проверить
./.ai-sandbox/run.sh -- env | grep -E 'OPENAI|ANTHROPIC'
```

Если переменных нет — `--env-file` не подхватил файл. Проверить:
- Файл существует на момент запуска
- `chmod 600` (Docker может ругаться на 644)
- Никаких BOM/CRLF в файле (`file ~/.config/ai-sandbox/credentials.env`)

Override credentials file:
```bash
AI_SANDBOX_CREDS_FILE=/path/to/other.env ./.ai-sandbox/run.sh -- claude
```

### Сценарий 4: Подозрение на компрометацию (агент сделал странное)

Симптомы: непонятные исходящие соединения, появились файлы которых
не должно быть, агент пытается читать места куда не должен.

```bash
# 1. ОСТАНОВИТЬ всё немедленно
docker ps | grep ai-sandbox
docker stop <container-name>

# 2. Сделать snapshot для анализа
tar czf /tmp/forensics-$(date +%s).tgz .ai-sandbox/home/ .claude/

# 3. Revoke API-ключи (Anthropic, OpenAI dashboards)

# 4. Проверить bash history агента
cat .ai-sandbox/home/.bash_history 2>/dev/null
cat .ai-sandbox/home/.zsh_history 2>/dev/null

# 5. Проверить session history Claude/Codex
ls -la .ai-sandbox/home/.config/claude/
ls -la .ai-sandbox/home/.codex/sessions/

# 6. Проверить аномальные файлы в workspace
git status
git diff
find $PWD -newer .ai-sandbox -not -path '*/.git/*' -not -path '*/.ai-sandbox/*' 2>/dev/null

# 7. Полная очистка
rm -rf .ai-sandbox/home/
docker rmi $(docker image ls 'ai-sandbox:*' -q)

# 8. (Опционально) Пересобрать с новой подписью образа из чистого шаблона
```

После: пересмотреть `.claude/settings.json`, добавить наблюдённые
обходные паттерны в deny-list. Обновить `allowed-domains.txt` если
видели легитимные требования к новым хостам.

### Сценарий 5: Конфликт `--name` для параллельных сессий

После итерации 2026-05-28 имя контейнера включает `$$` (PID), что
устраняет коллизию между shells. Если всё же видите:

```
docker: Error response from daemon: Conflict. The container name
"/ai-sandbox-myproject-12345" is already in use
```

Возможно: один shell перезапускает sandbox с тем же PID (редко). Workaround:

```bash
AI_SANDBOX_NAME_SUFFIX=$(date +%s%N) ./.ai-sandbox/run.sh -- claude
```

Или вручную удалить мёртвый контейнер:
```bash
docker rm -f $(docker ps -a -q --filter 'name=ai-sandbox-myproject')
```

### Сценарий 6: Образ невозможно скачать (npm registry недоступен)

При билде `npm install` падает с timeout / 503.

```bash
# Проверить доступность с хоста
curl -I https://registry.npmjs.org/
```

Если registry down — подождать или использовать mirror:

```bash
# В Dockerfile временно добавить (НЕ коммитить):
RUN npm config set registry https://registry.npmmirror.com
# затем стандартный npm install
```

Или установить версии из cached tarball если есть.

### Сценарий 7: cgroup memory unsupported

```
docker: Your kernel does not support swap limit capabilities
```

Возможна на старых Linux хостах без `swapaccount=1`.

Workaround:
```bash
AI_SANDBOX_MEMORY= ./.ai-sandbox/run.sh -- claude
```

Долгосрочно: в `/etc/default/grub` добавить
`GRUB_CMDLINE_LINUX_DEFAULT="... cgroup_enable=memory swapaccount=1"`,
`update-grub`, reboot.

### Сценарий 8: arm64 (Apple Silicon) — libnss_wrapper не находится

В итерации 2026-05-28 добавлен arch-aware fallback. Если всё же не
находит:

```bash
./.ai-sandbox/run.sh -- bash -lc 'ldconfig -p | grep nss_wrapper'
```

Если ничего не выводит:
```bash
./.ai-sandbox/run.sh -- bash -lc 'dpkg -L libnss-wrapper | grep \.so'
```

Должен быть `/usr/lib/aarch64-linux-gnu/libnss_wrapper.so`. Если нет —
проверить, что `libnss-wrapper` установлен в apt-слое Dockerfile.

## Регулярное обслуживание

### Еженедельно

- `./.ai-sandbox/check-updates.sh` — посмотреть, есть ли новые версии
- Просмотр `git status` и `git log` в каждом активном проекте — что
  агент изменил

### Ежемесячно

- Аудит `.ai-sandbox/home/.config/claude/sessions/` — что делал агент
- Очистка старых образов: `docker image prune --filter 'until=720h'`
- Ротация API-ключей если политика безопасности требует

### При смене dev-машины

1. Скопировать `~/.config/ai-sandbox/credentials.env` (защищённо!)
2. Для каждого активного проекта — скопировать `.ai-sandbox/home/`
   (или пустить агенты заново заавторизоваться)
3. Установить Docker
4. Pull или rebuild образ

## Контроль использования ресурсов

### Сколько занимают образы

```bash
docker image ls 'ai-sandbox:*' --format 'table {{.Tag}}\t{{.Size}}'
```

### Сколько занимает state

```bash
du -sh ~/projects/*/.ai-sandbox/home/ 2>/dev/null | sort -h
```

### Очистка старых образов

```bash
# Все ai-sandbox образы старше 30 дней
docker image prune -a --filter 'label=org.opencontainers.image.title=ai-sandbox' \
  --filter 'until=720h'

# Без label-фильтра (осторожно — может задеть другие образы)
docker image prune --filter 'until=720h'
```

## Эскалация

Если ни один сценарий не помогает:

1. Собрать диагностику:
   ```bash
   {
     echo "=== docker version ==="
     docker version
     echo "=== docker info ==="
     docker info
     echo "=== versions.env ==="
     cat .ai-sandbox/versions.env
     echo "=== image inspect ==="
     source .ai-sandbox/versions.env
     docker image inspect "ai-sandbox:codex-${CODEX_VERSION}_claude-${CLAUDE_VERSION}" 2>&1
     echo "=== last container logs ==="
     docker ps -a --filter 'name=ai-sandbox' --format '{{.ID}}' | head -1 | xargs -r docker logs --tail=200
   } > /tmp/ai-sandbox-diag.txt 2>&1
   ```

2. Проверить ROADMAP.md / known issues
3. Создать issue в репо шаблона с прикреплённой диагностикой
   (предварительно удалить любые ключи / private данные)
