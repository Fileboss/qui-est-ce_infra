#!/bin/bash
# Runs once on first volume init (standard /docker-entrypoint-initdb.d/ behaviour).
# The app DB (POSTGRES_DB) is already created by the postgres image at this point;
# this script only adds the second DB used by Keycloak, owned by its own role.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE USER ${KC_DB_USERNAME} WITH PASSWORD '${KC_DB_PASSWORD}';
    CREATE DATABASE keycloak OWNER ${KC_DB_USERNAME};
EOSQL
