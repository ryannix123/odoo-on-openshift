# Odoo on OpenShift

![OpenShift](https://img.shields.io/badge/OpenShift-4.x-red?logo=redhatopenshift)
![Odoo](https://img.shields.io/badge/Odoo-19.0-714B67?logo=odoo&logoColor=white)
![UBI](https://img.shields.io/badge/UBI-10-red?logo=redhat&logoColor=white)
![SCC](https://img.shields.io/badge/SCC-restricted--v2-brightgreen)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)
![Quay.io](https://img.shields.io/badge/Quay.io-Container-red?logo=redhat&logoColor=white)

Deploy [Odoo 19 Community](https://github.com/odoo/odoo) on Red Hat OpenShift on a **Red Hat Universal Base Image 10** foundation, with automatic database initialization and PostgreSQL.

> **No cluster? No problem.** The [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox) gives you a free OpenShift environment — no credit card, no expiration. Clone this repo, run the deploy script, and you'll have a working ERP in a few minutes.

## Features

- **UBI 10 base** — built entirely on Red Hat's Universal Base Image, not Debian/Ubuntu like the upstream Odoo image
- **Automated Installation** — no manual database-manager step; the entrypoint initializes Odoo's base modules on first boot and sets a known admin password
- **OpenShift Optimized** — runs as an arbitrary non-root UID, compatible with the Developer Sandbox's `restricted-v2` SCC
- **Persistent Storage** — the filestore and database survive restarts
- **Report-ready PDFs** — bundles `wkhtmltopdf 0.12.6` with patched Qt for proper report headers/footers
- **Secure by Default** — TLS-terminated route, generated credentials, database manager hidden (`list_db = False`)
- **Weekly CI/CD Builds** — automated container builds pick up UBI security updates

## Quick Start

```bash
# Clone the repository
git clone https://github.com/ryannix123/odoo-on-openshift.git
cd odoo-on-openshift

# Deploy to your current OpenShift project
./deploy-odoo.sh
```

The script prints the URL and admin login when it finishes. Everything is also written to `odoo-credentials.txt`.

## Requirements

- OpenShift 4.x cluster (or the [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox))
- `oc` CLI logged into your cluster
- Quota for 2 pods and ~10Gi of storage

## Architecture

```
┌─────────────────────────────────────────────┐
│               OpenShift Route                │
│           (TLS termination, edge)            │
└──────────────────────┬──────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│                 Odoo Pod                     │
│      Python 3.12 + Odoo 19 on UBI 10         │
│         built-in HTTP server :8069           │
│          longpolling :8072                   │
└──────────────────────┬──────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│              PostgreSQL Pod                  │
│        registry.redhat.io RHEL 16            │
│               (Port 5432)                    │
│                 5Gi PVC                      │
└─────────────────────────────────────────────┘
```

Unlike PHP applications, Odoo ships its own multi-threaded HTTP server, so there is **no nginx/PHP-FPM/supervisord sidecar** — a single process serves the app.

## Components

| Component  | Image                                       | Purpose                       |
| ---------- | ------------------------------------------- | ----------------------------- |
| Odoo       | `quay.io/ryan_nix/odoo-openshift:19.0`      | ERP application (UBI 10)      |
| PostgreSQL | `registry.redhat.io/rhel9/postgresql-16`    | Database (runs non-root)      |

## Usage

```bash
./deploy-odoo.sh            # Deploy
./deploy-odoo.sh status     # Show pods, route, and saved credentials
./deploy-odoo.sh cleanup    # Tear everything down (deletes PVCs)
```

### View logs

```bash
oc logs -f deployment/odoo
oc logs -f deployment/postgresql
```

## Why UBI 10?

The upstream Odoo container is built on Ubuntu. Rebuilding on UBI 10 means the whole stack sits on a Red Hat–supported base with a predictable CVE feed and `dnf`-managed dependencies — the same foundation as everything else you run on OpenShift. It also demonstrates the pattern cleanly: take an upstream open-source app and re-home it on the Red Hat platform without changing how it works.

## Configuration

The container reads everything from environment variables at startup and renders `/etc/odoo/odoo.conf` on the fly, so the image stays credential-free.

| Variable               | Default      | Description                                  |
| ---------------------- | ------------ | -------------------------------------------- |
| `DB_HOST`              | `postgresql` | Database hostname                            |
| `DB_PORT`              | `5432`       | Database port                                |
| `DB_USER`              | `odoo`       | Database username                            |
| `DB_PASSWORD`          | `odoo`       | Database password                            |
| `DB_NAME`              | `odoo`       | Database name                                |
| `ADMIN_PASSWORD`       | `admin`      | Odoo master (database-manager) password      |
| `ADMIN_LOGIN_PASSWORD` | `admin`      | Web login password for the `admin` user      |
| `WITHOUT_DEMO`         | `all`        | Set to `False` to load demo data             |
| `WORKERS`              | `0`          | `0` = threaded mode (fine for the Sandbox)   |
| `LIST_DB`              | `False`      | Hide the database manager UI                 |

### Storage

| PVC               | Size | Purpose                       |
| ----------------- | ---- | ----------------------------- |
| `odoo-data`       | 5Gi  | Filestore (attachments, etc.) |
| `postgresql-data` | 5Gi  | Database files                |

## Custom Add-ons

Odoo's community add-ons live in `/mnt/extra-addons`. To ship your own modules, fork this repo and copy them into the image:

```dockerfile
COPY my-addons/ /mnt/extra-addons/
```

Then rebuild and push, and point `ODOO_IMAGE` in `deploy-odoo.sh` at your image. Building add-ons into the image (rather than mounting them) keeps every deployment reproducible and rollback-friendly.

## Building the Container Image

```bash
podman build --platform linux/amd64 \
  --build-arg ODOO_VERSION=19.0 \
  -t quay.io/your-username/odoo-openshift:19.0 -f Containerfile .

podman push quay.io/your-username/odoo-openshift:19.0
```

## CI/CD

`.github/workflows/build-image.yml` builds and pushes the image:

- **Weekly builds** every Monday at 06:00 UTC to pick up UBI security updates
- **Manual trigger** with an optional Odoo version override via `workflow_dispatch`
- **Multi-tag push** to Quay.io: full version (`19.0`), major (`19`), and `latest`

Add two repository secrets under **Settings → Secrets and variables → Actions**:

| Secret          | Value                          |
| --------------- | ------------------------------ |
| `QUAY_USERNAME` | Your Quay.io username          |
| `QUAY_PASSWORD` | Quay.io password or robot token |

## Troubleshooting

### Developer Sandbox scaled down my pods

The Sandbox scales deployments to zero after inactivity. Wake them:

```bash
oc scale deployment --all --replicas=1 -n $(oc project -q)
```

### Odoo pod is slow to become ready on first boot

First boot initializes the entire base module set before serving traffic — this can take a few minutes. The readiness probe allows for it (`failureThreshold: 30`). Watch progress with:

```bash
oc logs -f deployment/odoo
```

### Login not working

```bash
# Confirm the admin password was seeded on first boot
cat odoo-credentials.txt
```

If the seed step was skipped (logged as a warning), open the database manager with the master password and set the password from the UI.

### Check credentials

```bash
cat odoo-credentials.txt
```

## Files

| File                                | Description                                    |
| ----------------------------------- | ---------------------------------------------- |
| `deploy-odoo.sh`                    | Main deployment script (deploy/status/cleanup) |
| `Containerfile`                     | UBI 10 container build                          |
| `entrypoint.sh`                     | Startup: UID handling, config, first-boot init |
| `odoo.conf`                         | Build-time placeholder config                  |
| `.github/workflows/build-image.yml` | Weekly CI/CD build pipeline                     |

## Resources

- [Odoo 19 Documentation](https://www.odoo.com/documentation/19.0/)
- [Odoo Deployment Guide](https://www.odoo.com/documentation/19.0/administration/on_premise/deploy.html)
- [Red Hat Universal Base Images](https://catalog.redhat.com/software/base-images)
- [OpenShift Documentation](https://docs.openshift.com/)

## License

Odoo Community is licensed under LGPLv3. This deployment tooling is provided as-is; test on OpenShift before production use.
