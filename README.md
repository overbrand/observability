# Overbrand observability

One monitoring platform for every Overbrand app (BuyNSellem, Eventez, the
next ones): one Grafana, one Prometheus, one Loki, one uptime prober, one
alert routing. Apps keep almost nothing on their side: they follow the
contract below, and an agent on their machine ships everything here.

```
             ┌─────────────── Observability VPS (Dokploy) ───────────────┐
 agents ───▶ │ Traefik ─▶ Prometheus  ─▶ rules ─▶ Alertmanager ─▶ Telegram│
 (push,      │  (basic    Loki        ─▶ rules ─┘                 └─▶ e-mail│
  basic auth)│   auth)    Blackbox ─▶ probes every public URL            │
             │            Grafana (dashboards, Logto sign-in)            │
             └───────────────────────────────────────────────────────────┘
   Eventez VPS: agents/alloy-docker      BNS Dokploy: agents/alloy-docker
   BNS AKS: agents/alloy-k8s (installed by the BNS Pulumi stack)
```

| Folder | What |
|---|---|
| `server/` | The central stack (Docker Compose, deployed by Dokploy) |
| `agents/alloy-docker/` | The agent for a Docker host (VPS, Dokploy server) |
| `agents/alloy-k8s/` | The agent for a Kubernetes cluster (Helm values) |
| `grafana/dashboards/` | `Overbrand/` generic dashboards; one folder per project for its own |
| `grafana/alerts/` | Generic alert rules (Prometheus and Loki) |
| `uptime/` | The public URLs probed, one file per project |
| `scripts/` | `check.sh` validates everything; `ingest-user.sh` makes an agent credential |

## The contract (what an app must do)

1. **Logs on stdout/stderr**, JSON preferred (`{"level":"error",…}`;
   pino's numeric levels and Python's `levelname` are understood too). No
   log files inside the container.
2. **Labels `project`, `env`, `service`.** Nothing to do in the common case:
   the agent sets `project`/`env` for the whole machine and `service` from
   the compose service (Docker) or the pod's `app` label (Kubernetes). A
   machine that runs several projects labels its containers
   `overbrand.project`, `overbrand.env` (and optionally `overbrand.service`).
3. **A health endpoint** that answers 2xx with `"status":"ok"` (or
   `"healthy"`; `"degraded"` also passes), listed in `uptime/<project>.yml`.
   `/metrics` is optional: label the container `overbrand.metrics.port`
   (and `overbrand.metrics.path`) and the agent scrapes it.
4. **A Sentry project per app** for exceptions and traces (unchanged).
5. Optionally, **business dashboards** in `grafana/dashboards/<Project>/`.

Containers labelled `overbrand.logs=false` are not collected.

## Deploy the central stack (Dokploy)

1. DNS: `grafana.overbrand.net` and `ingest.overbrand.net` → the Dokploy server.
2. Dokploy → Create → **Docker Compose**: repository
   `git@github.com:overbrand/observability.git`, branch `main`, compose path
   `server/docker-compose.yml`.
3. Environment: copy `server/.env.example` and fill it in (see below for
   Telegram, the ingest users and the heartbeat).
4. Deploy. Grafana: `https://grafana.overbrand.net`, user `admin`.

Sizing: 2 vCPU / 4 GB RAM / 40 GB disk is plenty for a few projects at
30 days of metrics and 14 days of logs (`METRICS_RETENTION`, `LOGS_RETENTION`).

**Telegram**: create a bot with @BotFather (`TELEGRAM_BOT_TOKEN`), add it
to one group per project plus an ops group, send a message in each, then
read the chat ids (negative numbers) at
`https://api.telegram.org/bot<token>/getUpdates`.

**Heartbeat** (recommended): a free healthchecks.io check with a 1-minute
period and 5-minute grace, its ping URL in `HEARTBEAT_URL`. The `Watchdog`
alert pings it every minute; if the monitoring server dies, healthchecks.io
tells you — nothing inside a dead server can.

**Logto sign-in** (optional): a "Traditional web" app in the Overbrand
Logto, redirect URI `https://grafana.overbrand.net/login/generic_oauth`,
then `LOGTO_ENABLED=true` with its endpoint, client id and secret. Logto
role `grafana-admin` → Grafana Admin, `grafana-editor` → Editor, anyone
else Viewer. Keep the local admin as the way in when SSO is down.

## Connect a machine

Every agent has its own credential, so one can be revoked alone:

```bash
scripts/ingest-user.sh eventez-vps
```

prints `INGEST_USER`/`INGEST_PASSWORD` for the agent and an htpasswd entry
to append to the central `INGEST_USERS` (comma-separated, in single quotes).
Redeploy the central stack after changing `INGEST_USERS`.

### Eventez (plain Docker VPS)

```bash
git clone git@github.com:overbrand/observability.git /opt/overbrand-observability
cd /opt/overbrand-observability/agents/alloy-docker
cp .env.example .env    # PROJECT=eventez ENV=production HOST_NAME=eventez-vps + the credential
docker compose up -d
```

### BuyNSellem on Dokploy

Dokploy → Create → Docker Compose, same repository, compose path
`agents/alloy-docker/docker-compose.yml`, environment from
`agents/alloy-docker/.env.example` with `PROJECT=bns`, `ENV=staging` (or
`production`), `HOST_NAME=bns-dokploy`. The central stack's own containers
are labelled `overbrand.project=overbrand`, so a server that hosts both is
fine.

### BuyNSellem on AKS

The BNS Pulumi stack installs `grafana/k8s-monitoring` with the values of
`agents/alloy-k8s/values.yaml` once configured:

```bash
cd infra
pulumi config set --path observability.username bns-aks
pulumi config set --secret observabilityIngestPassword <password>
pulumi up
```

Any other cluster: `helm upgrade --install` with `agents/alloy-k8s/values.yaml`
(see the header of that file).

## Add an app

1. It follows the contract.
2. Its machine gets the agent (or nothing, if it already has one).
3. Its public URLs go in `uptime/<project>.yml`.
4. Its alerts go to their own Telegram group and address: add the project
   to `PROJECTS` and two `TELEGRAM_CHAT_<P>` / `EMAIL_<P>` lines in
   `server/docker-compose.yml` (obs-alertmanager). Without them they go to ops.

No new Grafana, dashboards or alert rules: the generic ones select by
`project`.

## What is watched

| Alert | When |
|---|---|
| `EndpointDown` | a URL in `uptime/` fails for 3 minutes (critical) |
| `EndpointSlow` | it takes over 5 s on average for 10 minutes |
| `CertificateExpiresSoon` | its TLS certificate has under 14 days (3 days: critical) |
| `AgentSilent` | a project/env that sent metrics stops for 5 minutes (critical) |
| `HostCpuHigh` / `HostMemoryHigh` / `HostDiskFilling` | 90 % / 90 % / 85 % (95 %: critical) |
| `ContainerRestarting` / `ContainerMemoryNearLimit` | Docker containers |
| `PodCrashLooping`, `PodNotReady`, `ContainerNearMemoryLimit`, `ContainerCpuThrottled`, `HpaAtMaximum`, `VolumeAlmostFull`, `JobFailed`, `NodeNotReady` | Kubernetes (`JobFailed` covers the MongoDB backup CronJob) |
| `ErrorLogSpike` | a service logs over 20 errors in 5 minutes (Loki) |
| `ObservabilityComponentDown` | a part of this stack is down |
| `Watchdog` | always: the heartbeat |

Dashboards (Grafana → Overbrand): **Services** (uptime, firing alerts,
container CPU/memory/restarts, errors), **Uptime** (status, 24 h/7 d
availability, certificates), **Hosts**, **Logs** (search).

## Develop

`scripts/check.sh` validates every file with the tool that runs it
(promtool, amtool, Loki, Alloy, docker compose). Run it before pushing.

Notes:
- On its first start an agent replays each container's Docker log history;
  Loki refuses lines older than 7 days (`timestamp too old` in the agent's
  log), once, then it is quiet.
- The Docker agent needs `privileged`, `pid: host` and `cgroup: host` to
  see the other containers (cgroup v2).
- Alertmanager's config is generated at start by
  `server/alertmanager/render.sh`, so secrets stay in the environment.
