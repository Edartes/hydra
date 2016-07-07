sourceRoot="$PWD"
hydraDevDir="$sourceRoot/inst"
export HYDRA_HOME="$sourceRoot/src"

function setupEnvVars() {
    PGDATABASE=hydra
    PGHOST="$hydraDevDir/sockets"
    PGPORT=5432
    HYDRA_DATA="$hydraDevDir/data"
    HYDRA_DBI="dbi:Pg:dbname=$PGDATABASE;port=$PGPORT;host=$PGHOST"
    export PGDATABASE PGHOST PGPORT HYDRA_DATA HYDRA_DBI
}

function stop-database() {
    if [ -e "$hydraDevDir/database/postmaster.pid" ]; then
        pg_ctl -D "$hydraDevDir/database" stop
    fi
}

function start-database() {
    [ -e "$hydraDevDir/database/postmaster.pid" ] \
        && pg_ctl -D "$hydraDevDir/database" status &> /dev/null \
        && return 0
    mkdir -p "$hydraDevDir/sockets"
    if type -P setsid &> /dev/null; then
        local ctl="setsid -w pg_ctl"
    else
        local ctl=pg_ctl
    fi
    $ctl -D "$hydraDevDir/database" \
        -o "-F -k '$hydraDevDir/sockets' -p 5432 -h ''" -w start
    trap stop-database EXIT
}

if [ -e "$hydraDevDir/database" ]; then
    setupEnvVars
    start-database
fi

function setup-database() {
    setupEnvVars
    initdb -D "$hydraDevDir/database" \
        && start-database \
        && createdb -p 5432 -h "$hydraDevDir/sockets" hydra \
        && mkdir -p "$HYDRA_DATA" \
        && hydra-init \
        && return 0
    return 1
}

function setup-dev-env() {
    if [ ! -e "$sourceRoot/configure" ]; then
        "$sourceRoot/bootstrap" || return 1
    fi
    if [ ! -e Makefile ]; then
        "$sourceRoot/configure" $configureFlags || return 1
    fi
    if [ ! -e "$HYDRA_HOME/sql/hydra-postgresql.sql" ]; then
        make || return 1
    fi
    if [ ! -e "$hydraDevDir/database" ]; then
        setup-database || return 1
        hydra-create-user admin --password admin --role admin || return 1
    fi
}
