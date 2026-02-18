# docker-swarm-nginx — Datadog observability showcase

Demonstrates **metrics, APM traces, and logs** from a Docker Swarm stack that uses **nginx as an API gateway** in front of a **Spring Boot (Java)** app and a **Laravel (PHP)** app, all monitored by the Datadog Agent.

---

## Architecture

```
Client
  │
  ▼
nginx-gateway  (port 80)          ← Datadog nginx tracing module (APM)
  │             /java/*            ← JSON access logs with trace/span IDs
  │             /php/*
  ├──▶ springboot-app:8080         ← dd-java-agent (APM)
  │                                ← JSON structured logs with trace correlation
  └──▶ laravel-app:80             ← dd-trace-php (APM)
                                   ← stderr logs with trace injection

datadog-agent  (global, one per node)
  ├── Collects container logs from all services
  ├── Receives APM traces from nginx, Spring Boot, Laravel
  ├── Scrapes nginx metrics via stub_status (/nginx_status)
  └── Ships everything to Datadog (datadoghq.com / us1)
```

## What you get in Datadog

| Signal | Source | How |
|---|---|---|
| **Metrics** | nginx | `nginx` integration check via `stub_status` |
| **Metrics** | Docker Swarm | Docker integration (auto) |
| **APM Traces** | nginx | `ngx_http_datadog_module` v1.12.0 |
| **APM Traces** | Spring Boot | `dd-java-agent` (baked into image) |
| **APM Traces** | Laravel | `dd-trace-php` (baked into image) |
| **Logs** | All services | Container log collection with JSON parsing |
| **Log-Trace correlation** | nginx / Spring Boot | `dd.trace_id` injected in JSON logs |

---

## Prerequisites

- Docker Swarm initialised (`docker swarm init`)
- Docker Buildx with multi-arch support
- Logged into Docker Hub (`docker login`)
- A Datadog account on **us1** (`datadoghq.com`)

---

## Quickstart

### 1. Configure your Datadog API key

```bash
cp .env.example .env
# Edit .env and set DD_API_KEY=<your_key>
```

> `.env` is listed in `.gitignore` — it will never be committed.

### 2. Build and push images

```bash
chmod +x scripts/build_push.sh scripts/deploy.sh

# Default: linux/arm64 (Apple Silicon / ARM nodes)
./scripts/build_push.sh

# For x86-64 nodes:
PLATFORM=linux/amd64 ./scripts/build_push.sh
```

### 3. Deploy the stack

```bash
./scripts/deploy.sh            # stack name: nginx-demo
# or:
./scripts/deploy.sh my-stack
```

### 4. Generate traffic

```bash
HOST=localhost   # or your Swarm manager IP

# Spring Boot (Java) via nginx
curl http://$HOST/java/
curl http://$HOST/java/work

# Laravel (PHP) via nginx
curl http://$HOST/php/
curl http://$HOST/php/work

# Continuous traffic for a richer trace view
for i in $(seq 1 50); do
  curl -s http://$HOST/java/work > /dev/null
  curl -s http://$HOST/php/work  > /dev/null
done
```

### 5. Check Datadog

| What to look at | URL |
|---|---|
| APM Service Map | https://app.datadoghq.com/apm/map |
| APM Traces | https://app.datadoghq.com/apm/traces |
| nginx metrics dashboard | https://app.datadoghq.com/dash/integration/21/nginx---overview |
| Log Explorer | https://app.datadoghq.com/logs |

---

## Images on Docker Hub

| Image | Description |
|---|---|
| `wwongpai/nginx-datadog:latest` | nginx 1.28.2 + Datadog `ngx_http_datadog_module` v1.12.0 |
| `wwongpai/springboot-nginx-demo:latest` | Spring Boot 3.2.1 + dd-java-agent |
| `wwongpai/laravel-nginx-demo:latest` | Laravel 11 + dd-trace-php |
| `wwongpai/datadog-agent:latest` | Mirrored `datadog/agent:latest` |

---

## Stack management

```bash
# View services
docker stack services nginx-demo

# View logs for a service
docker service logs nginx-demo_nginx-gateway -f
docker service logs nginx-demo_springboot-app -f
docker service logs nginx-demo_laravel-app -f

# Remove stack
docker stack rm nginx-demo
```

---

## Endpoints

| Path | Upstream | Description |
|---|---|---|
| `GET /java/` | springboot-app:8080/ | Spring Boot root |
| `GET /java/work` | springboot-app:8080/work | 100 ms simulated latency |
| `GET /php/` | laravel-app:80/ | Laravel root |
| `GET /php/work` | laravel-app:80/work | 100 ms simulated latency |
| `GET /health` | nginx | nginx health probe (not traced) |
| `GET /nginx_status` | nginx | stub_status (internal, scraped by agent) |

---

## Security notes

- `DD_API_KEY` is passed via environment variable substitution in `docker-stack.yml` — it is **never hardcoded** in any committed file.
- The `.env` file (where you store the real key locally) is in `.gitignore`.
- Docker images contain **no secrets**.
