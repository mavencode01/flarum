#!/bin/sh

# Env variables
export DB_HOST
export DB_USER
export DB_NAME
export DB_PREF
export DEBUG

# Default values
DB_HOST=${DB_HOST:-mariadb}
DB_USER=${DB_USER:-flarum}
DB_NAME=${DB_NAME:-flarum}
DB_PREF=${DB_PREF:-""}
DEBUG=${DEBUG:-false}

# Required env variables
if [ -z "$DB_PASS" ]; then
  echo "[ERROR] Mariadb database password must be set !"
  exit 1
fi

if [ -z "$FORUM_URL" ]; then
  echo "[ERROR] Forum url must be set !"
  exit 1
fi

# Set permissions
chown -R $UID:$GID /flarum /etc/nginx /etc/php7 /var/log /var/lib/nginx /tmp /etc/s6.d

cd /flarum/app/

# Installation settings
cat > config.yml <<EOF
databaseConfiguration:
    driver: mysql
    host: ${DB_HOST}
    database: ${DB_NAME}
    username: ${DB_USER}
    password: ${DB_PASS}
    prefix: ${DB_PREF}

baseUrl: ${FORUM_URL}
EOF

# Installer problem, wait fix in beta 6
# PHP Fatal error:  Uncaught ReflectionException: Class flarum.config does not
# exist in /flarum/vendor/illuminate/container/Container.php
# https://github.com/flarum/core/commit/7192c4391bee006ccc2de3db6caa89803d72d130
# sed -i -e 's|InfoCommand::class,||g' \
#        -e "s|\['config' => \$app->make('flarum.config')\]|['config' => \$app->isInstalled() ? \$app->make('flarum.config') : []]|g" vendor/flarum/core/src/Console/Server.php

# if no installation was performed before
if [ ! -e 'assets/rev-manifest.json' ]; then

  echo "[INFO] First launch, installing flarum..."

  # Mail settings
  sed -i -e "s|{{ DB_NAME }}|${DB_NAME}|g" \
         -e "s|{{ MAIL_FROM }}|${MAIL_FROM}|g" \
         -e "s|{{ MAIL_HOST }}|${MAIL_HOST}|g" \
         -e "s|{{ MAIL_PORT }}|${MAIL_PORT}|g" \
         -e "s|{{ MAIL_USER }}|${MAIL_USER}|g" \
         -e "s|{{ MAIL_PASS }}|${MAIL_PASS}|g" \
         -e "s|{{ MAIL_ENCR }}|${MAIL_ENCR}|g" config.sql

  # Install flarum
  su-exec $UID:$GID php flarum install --file config.yml

  # Define flarum settings in database
  mysql -h"${DB_HOST}" -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" < config.sql

  echo "[INFO] Installation done, launch flarum..."

else

  echo "[INFO] Flarum already installed, init app..."

  # Disable already done steps during installation
  # ----------------------------------------------
  #
  # See : flarum/core/src/Install/Console/DefaultsDataProvider.php
  #       flarum/core/src/Install/Console/InstallCommand.php
  #
  #   runMigrations() = Database migration (Flarum\Database\Migrator)
  #   writeSettings() = Writing default flarum settings (Flarum\Settings\SettingsRepositoryInterface)
  #      seedGroups() = Create default groups
  # seedPermissions() = Create default permissions
  # createAdminUser() = Create default admin user
  #sed -i -e '/$this->runMigrations();/ s/^/#/'   \
  #       -e '/$this->writeSettings();/ s/^/#/'   \
  #       -e '/$this->seedGroups();/ s/^/#/'      \
  #       -e '/$this->seedPermissions();/ s/^/#/' \
  #       -e '/$this->createAdminUser();/ s/^/#/' vendor/flarum/core/src/Install/Console/InstallCommand.php

  # Init flarum (without steps above)
  su-exec $UID:$GID php flarum migrate
  su-exec $UID:$GID php flarum cache:clear

  # Composer cache dir and packages list paths
  CACHE_DIR=/flarum/app/assets/.extensions
  LIST_FILE=assets/.extensions/list

  # Download extra extensions installed with composer wrapup script
  if [ -s "$LIST_FILE" ]; then
    echo "[INFO] Install extra bundled extensions"
    while read extension; do
      echo "[INFO] -------------- Install extension : ${extension} --------------"
      COMPOSER_CACHE_DIR="$CACHE_DIR" su-exec $UID:$GID composer require "$extension"
    done < "$LIST_FILE"
    echo "[INFO] Install extra bundled extensions. DONE."
  fi

  echo "[INFO] Init done, launch flarum..."

fi

# Set flarum debug mode
if [ -f "config.php" ]; then
  sed -i -e "s|\('debug' =>\) .*|\1 ${DEBUG},|" \
         -e "s|\('host' =>\) .*|\1 '${DB_HOST}',|" \
         -e "s|\('database' =>\) .*|\1 '${DB_NAME}',|" \
         -e "s|\('username' =>\) .*|\1 '${DB_USER}',|" \
         -e "s|\('password' =>\) .*|\1 '${DB_PASS}',|" \
         -e "s|\('prefix' =>\) .*|\1 '${DB_PREF}',|" \
         -e "s|\('url' =>\) .*|\1 '${FORUM_URL}',|" config.php
fi

# Removing installation files
rm -f config.sql config.yml

# Set permissions
chown -R $UID:$GID /flarum

# RUN !
exec su-exec $UID:$GID /bin/s6-svscan /etc/s6.d
