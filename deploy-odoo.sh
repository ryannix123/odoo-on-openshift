#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy-odoo.sh — one-command Odoo 19 on OpenShift (tuned for Developer Sandbox)
#
#   ./deploy-odoo.sh            Deploy Odoo + PostgreSQL into the current project
#   ./deploy-odoo.sh status     Show pods, routes, and saved credentials
#   ./deploy-odoo.sh cleanup    Remove everything this script created
#
# Designed for the Red Hat Developer Sandbox: restricted-v2 SCC (arbitrary
# UID, no root), generous quota. No cluster admin required.
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- Configuration --------------------------------------------------------
ODOO_IMAGE="${ODOO_IMAGE:-quay.io/ryan_nix/odoo-openshift:19.0}"
# RHEL PostgreSQL image runs as an arbitrary non-root UID out of the box,
# which is exactly what the Sandbox's restricted-v2 SCC requires.
POSTGRES_IMAGE="${POSTGRES_IMAGE:-registry.redhat.io/rhel9/postgresql-16:latest}"

APP_NAME="odoo"
DB_NAME_INTERNAL="odoo"
DB_USER="odoo"
CREDS_FILE="odoo-credentials.txt"

ODOO_STORAGE="${ODOO_STORAGE:-5Gi}"     # filestore (attachments, sessions)
DB_STORAGE="${DB_STORAGE:-5Gi}"         # PostgreSQL data

# ---- Helpers --------------------------------------------------------------
c_reset='\033[0m'; c_blue='\033[0;34m'; c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'
info()  { echo -e "${c_blue}>>${c_reset} $*"; }
ok()    { echo -e "${c_green}✓${c_reset} $*"; }
warn()  { echo -e "${c_yellow}!${c_reset} $*"; }
die()   { echo -e "${c_red}✗ $*${c_reset}" >&2; exit 1; }

gen_pw() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }

require_oc() {
    command -v oc >/dev/null 2>&1 || die "The 'oc' CLI is not installed or not on PATH."
    oc whoami >/dev/null 2>&1 || die "Not logged in. Run 'oc login ...' first."
    PROJECT="$(oc project -q)"
    info "Target project: ${c_green}${PROJECT}${c_reset}"
}

# ---- Cleanup --------------------------------------------------------------
cleanup() {
    require_oc
    warn "Deleting all Odoo resources in project ${PROJECT}..."
    oc delete deployment,statefulset,svc,route,secret,pvc \
        -l "app.kubernetes.io/part-of=${APP_NAME}" --ignore-not-found
    rm -f "${CREDS_FILE}"
    ok "Cleanup complete. (PVCs deleted — data is gone.)"
    exit 0
}

# ---- Status ---------------------------------------------------------------
status() {
    require_oc
    echo
    info "Pods:"
    oc get pods -l "app.kubernetes.io/part-of=${APP_NAME}" -o wide || true
    echo
    info "Routes:"
    oc get route -l "app.kubernetes.io/part-of=${APP_NAME}" \
        -o custom-columns=NAME:.metadata.name,URL:.spec.host 2>/dev/null || true
    echo
    if [ -f "${CREDS_FILE}" ]; then
        info "Saved credentials (${CREDS_FILE}):"
        sed 's/^/   /' "${CREDS_FILE}"
    else
        warn "No ${CREDS_FILE} found in this directory."
    fi
    exit 0
}

# ---- Deploy ---------------------------------------------------------------
deploy() {
    require_oc

    local db_password admin_password login_password
    db_password="$(gen_pw)"
    admin_password="$(gen_pw)"    # Odoo master (database-manager) password
    login_password="$(gen_pw)"    # admin user's web login password

    info "Creating secret with generated credentials..."
    oc create secret generic "${APP_NAME}-secret" \
        --from-literal=db-user="${DB_USER}" \
        --from-literal=db-password="${db_password}" \
        --from-literal=db-name="${DB_NAME_INTERNAL}" \
        --from-literal=admin-password="${admin_password}" \
        --from-literal=login-password="${login_password}" \
        --dry-run=client -o yaml | oc apply -f -
    oc label secret "${APP_NAME}-secret" \
        "app.kubernetes.io/part-of=${APP_NAME}" --overwrite >/dev/null

    # ---------------- PostgreSQL ------------------
    info "Deploying PostgreSQL..."
    oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-data
  labels: { app.kubernetes.io/part-of: ${APP_NAME}, app.kubernetes.io/component: database }
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: ${DB_STORAGE} } }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql
  labels: { app.kubernetes.io/part-of: ${APP_NAME}, app.kubernetes.io/component: database }
spec:
  replicas: 1
  selector: { matchLabels: { app: postgresql } }
  strategy: { type: Recreate }
  template:
    metadata:
      labels:
        app: postgresql
        app.kubernetes.io/part-of: ${APP_NAME}
        app.kubernetes.io/component: database
    spec:
      containers:
      - name: postgresql
        image: ${POSTGRES_IMAGE}
        ports: [ { containerPort: 5432 } ]
        env:
        - { name: POSTGRESQL_USER,     valueFrom: { secretKeyRef: { name: ${APP_NAME}-secret, key: db-user } } }
        - { name: POSTGRESQL_PASSWORD, valueFrom: { secretKeyRef: { name: ${APP_NAME}-secret, key: db-password } } }
        - { name: POSTGRESQL_DATABASE, valueFrom: { secretKeyRef: { name: ${APP_NAME}-secret, key: db-name } } }
        readinessProbe:
          exec: { command: ["/usr/libexec/check-container"] }
          initialDelaySeconds: 5
          timeoutSeconds: 10
        livenessProbe:
          tcpSocket: { port: 5432 }
          initialDelaySeconds: 30
        resources:
          requests: { cpu: 100m, memory: 256Mi }
          limits:   { cpu: 500m, memory: 512Mi }
        volumeMounts:
        - { name: data, mountPath: /var/lib/pgsql/data }
      volumes:
      - name: data
        persistentVolumeClaim: { claimName: postgresql-data }
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  labels: { app.kubernetes.io/part-of: ${APP_NAME}, app.kubernetes.io/component: database }
spec:
  selector: { app: postgresql }
  ports: [ { port: 5432, targetPort: 5432 } ]
EOF

    info "Waiting for PostgreSQL to become ready..."
    oc rollout status deployment/postgresql --timeout=180s

    # ---------------- Odoo ------------------
    info "Deploying Odoo..."
    oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odoo-data
  labels: { app.kubernetes.io/part-of: ${APP_NAME}, app.kubernetes.io/component: app }
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: ${ODOO_STORAGE} } }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: odoo
  labels: { app.kubernetes.io/part-of: ${APP_NAME}, app.kubernetes.io/component: app }
spec:
  replicas: 1
  selector: { matchLabels: { app: odoo } }
  strategy: { type: Recreate }
  template:
    metadata:
      labels:
        app: odoo
        app.kubernetes.io/part-of: ${APP_NAME}
        app.kubernetes.io/component: app
    spec:
      containers:
      - name: odoo
        image: ${ODOO_IMAGE}
        ports: [ { containerPort: 8069 }, { containerPort: 8072 } ]
        env:
        - { name: DB_HOST, value: postgresql }
        - { name: DB_PORT, value: "5432" }
        - { name: DB_USER,     valueFrom: { secretKeyRef: { name: ${APP_NAME}-secret, key: db-user } } }
        - { name: DB_PASSWORD, valueFrom: { secretKeyRef: { name: ${APP_NAME}-secret, key: db-password } } }
        - { name: DB_NAME,     valueFrom: { secretKeyRef: { name: ${APP_NAME}-secret, key: db-name } } }
        - { name: ADMIN_PASSWORD,       valueFrom: { secretKeyRef: { name: ${APP_NAME}-secret, key: admin-password } } }
        - { name: ADMIN_LOGIN_PASSWORD, valueFrom: { secretKeyRef: { name: ${APP_NAME}-secret, key: login-password } } }
        - { name: WITHOUT_DEMO, value: "all" }
        - { name: WORKERS, value: "0" }
        readinessProbe:
          httpGet: { path: /web/health, port: 8069 }
          initialDelaySeconds: 20
          periodSeconds: 10
          timeoutSeconds: 10
          failureThreshold: 30
        livenessProbe:
          httpGet: { path: /web/health, port: 8069 }
          initialDelaySeconds: 90
          periodSeconds: 30
          timeoutSeconds: 10
        resources:
          requests: { cpu: 200m, memory: 512Mi }
          limits:   { cpu: "1",  memory: 1536Mi }
        volumeMounts:
        - { name: data, mountPath: /var/lib/odoo }
      volumes:
      - name: data
        persistentVolumeClaim: { claimName: odoo-data }
---
apiVersion: v1
kind: Service
metadata:
  name: odoo
  labels: { app.kubernetes.io/part-of: ${APP_NAME}, app.kubernetes.io/component: app }
spec:
  selector: { app: odoo }
  ports:
  - { name: http,     port: 8069, targetPort: 8069 }
  - { name: longpoll, port: 8072, targetPort: 8072 }
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: odoo
  labels: { app.kubernetes.io/part-of: ${APP_NAME}, app.kubernetes.io/component: app }
  annotations:
    haproxy.router.openshift.io/timeout: "600s"
spec:
  to: { kind: Service, name: odoo }
  port: { targetPort: http }
  tls: { termination: edge, insecureEdgeTerminationPolicy: Redirect }
EOF

    info "Waiting for Odoo to initialize (first boot builds the database — this can take a few minutes)..."
    oc rollout status deployment/odoo --timeout=600s

    local host
    host="$(oc get route odoo -o jsonpath='{.spec.host}')"

    # ---------------- Save credentials ------------------
    cat > "${CREDS_FILE}" <<EOF
Odoo on OpenShift — deployment credentials
==========================================
URL:              https://${host}
Login (email):    admin
Login password:   ${login_password}
Master password:  ${admin_password}    (database manager / master password)
Database name:    ${DB_NAME_INTERNAL}
DB user:          ${DB_USER}
DB password:      ${db_password}
EOF
    chmod 600 "${CREDS_FILE}"

    echo
    ok "Odoo is deployed."
    echo -e "   URL:            ${c_green}https://${host}${c_reset}"
    echo -e "   Login:          admin / ${login_password}"
    echo -e "   All credentials saved to ${c_green}${CREDS_FILE}${c_reset}"
    echo
    warn "Sandbox note: pods scale to zero when idle. Wake them with:"
    echo "   oc scale deployment --all --replicas=1 -n \$(oc project -q)"
}

# ---- Dispatch -------------------------------------------------------------
case "${1:-deploy}" in
    deploy)  deploy ;;
    status)  status ;;
    cleanup) cleanup ;;
    *) die "Unknown command '${1}'. Use: deploy | status | cleanup" ;;
esac
