# MySQL HA: репликация, Orchestrator и VIP

Ansible-проект для трёх узлов MySQL 8.4 с асинхронной GTID-репликацией, автоматическим переключением primary через Percona Orchestrator и единым клиентским VIP через Keepalived. Компоненты MySQL и Orchestrator работают в Docker Compose; данные MySQL хранятся на хостах в `/srv/mysql/data`.

> **Важно:** это асинхронная репликация, а не синхронный кластер. При аварийном отказе primary последние подтверждённые записи могут отсутствовать на репликах. В проекте нет внешнего STONITH/fencing: перед использованием для критичных данных испытайте сетевое разделение и сценарии отказа из [плана испытаний](FAILOVER_TESTS.ru.md). Резервные копии и проверка восстановления обязательны.

## Схема

| Узел | Адрес | Начальная роль |
| --- | --- | --- |
| db01 | `10.100.0.1` | seed primary при первом развёртывании |
| db02 | `10.100.0.2` | реплика |
| db03 | `10.100.0.3` | реплика |

- MySQL: порт `3306`, GTID auto-position, binlog и `log_replica_updates`.
- Orchestrator: экземпляр на каждом DB-узле, Raft из трёх участников, HTTP API/UI на порту `3000`. Он обнаруживает текущий primary и управляет failover.
- Keepalived: VIP `10.100.0.5:3306` должен находиться только на проверенном writable primary. После failover primary **может быть любым** из трёх узлов; имя `db01` не означает, что он всегда главный.
- UFW: SSH разрешён только из явно заданных управляющих сетей, доступ к MySQL — из доверенных клиентских сетей и между узлами. Перед развёртыванием проверьте CIDR в `group_vars/all.yml`.
- `mysql-safe-rejoin`: сервис/таймер для безопасного возврата бывшего primary как read-only реплики. При лишних GTID он отказывается автоматически присоединять узел.

Адреса и сети в репозитории относятся к конкретному стенду. Не запускайте playbook в другой сети без проверки `inventory/production.yml`, `group_vars/all.yml`, свободного VIP и правил firewall.

## Требования

- Три чистых сервера Ubuntu 22.04/24.04 или Debian 12 с доступом по SSH и `sudo`.
- Одна сеть, в которой работает выбранный VIP и VRRP между DB-узлами.
- На управляющей машине: Python, Ansible и коллекции из файлов требований.
- Проверенные резервные копии перед изменением существующей топологии. Установка на узлы с неизвестными MySQL-данными намеренно блокируется.

Установка зависимостей на управляющей машине:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-controller.txt
.venv/bin/ansible-galaxy collection install -r requirements.yml
```

## Настройка секретов

`group_vars/vault.yml` игнорируется Git. Создайте его из [шаблона](group_vars/vault.example.yml), сразу зашифруйте и замените **все** примерные значения через `ansible-vault edit`. Не используйте пароль SSH/sudo как пароль Vault или MySQL.

```bash
cp group_vars/vault.example.yml group_vars/vault.yml
.venv/bin/ansible-vault encrypt group_vars/vault.yml
.venv/bin/ansible-vault edit group_vars/vault.yml
```

Не публикуйте `vault.yml`, вывод команд с паролями, дампы баз или приватные ключи. Перед отправкой на GitHub проверьте, что секрет не отслеживается: `git ls-files group_vars/vault.yml` должен вернуть пустой вывод.

## Первое развёртывание

1. Проверьте SSH-пользователя и адреса в [inventory](inventory/production.yml), параметры VIP, CIDR и пароли в переменных. Убедитесь, что все три datadir пусты и нет данных, которые нужно сохранить.
2. При необходимости установите Python и SSH-ключ на новых серверах:

   ```bash
   .venv/bin/ansible-playbook -i inventory/production.yml playbooks/bootstrap.yml --ask-pass --ask-become-pass
   ```

3. На **новой пустой** топологии выполните развёртывание с одноразовым подтверждением инициализации репликации:

   ```bash
   .venv/bin/ansible-playbook -i inventory/production.yml playbooks/deploy.yml \
     --ask-vault-pass --ask-become-pass \
     -e confirm_mysql_replication_bootstrap=YES_INITIALIZE_ASYNC_REPLICATION
   ```

4. Выполните read-only проверку:

   ```bash
   .venv/bin/ansible-playbook -i inventory/production.yml playbooks/healthcheck.yml \
     --ask-vault-pass --ask-become-pass
   ```

Ожидаемое состояние: три здоровых MySQL-контейнера, один writable primary, две read-only реплики с работающими IO/SQL-потоками, согласованная топология Orchestrator и VIP на текущем primary. На новых серверах с парольной SSH-аутентификацией добавьте `--ask-pass` также к последующим командам.

Не применяйте флаг первичной инициализации к существующей топологии. После failover сначала проверьте фактические роли и GTID: переменная `mysql_primary_host: db01` задаёт начальный seed, а не заменяет обнаружение текущего primary.

## Эксплуатация

| Задача | Команда / документ |
| --- | --- |
| Состояние MySQL, Orchestrator, репликации и VIP | `ansible-playbook playbooks/healthcheck.yml --ask-vault-pass --ask-become-pass` |
| Диагностика без изменения топологии | `ansible-playbook playbooks/recovery.yml --ask-vault-pass --ask-become-pass` |
| Ручное восстановление и команды SQL | [HTML-runbook](RUNBOOK.html) |
| Проверка failover и возврата узлов | [План испытаний](FAILOVER_TESTS.ru.md) |
| Диагностика занятого места | `ansible mysql_cluster -b -K -m script -a 'scripts/cleanup_disk_node.sh --dry-run'` |
| Расширение уже увеличенного виртуального диска | [playbooks/expand_root_disk.yml](playbooks/expand_root_disk.yml), только после проверки layout и backup |

Команды в таблице запускаются из корня репозитория; `ansible.cfg` подставляет inventory для коротких вызовов. Для `recovery.yml` и `healthcheck.yml` нужен Vault. Скрипт очистки в режиме `--dry-run` только показывает возможные действия. Не удаляйте файлы binlog, relay log или datadir вручную через `rm`: они участвуют в восстановлении и репликации.

Плейбуки `reclone_db01_from_db03.yml` и `reclone_db03_from_db02.yml` созданы для **конкретных прошлых инцидентов** и не являются универсальными процедурами. Они могут заменить данные узла. Для нового расхождения GTID сначала определите текущий primary, сравните наборы GTID, проверьте резервную копию и составьте отдельный план восстановления.

`playbooks/update.yml` намеренно не обновляет MySQL автоматически: он собирает состояние и останавливается до отдельно согласованного плана обновления. `playbooks/destroy.yml` требует явных подтверждений; остановка сервисов и удаление данных — разные действия.

## Структура проекта

```text
inventory/              адреса и идентификаторы DB-узлов
group_vars/             общие переменные и шаблон Vault
playbooks/              развёртывание, проверки и отдельные процедуры
roles/mysql/            MySQL, конфигурация и Docker Compose
roles/mysql_replication/ GTID-репликация и безопасное присоединение
roles/orchestrator/     Orchestrator и Raft
roles/keepalived/       VIP и проверка текущего primary
roles/preflight/        проверки безопасности до изменений
scripts/                диагностические и обслуживающие скрипты
```

Подробные команды для подключения к MySQL, управления пользователями, проверки репликации и разбора отказов находятся в [RUNBOOK.html](RUNBOOK.html). Для GitHub откройте файл локально в браузере: интерактивное копирование команд работает в HTML-версии.
