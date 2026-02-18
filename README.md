# docker-swarm-nginx — Datadog observability showcase

Demonstrates **metrics, APM traces, and logs** from a Docker Swarm stack that uses **nginx as an API gateway** in front of a **Spring Boot (Java)** app and a **Laravel (PHP)** app, all monitored by the Datadog Agent.

Reference: [Datadog nginx proxy tracing setup](https://docs.datadoghq.com/tracing/trace_collection/proxy_setup/nginx/) · [DataDog/nginx-datadog on GitHub](https://github.com/DataDog/nginx-datadog)

---

## Architecture

```
Client
  │
  ▼
nginx-gateway  (port 80)          ← ngx_http_datadog_module (APM tracing)
  │             /java/*            ← JSON access logs with dd.trace_id / dd.span_id
  │             /php/*
  ├──▶ springboot-app:8080         ← dd-java-agent (APM)
  │                                ← JSON logs with trace correlation
  └──▶ laravel-app:80              ← dd-trace-php (APM)
                                   ← stderr logs with trace injection

datadog-agent  (global, one per Swarm node)
  ├── Receives APM traces from nginx, Spring Boot, Laravel on :8126
  ├── Scrapes nginx metrics via stub_status (/nginx_status)
  ├── Collects container logs from all services
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
| **Logs** | All services | Container log collection |
| **Log-Trace correlation** | nginx / Spring Boot | `dd.trace_id` injected in JSON logs |

---

## How nginx tracing works (step by step)

This section walks through exactly what was done to instrument nginx, following the official [DataDog/nginx-datadog](https://github.com/DataDog/nginx-datadog) approach.

### Step 1 — Download the Datadog nginx module

Datadog publishes pre-built dynamic module (`.so`) files for specific nginx versions and architectures at:

```
https://github.com/DataDog/nginx-datadog/releases/download/<TAG>/
  ngx_http_datadog_module-<ARCH>-<NGINX_VERSION>.so.tgz
```

The module is a **C++ dynamic nginx module** (it uses Datadog's C++ tracer under the hood, which is why traces show `client: cpp` in the agent status). It must exactly match:
- The nginx **binary version** running in your container
- The container **CPU architecture** (`amd64` or `arm64`)

In this repo we use nginx `1.28.2` and module release `v1.12.0`. The download URLs are:

| Arch | URL |
|---|---|
| `linux/arm64` | `https://github.com/DataDog/nginx-datadog/releases/download/v1.12.0/ngx_http_datadog_module-arm64-1.28.2.so.tgz` |
| `linux/amd64` | `https://github.com/DataDog/nginx-datadog/releases/download/v1.12.0/ngx_http_datadog_module-amd64-1.28.2.so.tgz` |

### Step 2 — Build a custom nginx Docker image

`nginx/Dockerfile`:

```dockerfile
FROM nginx:1.28.2

# TARGETARCH is injected automatically by docker buildx:
#   linux/arm64  → TARGETARCH=arm64
#   linux/amd64  → TARGETARCH=amd64
# Do NOT provide a default — letting BuildKit set it correctly.
ARG TARGETARCH

ENV DD_NGINX_MODULE_VERSION=v1.12.0
ENV NGINX_VERSION=1.28.2

# Download the correct .so for this platform, extract to the nginx modules dir,
# then remove the download tooling to keep the image small.
RUN apt-get update \
    && apt-get install -y --no-install-recommends wget \
    && wget -q \
       "https://github.com/DataDog/nginx-datadog/releases/download/${DD_NGINX_MODULE_VERSION}/ngx_http_datadog_module-${TARGETARCH}-${NGINX_VERSION}.so.tgz" \
       -O /tmp/dd-module.tgz \
    && tar -xzf /tmp/dd-module.tgz -C /usr/lib/nginx/modules/ \
    && rm /tmp/dd-module.tgz \
    && apt-get purge -y wget \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

> **Multi-arch note**: `ARG TARGETARCH` with **no default** is required. If you write `ARG TARGETARCH=amd64`, BuildKit's automatic value for arm64 is silently overridden and the wrong `.so` is baked in — the container will start but nginx will refuse to load the module (architecture mismatch).

Build and push for both architectures in one step:

```bash
docker buildx build \
  --platform linux/arm64,linux/amd64 \
  --push \
  -t wwongpai/nginx-datadog:latest \
  ./nginx
```

### Step 3 — Load the module and configure tracing in nginx.conf

`nginx/nginx.conf`:

```nginx
# ── 1. Load the Datadog module ─────────────────────────────────────────────
# Must be the very first directive, before events {} and http {}.
# Use the absolute path to avoid ambiguity across nginx builds.
load_module /usr/lib/nginx/modules/ngx_http_datadog_module.so;

events {
    worker_connections 1024;
}

http {
    # ── 2. Connect to the Datadog Agent ──────────────────────────────────────
    # Default is http://localhost:8126. In Docker Swarm we use the service
    # name alias so it resolves via the overlay network DNS.
    datadog_agent_url http://datadog-agent:8126;

    # ── 3. Unified Service Tagging ────────────────────────────────────────────
    # These map to DD_SERVICE, DD_ENV, DD_VERSION and appear on every span.
    datadog_service_name nginx-gateway;
    datadog_environment  demo;
    datadog_version      1.0.0;

    # ── 4. Sampling rate ─────────────────────────────────────────────────────
    # 1.0 = keep 100% of traces (good for demos; lower in production).
    datadog_sample_rate 1.0;

    # ── 5. Trace context propagation ─────────────────────────────────────────
    # The module injects trace headers into every proxied request so that
    # the downstream service (Spring Boot / Laravel) continues the same trace.
    # "tracecontext" = W3C standard (traceparent/tracestate headers)
    # "datadog"      = Datadog proprietary (x-datadog-trace-id, etc.)
    # Both are injected, so either style is accepted by the upstream tracer.
    datadog_propagation_styles tracecontext datadog;

    # ── 6. JSON access log with trace/span IDs ───────────────────────────────
    # $datadog_trace_id and $datadog_span_id are nginx variables exposed by
    # the module. They contain the hex-encoded IDs of the active span.
    # Including them in logs enables log ↔ trace correlation in Datadog.
    log_format dd_json escape=json
        '{'
            '"timestamp":"$time_iso8601",'
            '"remote_addr":"$remote_addr",'
            '"method":"$request_method",'
            '"uri":"$request_uri",'
            '"status":$status,'
            '"body_bytes_sent":$body_bytes_sent,'
            '"request_time":$request_time,'
            '"upstream_addr":"$upstream_addr",'
            '"upstream_status":"$upstream_status",'
            '"upstream_response_time":"$upstream_response_time",'
            '"http_user_agent":"$http_user_agent",'
            '"dd.trace_id":"$datadog_trace_id",'
            '"dd.span_id":"$datadog_span_id"'
        '}';

    access_log /dev/stdout dd_json;
    error_log  /dev/stderr warn;

    server {
        listen 80;

        # ── 7. Per-location resource names ───────────────────────────────────
        # datadog_resource_name sets the span's "resource" field in Datadog APM.
        # The default is "$request_method $uri". Overriding per location makes
        # the service map and trace list easier to read.

        location /java/ {
            proxy_pass http://springboot-app:8080/;
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            datadog_resource_name "$request_method /java/";
        }

        location /php/ {
            proxy_pass http://laravel-app:80/;
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            datadog_resource_name "$request_method /php/";
        }

        # ── 8. Exclude internal endpoints from tracing ────────────────────────
        # stub_status is hit every 15 s by the Datadog agent nginx check.
        # datadog_tracing off prevents these from polluting the APM trace list.
        location /nginx_status {
            stub_status;
            datadog_tracing off;
            allow 127.0.0.1;
            allow 10.0.0.0/8;
            deny  all;
        }

        location /health {
            datadog_tracing off;
            return 200 "ok\n";
            add_header Content-Type text/plain;
        }
    }
}
```

### Step 4 — Configure the Datadog Agent to receive traces

In `docker-stack.yml` the agent is configured with:

```yaml
DD_APM_ENABLED: "true"
DD_APM_NON_LOCAL_TRAFFIC: "true"   # accept traces from other containers
```

`DD_APM_NON_LOCAL_TRAFFIC` is required — by default the agent only accepts traces from `localhost`. Without it the nginx module connects to port 8126 but the agent silently drops every payload.

### Step 5 — Configure nginx metrics (stub_status check)

The Datadog agent `nginx` integration check is mounted via Docker Swarm configs.

`datadog/nginx.d/conf.yaml`:

```yaml
init_config:

instances:
  - nginx_status_url: http://nginx-gateway/nginx_status
```

This file is mounted to `/etc/datadog-agent/conf.d/nginx.d/conf.yaml` inside the agent container via the `configs:` block in `docker-stack.yml`. The agent scrapes `/nginx_status` every 15 seconds and emits 7 metrics (`nginx.net.connections`, `nginx.net.request_per_s`, etc.).

### What a trace looks like end-to-end

```
nginx-gateway span (operation: nginx.request)
│  resource:  GET /java/work
│  service:   nginx-gateway
│  duration:  ~101 ms
│
└── springboot-app span (operation: servlet.request)
       resource:  GET /work
       service:   springboot-app
       duration:  ~100 ms (Thread.sleep)
```

The nginx module injects `traceparent` (W3C) and `x-datadog-trace-id` headers into the proxied request. The dd-java-agent in Spring Boot reads those headers and creates its span as a **child** of the nginx span — producing a single connected flame graph in Datadog APM.

### nginx module variables used for log correlation

The module exposes these nginx variables that can be used in `log_format`:

| Variable | Type | Description |
|---|---|---|
| `$datadog_trace_id` | hex 128-bit | Full trace ID — use this in log formats |
| `$datadog_span_id` | hex 64-bit | Current span ID |
| `$datadog_trace_id_64bits_base10` | decimal | Lower 64 bits of trace ID (decimal) |
| `$datadog_span_id_64bits_base10` | decimal | Span ID in decimal |
| `$datadog_json` | JSON string | Full span metadata as JSON |

We use `$datadog_trace_id` and `$datadog_span_id` in the `dd_json` log format. This is what enables the **"View Trace"** button on a log line in Datadog Log Explorer — the backend matches the `dd.trace_id` field in the log to the stored trace.

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

# Multi-arch (both at once):
PLATFORM=linux/arm64,linux/amd64 ./scripts/build_push.sh
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
while true; do
  curl -s http://$HOST/java/work > /dev/null
  curl -s http://$HOST/php/work  > /dev/null
  sleep 0.5
done
```

### 5. Check Datadog

| What to look at | URL |
|---|---|
| APM Service Map | https://app.datadoghq.com/apm/map?env=demo |
| APM Traces | https://app.datadoghq.com/apm/traces?env=demo |
| nginx metrics dashboard | https://app.datadoghq.com/dash/integration/21/nginx---overview |
| Log Explorer | https://app.datadoghq.com/logs?query=env%3Ademo |

---

## Images on Docker Hub

| Image | Description |
|---|---|
| `wwongpai/nginx-datadog:latest` | nginx 1.28.2 + `ngx_http_datadog_module` v1.12.0 (multi-arch) |
| `wwongpai/springboot-nginx-demo:latest` | Spring Boot 3.2.1 + dd-java-agent (multi-arch) |
| `wwongpai/laravel-nginx-demo:latest` | Laravel 11 + dd-trace-php 1.16.0 (multi-arch) |
| `wwongpai/datadog-agent:latest` | Mirrored `datadog/agent:latest` |

---

## Stack management

```bash
# View services
docker stack services nginx-demo

# Follow logs for a service
docker service logs nginx-demo_nginx-gateway -f
docker service logs nginx-demo_springboot-app -f
docker service logs nginx-demo_laravel-app -f

# Run the nginx check manually and verify metrics
docker exec $(docker ps -q -f name=nginx-demo_datadog-agent) agent check nginx

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
| `GET /health` | nginx | Health probe (tracing disabled) |
| `GET /nginx_status` | nginx | stub_status — internal, scraped by agent (tracing disabled) |

---

## Security notes

- `DD_API_KEY` is passed via environment variable substitution (`${DD_API_KEY}`) in `docker-stack.yml` — it is **never hardcoded** in any committed file.
- The `.env` file (where you store the real key locally) is in `.gitignore`.
- Docker images contain **no secrets**. The API key is injected at container runtime by Docker Swarm.
