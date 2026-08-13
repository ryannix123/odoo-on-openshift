#!/usr/bin/env bash
# Entrypoint for Odoo on OpenShift.
# - Tolerates the arbitrary UID OpenShift assigns under restricted-v2 SCC
# - Renders /etc/odoo/odoo.conf from environment variables
# - Waits for PostgreSQL
# - Auto-initializes the database on first boot, then just runs on restarts
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Arbitrary UID handling.
# OpenShift runs the container as a random UID with no /etc/passwd entry.
# Several Python libraries (and Odoo's session code) call getpwuid() and fail
# with "cannot find name for user id". If nss_wrapper is unavailable we fall
# back to appending an entry to a writable passwd file.
# ---------------------------------------------------------------------------
if ! whoami &>/dev/null; then
    if [ -w /etc/passwd ]; then
        echo "odoo:x:$(id -u):0:Odoo user:/var/lib/odoo:/sbin/nologin" >> /etc/passwd
    else
        export NSS_WRAPPER_PASSWD=/tmp/passwd
        export NSS_WRAPPER_GROUP=/etc/group
        cp /etc/passwd /tmp/passwd 2>/dev/null || touch /tmp/passwd
        echo "odoo:x:$(id -u):0:Odoo user:/var/lib/odoo:/sbin/nologin" >> /tmp/passwd
    fi
fi

export HOME=/var/lib/odoo

# ---------------------------------------------------------------------------
# 2. Configuration.
# Defaults align with the SuiteCRM project's convention: the DB service is
# reachable at its service name, everything else is generated/overridable.
# ---------------------------------------------------------------------------
DB_HOST="${DB_HOST:-postgresql}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-odoo}"
DB_PASSWORD="${DB_PASSWORD:-odoo}"
DB_NAME="${DB_NAME:-odoo}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"          # Odoo "master" password
WITHOUT_DEMO="${WITHOUT_DEMO:-all}"                 # set to False to load demo data
WORKERS="${WORKERS:-0}"                             # 0 = threaded mode (fine for sandbox)
LIST_DB="${LIST_DB:-False}"                         # hide DB manager by default

CONF=/etc/odoo/odoo.conf
cat > "${CONF}" <<EOF
[options]
admin_passwd = ${ADMIN_PASSWORD}
db_host = ${DB_HOST}
db_port = ${DB_PORT}
db_user = ${DB_USER}
db_password = ${DB_PASSWORD}
db_name = ${DB_NAME}
dbfilter = ^${DB_NAME}\$
data_dir = /var/lib/odoo
addons_path = /opt/odoo/src/addons,/opt/odoo/src/odoo/addons,/mnt/extra-addons
list_db = ${LIST_DB}
proxy_mode = True
workers = ${WORKERS}
without_demo = ${WITHOUT_DEMO}
log_level = info
EOF

echo ">> Rendered ${CONF}:"
grep -v -E 'password|passwd' "${CONF}" | sed 's/^/   /'

# ---------------------------------------------------------------------------
# 3. Wait for PostgreSQL to accept connections.
# ---------------------------------------------------------------------------
echo ">> Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT} ..."
export PGPASSWORD="${DB_PASSWORD}"
for i in $(seq 1 60); do
    if pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -q; then
        echo ">> PostgreSQL is ready."
        break
    fi
    if [ "${i}" -eq 60 ]; then
        echo "!! PostgreSQL not ready after 120s, exiting." >&2
        exit 1
    fi
    sleep 2
done

# ---------------------------------------------------------------------------
# 4. First-boot initialization.
# We check whether the target database already has Odoo's schema. If the
# ir_module_module table is absent, we initialize the base module set. On
# subsequent restarts this is skipped and Odoo just serves.
# ---------------------------------------------------------------------------
db_initialized() {
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
        -tAc "SELECT to_regclass('public.ir_module_module');" 2>/dev/null \
        | grep -q "ir_module_module"
}

# Ensure the database itself exists (Odoo can create it, but only if the role
# has CREATEDB; the bitnami/crunchy postgres images grant that to the app user).
if ! psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c '\q' 2>/dev/null; then
    echo ">> Database ${DB_NAME} not reachable yet; Odoo will attempt to create it."
fi

if [ "${1:-odoo}" = "odoo" ]; then
    if db_initialized; then
        echo ">> Existing Odoo database detected — skipping initialization."
    else
        echo ">> Fresh database — initializing base modules (demo data: ${WITHOUT_DEMO})."
        odoo -c "${CONF}" -d "${DB_NAME}" -i base \
            --without-demo="${WITHOUT_DEMO}" --stop-after-init

        # With demo data disabled, the admin account has no usable login
        # password. Seed a known one (from ADMIN_LOGIN_PASSWORD, default 'admin')
        # via the Odoo shell so the operator can log in immediately.
        ADMIN_LOGIN_PASSWORD="${ADMIN_LOGIN_PASSWORD:-admin}"
        echo ">> Setting admin login password."
        echo "admin_user = env['res.users'].browse(2); admin_user.login = 'admin'; admin_user.password = '${ADMIN_LOGIN_PASSWORD}'; env.cr.commit()" \
            | odoo shell -c "${CONF}" -d "${DB_NAME}" --no-http 2>/dev/null || \
            echo "!! Could not auto-set admin password; use the master password to set it via the UI."
        echo ">> Initialization complete."
    fi
    echo ">> Starting Odoo."
    exec odoo -c "${CONF}"
fi

# Passthrough for any other command (e.g. `oc rsh` debugging).
exec "$@"
