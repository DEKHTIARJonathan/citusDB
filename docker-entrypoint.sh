#!/bin/bash
set -e

if [ "$1" = 'postgres' ]; then
    chown -R postgres "$PGDATA"

    if [ -z "$(ls -A "$PGDATA")" ]; then
        gosu postgres initdb

        sed -ri "s/^#(listen_addresses\s*=\s*)\S+/\1'*'/" "$PGDATA"/postgresql.conf

        # check password first so we can ouptut the warning before postgres
        # messes it up
        if [ "$POSTGRES_PASSWORD" ]; then
            pass="PASSWORD '$POSTGRES_PASSWORD'"
            authMethod=md5
        else
            # The - option suppresses leading tabs but *not* spaces. :)
            cat >&2 <<-'EOWARN'
			****************************************************
			WARNING: No password has been set for the database.
			         This will allow anyone with access to the
			         Postgres port to access your database. In
			         Docker's default configuration, this is
			         effectively any other container on the same
			         system.

			         Use "-e POSTGRES_PASSWORD=password" to set
			         it in "docker run".
			****************************************************
			EOWARN

            pass=
            authMethod=trust
        fi

        : ${POSTGRES_USER:=postgres}
        : ${POSTGRES_DB:=$POSTGRES_USER}

        if [ "$POSTGRES_DB" != 'postgres' ]; then
            gosu postgres postgres --single -jE <<-EOSQL
				CREATE DATABASE "$POSTGRES_DB" ;
			EOSQL
            echo
        fi

        if [ "$POSTGRES_USER" = 'postgres' ]; then
            op='ALTER'
        else
            op='CREATE'
        fi

        gosu postgres postgres --single -jE <<-EOSQL
			$op USER "$POSTGRES_USER" WITH SUPERUSER $pass ;
		EOSQL
        echo

        { echo; echo "host all all 0.0.0.0/0 $authMethod"; } >> "$PGDATA"/pg_hba.conf

        if [ -d /docker-entrypoint-initdb.d ]; then
            for f in /docker-entrypoint-initdb.d/*.sh; do
                [ -f "$f" ] && . "$f"
            done
        fi
		
		
	
    fi

    if [ "$CITUS_MASTER" ]; then
        echo "Loading linked citus workers"
        . /reload-workers.sh
    fi
	
	gosu postgres postgres --single -jE <<-EOSQL
		-- load extension first time after install
		CREATE EXTENSION cstore_fdw;

		-- create server object
		CREATE SERVER cstore_server FOREIGN DATA WRAPPER cstore_fdw;
	EOSQL
	echo
	
    exec gosu postgres "$@"
fi

sed -i '68s/.*/max_connections = 300                   # (change requires restart)/'  "$PGDATA"/postgresql.conf
sed -i '68s/.*/max_connections = 300                   # (change requires restart)/'  /opt/citusdb/4.0/data/postgresql.conf
sed -i "151s/.*/shared_preload_libraries = 'cstore_fdw'         # (change requires restart)/" "$PGDATA"/postgresql.conf
sed -i "151s/.*/shared_preload_libraries = 'cstore_fdw'         # (change requires restart)/" /opt/citusdb/4.0/data/postgresql.conf
gosu postgres pg_ctl stop
gosu postgres pg_ctl -w start

exec "$@"
