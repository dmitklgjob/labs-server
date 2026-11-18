# Развёртывание на Ubuntu из Git

Все команды выполняются на сервере по SSH. Используйте пользователя, у которого будет находиться каталог `~/www`. После настройки Docker запускайте `docker compose` и `make` под этим пользователем.

## 1. Установить инструменты

Установите Docker Engine, Buildx и плагин Compose по [инструкции Docker для Ubuntu](https://docs.docker.com/engine/install/ubuntu/). Затем выполните:

```sh
sudo apt update
sudo apt install -y git openssh-client make openssl rsync acl
sudo systemctl enable --now docker
sudo usermod -aG docker "$(id -un)"
```

Переподключитесь по SSH и проверьте, что `docker info` и `docker compose version` работают без `sudo`. Группа `docker` даёт права уровня root. [Документация Docker](https://docs.docker.com/engine/install/linux-postinstall/)

## 2. Настроить доступ к GitHub и клонировать проекты

Если репозитории приватные, настройте на сервере SSH-ключ с доступом на чтение ко всем трём репозиториям. Для нового ключа используйте `ssh-keygen -t ed25519` и добавьте **публичный** ключ в GitHub. Проверьте доступ командой `ssh -T git@github.com`. [Настройка SSH в GitHub](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)

Клонируйте репозитории после того, как нужные изменения опубликованы в их ветках `main`:

```sh
mkdir -p "$HOME/www"
cd "$HOME/www"
git clone --branch main git@github.com:dmitklgjob/labs-server.git server
git clone --branch main git@github.com:dmitklgjob/labs-backend.git backend
git clone --branch main git@github.com:dmitklgjob/labs-frontend.git frontend-src
mkdir -p frontend/public
```

Compose лежит в `~/www/server`, Symfony — в `~/www/backend`, исходники Vue — в `~/www/frontend-src`. Nginx раздаёт результат сборки из `~/www/frontend/public`.

## 3. Настроить серверное окружение

Команда `ip -br -4 addr show scope global` покажет локальные IPv4-адреса. Подставьте IP сетевого интерфейса сервера и фактический адрес, по которому пользователи будут открывать сайт. Порт Nginx — `8888`. Адрес в `SITE_URL` задаётся без завершающего слеша.

Выполните этот блок один раз. Он остановится, если какой-либо из файлов уже существует:

```sh
(
  set -eu
  cd "$HOME/www/server"
  LAN_IP=192.168.1.10
  SITE_URL=http://192.168.1.10:8888

  if [ -e .env ] || [ -e ../backend/.env.local ]; then
    echo 'Файл .env или backend/.env.local уже существует. Проверьте их вручную.' >&2
    exit 1
  fi

  umask 077
  DB_PASSWORD=$(openssl rand -hex 24)
  APP_SECRET=$(openssl rand -hex 32)
  OAUTH_PASSPHRASE=$(openssl rand -hex 32)
  OAUTH_ENCRYPTION_KEY=$(openssl rand -hex 16)

  cat > .env <<EOF_ENV
POSTGRES_BIND_IP=$LAN_IP
POSTGRES_DB=app
POSTGRES_USER=app
POSTGRES_PASSWORD=$DB_PASSWORD
EOF_ENV

  cat > ../backend/.env.local <<EOF_BACKEND
APP_ENV=prod
APP_DEBUG=0
APP_SECRET=$APP_SECRET
DEFAULT_URI=$SITE_URL
DATABASE_URL="postgresql://app:$DB_PASSWORD@postgres:5432/app?serverVersion=17&charset=utf8"
OAUTH_PASSPHRASE=$OAUTH_PASSPHRASE
OAUTH_ENCRYPTION_KEY=$OAUTH_ENCRYPTION_KEY
EOF_BACKEND
)
```

Подготовьте права для PHP-FPM. В контейнере `www-data` имеет UID 33. ACL оставляет репозиторий во владении пользователя, который делает `git pull`.

```sh
(
  set -e
  cd "$HOME/www/backend"
  mkdir -p var vendor config/jwt storage/labs
  setfacl -m u:33:r .env.local
  setfacl -m u:33:rwx,d:u:33:rwx var vendor config/jwt storage/labs public
)
```

## 4. Собрать и опубликовать Vue

Используйте этот блок и для первой публикации, и после обновления `frontend-src`. Node.js запускается в контейнере. `npm ci` устанавливает зависимости по `package-lock.json`.

```sh
(
  set -eu
  cd "$HOME/www/frontend-src"
  docker run --rm --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=$PWD,target=/app" --workdir /app \
    -e npm_config_cache=/tmp/npm-cache \
    -e "BUILD_SHA=$(git rev-parse --short HEAD)" \
    node:24-alpine sh -ec 'npm ci && npm run build'
  mkdir -p "$HOME/www/frontend/public"
  rsync -a --delay-updates dist/ "$HOME/www/frontend/public/"
)
```

Значения `VITE_PAYLOAD_KEY` во frontend и `PAYLOAD_KEY` в Symfony должны совпадать. При изменении ключа обновите обе стороны и пересоберите Vue.

## 5. Запустить приложение и создать базу

Укажите адрес сайта из `SITE_URL` с путём `/callback` и свой email:

```sh
cd "$HOME/www/server"
make init OAUTH_REDIRECT_URI=http://192.168.1.10:8888/callback ADMIN_EMAIL=admin@example.com
docker compose ps
```

При первом старте PostgreSQL 17 создаст базу в томе `postgres17_data`. `make init` установит зависимости PHP, создаст ключи OAuth, применит миграции, зарегистрирует клиент Vue и создаст администратора. Сохраните пароль из вывода команды и проверьте вход через браузер.

Nginx доступен на всех интерфейсах на порту `8888`, PostgreSQL — на заданном LAN IP на порту `5432`. Symfony подключается к базе по имени `postgres`. Если меняется адрес сайта, обновите redirect URI существующего OAuth-клиента `frontend`.

### Если база уже была запущена на PostgreSQL 16

В `~/www/backend/.env.local` поменяйте `serverVersion=16` на `serverVersion=17`, сохранив реквизиты подключения. Из `~/www/server` остановите приложение и запустите PostgreSQL 17:

```sh
docker compose stop nginx php-fpm
docker compose up -d --wait postgres
```

Compose подключит новый том `postgres17_data`. Старый том `postgres_data` сохранится. Если есть дамп, восстановите его в пустую базу PostgreSQL 17 перед запуском `make init`. Если дампа нет и нужна чистая установка, выполните шаг 5.

## Последующие обновления

Получите изменения из нужных репозиториев:

```sh
git -C "$HOME/www/server" pull --ff-only
git -C "$HOME/www/backend" pull --ff-only
git -C "$HOME/www/frontend-src" pull --ff-only
```

После изменений frontend повторите шаг 4. После изменений конфигурации сервера или backend выполните:

```sh
cd "$HOME/www/server"
make up && make composer-install && make migrations && docker compose restart php-fpm nginx
```

Файлы `.env` для Compose и `.env.local` для Symfony, ключи OAuth и данные PostgreSQL остаются на сервере. Для остановки используйте `make stop`. Для диагностики используйте `docker compose ps` и `docker compose logs --tail=80`.
