.DEFAULT_GOAL := up
.PHONY: up stop down tunnel init composer-install oauth-keys migrations oauth-client restore-oauth-redirect create-admin

PHP_EXEC = docker compose exec -T --user www-data -e APP_ENV=prod
CONSOLE = $(PHP_EXEC) php-fpm php bin/console --no-interaction
ADMIN_EMAIL ?= admin@lab.local

up:
	docker compose up -d --build --wait

stop:
	docker compose stop

down:
	docker compose down --remove-orphans

tunnel:
	@compose_env=$$(docker compose config --environment) || exit $$?; \
		token=$$(printf '%s\n' "$$compose_env" | sed -n 's/^TUNNEL_TOKEN=//p'); \
		test -n "$$token" || { echo 'Укажите TUNNEL_TOKEN в .env.' >&2; exit 1; }; \
		set --; \
		if [ -f tls/ca.crt ]; then \
			set -- --mount "type=bind,source=$$PWD/tls/ca.crt,target=/etc/cloudflared/labs-ca.crt,readonly"; \
		fi; \
		TUNNEL_TOKEN="$$token" docker run --rm --network host --env TUNNEL_TOKEN "$$@" \
			cloudflare/cloudflared:latest tunnel --no-autoupdate --protocol http2 run

init:
	@test -n '$(OAUTH_REDIRECT_URI)' || { echo 'Укажите OAUTH_REDIRECT_URI с адресом сайта и путём /callback.' >&2; exit 1; }
	$(MAKE) up
	$(MAKE) composer-install
	$(MAKE) oauth-keys
	$(MAKE) migrations
	$(MAKE) oauth-client
	$(MAKE) create-admin

composer-install:
	$(PHP_EXEC) -e COMPOSER_HOME=/tmp/composer php-fpm composer install --no-dev --no-interaction --optimize-autoloader
	$(PHP_EXEC) php-fpm composer check-platform-reqs --no-dev

oauth-keys:
	$(CONSOLE) league:oauth2-server:generate-keypair --skip-if-exists
	$(PHP_EXEC) php-fpm chmod 600 config/jwt/private.pem
	$(PHP_EXEC) php-fpm chmod 644 config/jwt/public.pem

migrations:
	$(CONSOLE) doctrine:migrations:migrate --allow-no-migration

oauth-client:
	@test -n '$(OAUTH_REDIRECT_URI)' || { echo 'Укажите OAUTH_REDIRECT_URI с адресом сайта и путём /callback.' >&2; exit 1; }
	@clients=$$($(CONSOLE) league:oauth2-server:list-clients --columns=identifier --columns='redirect uri' --no-ansi) && \
		if ! printf '%s\n' "$$clients" | grep -Eq '^[[:space:]]*\|[[:space:]]*frontend[[:space:]]*\|'; then \
			$(CONSOLE) league:oauth2-server:create-client Frontend frontend --public \
				--grant-type=authorization_code --grant-type=refresh_token --scope=api \
				--redirect-uri='$(OAUTH_REDIRECT_URI)'; \
		elif ! printf '%s\n' "$$clients" | awk -F '[|]' -v uri='$(OAUTH_REDIRECT_URI)' '\
			$$2 ~ /^[[:space:]]*frontend[[:space:]]*$$/ { \
				gsub(/^[[:space:]]+|[[:space:]]+$$/, "", $$3); \
				count = split($$3, redirects, ", "); \
				for (i = 1; i <= count; i++) if (redirects[i] == uri) found = 1; \
			} END { exit !found }'; then \
			$(CONSOLE) league:oauth2-server:update-client frontend --add-redirect-uri='$(OAUTH_REDIRECT_URI)'; \
		fi

restore-oauth-redirect: oauth-client

create-admin:
	$(CONSOLE) app:user:create-admin '$(ADMIN_EMAIL)' --generate-password
