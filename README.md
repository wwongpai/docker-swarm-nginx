# docker-swarm-nginx — Datadog observability showcase

Demonstrates **metrics, APM traces, and logs** from a Docker Swarm stack that uses **nginx as an API gateway** in front of a **Spring Boot (Java)** app and a **Laravel (PHP)** app, all monitored by the Datadog Agent.

References:
- [Datadog nginx proxy tracing setup](https://docs.datadoghq.com/tracing/trace_collection/proxy_setup/nginx/)
- [DataDog/nginx-datadog on GitHub](https://github.com/DataDog/nginx-datadog)
- [Datadog Java APM](https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/dd_libraries/java/)
- [Datadog PHP APM](https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/dd_libraries/php/)
- [Log and Trace Correlation](https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/)

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
  │                                ← JSON logs with dd.trace_id / dd.span_id
  └──▶ laravel-app:80              ← dd-trace-php (APM)
                                   ← stderr logs with dd.trace_id injected

datadog-agent  (global — one per Swarm node)
  ├── Receives APM traces from nginx, Spring Boot, Laravel on :8126
  ├── Scrapes nginx metrics via stub_status (/nginx_status)
  ├── Collects container logs from all services
  └── Ships metrics + traces + logs → Datadog (datadoghq.com / us1)
```

## What you get in Datadog

| Signal | Source | How |
|---|---|---|
| **Metrics** | nginx | `nginx` integration check via `stub_status` |
| **Metrics** | Docker Swarm | Docker integration (auto) |
| **APM Traces** | nginx | `ngx_http_datadog_module` v1.12.0 |
| **APM Traces** | Spring Boot | `dd-java-agent` baked into image |
| **APM Traces** | Laravel | `dd-trace-php` baked into image |
| **Logs** | All services | Container log collection |
| **Log–Trace correlation** | All services | `dd.trace_id` + `dd.span_id` in every log line |

---

## Section 1 — How nginx tracing works (step by step)

### Background

The official approach ([docs.datadoghq.com/tracing/trace_collection/proxy_setup/nginx](https://docs.datadoghq.com/tracing/trace_collection/proxy_setup/nginx/)) uses the open-source **[DataDog/nginx-datadog](https://github.com/DataDog/nginx-datadog)** dynamic module. It is a C++ nginx module that:

1. Creates an APM span for every request nginx handles.
2. Injects distributed trace headers (`traceparent`, `x-datadog-trace-id`, etc.) into every proxied `proxy_pass` request so the downstream service continues the same trace.
3. Exposes nginx variables (`$datadog_trace_id`, `$datadog_span_id`) that you embed in `log_format` for log–trace correlation.

### Step 1.1 — Choose the right module file

Pre-built `.so` files are published at:

```
https://github.com/DataDog/nginx-datadog/releases/download/<TAG>/
  ngx_http_datadog_module-<ARCH>-<NGINX_VERSION>.so.tgz
```

The file must match **both** the nginx binary version **and** the container CPU architecture exactly. A mismatch causes nginx to refuse startup with a `dlopen failed` error.

This repo uses:

| Target | Download filename |
|---|---|
| `linux/arm64` | `ngx_http_datadog_module-arm64-1.28.2.so.tgz` |
| `linux/amd64` | `ngx_http_datadog_module-amd64-1.28.2.so.tgz` |

Module version: **v1.12.0** — nginx version: **1.28.2**

### Step 1.2 — Build a custom nginx image

`nginx/Dockerfile`:

```dockerfile
FROM nginx:1.28.2

# TARGETARCH is injected automatically by docker buildx:
#   --platform linux/arm64  →  TARGETARCH=arm64
#   --platform linux/amd64  →  TARGETARCH=amd64
#
# IMPORTANT: do NOT write ARG TARGETARCH=amd64 with a default.
# A default silently overrides what BuildKit sets, so the arm64 image
# ends up with the amd64 .so — nginx loads but immediately refuses to
# dlopen the module (architecture mismatch).
ARG TARGETARCH

ENV DD_NGINX_MODULE_VERSION=v1.12.0
ENV NGINX_VERSION=1.28.2

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

Build and push multi-arch in one command:

```bash
docker buildx build \
  --platform linux/arm64,linux/amd64 \
  --push \
  -t wwongpai/nginx-datadog:latest \
  ./nginx
```

### Step 1.3 — Load the module in nginx.conf

```nginx
# Must be the very first directive — before events {} and http {}.
# Use the absolute path to avoid ambiguity across nginx builds.
load_module /usr/lib/nginx/modules/ngx_http_datadog_module.so;
```

### Step 1.4 — Configure the Datadog directives in the http block

All `datadog_*` directives that apply globally go inside `http {}`:

```nginx
http {
    # Where the Datadog Agent listens for traces.
    # Default is http://localhost:8126.
    # In Docker Swarm we use the service name alias on the overlay network.
    datadog_agent_url http://datadog-agent:8126;

    # Unified Service Tagging — these appear on every span this nginx creates.
    datadog_service_name nginx-gateway;
    datadog_environment  demo;
    datadog_version      1.0.0;

    # Keep 100% of traces (reduce in production, e.g. 0.1 for 10%).
    datadog_sample_rate 1.0;

    # Inject BOTH W3C (traceparent/tracestate) AND Datadog proprietary headers
    # into every proxied request. This ensures downstream services using either
    # tracer style can continue the same distributed trace.
    datadog_propagation_styles tracecontext datadog;
}
```

### Step 1.5 — Set resource names per location

```nginx
location /java/ {
    proxy_pass http://springboot-app:8080/;
    # Override the default resource name "$request_method $uri".
    # A clean name makes the APM service map and trace list readable.
    datadog_resource_name "$request_method /java/";
}

location /php/ {
    proxy_pass http://laravel-app:80/;
    datadog_resource_name "$request_method /php/";
}
```

### Step 1.6 — Disable tracing on internal endpoints

```nginx
location /nginx_status {
    stub_status;
    # The Datadog agent polls this URL every 15 s for nginx metrics.
    # Without this directive, each poll creates a trace — polluting APM.
    datadog_tracing off;
    allow 10.0.0.0/8;
    deny  all;
}

location /health {
    datadog_tracing off;
    return 200 "ok\n";
}
```

### Step 1.7 — How distributed trace propagation works

When a request arrives at nginx, the module:

1. Creates an nginx span (`operation: nginx.request`, `service: nginx-gateway`).
2. Injects the trace context into the upstream `proxy_pass` request as HTTP headers:
   - `traceparent` / `tracestate` — W3C standard
   - `x-datadog-trace-id` / `x-datadog-parent-id` / `x-datadog-sampling-priority` — Datadog format
3. The dd-java-agent or dd-trace-php in the upstream service reads those headers and creates its own child span, linking it to the nginx span.

Result — a single connected flame graph in Datadog APM:

```
nginx-gateway  nginx.request  GET /java/work   101 ms
  └── springboot-app  servlet.request  GET /work   100 ms
```

### Step 1.8 — Verify nginx is sending traces

```bash
# Run the agent status command inside the running agent container
docker exec $(docker ps -q -f name=nginx-demo_datadog-agent) agent status \
  | grep -A 10 "Receiver"
```

You will see a `cpp` client entry (nginx uses Datadog's C++ tracer internally):

```
From cpp 202002 (), client v2.0.0
  Traces received: 44 (45,803 bytes)
  Spans received: 44
```

---

## Section 2 — How to collect nginx metrics and logs

### 2.1 — nginx metrics via stub_status

nginx does not expose a Prometheus endpoint natively. The Datadog agent has a built-in **nginx integration check** that scrapes the `stub_status` module.

#### Enable stub_status in nginx.conf

```nginx
location /nginx_status {
    stub_status;
    datadog_tracing off;
    # Only allow access from localhost and the Docker overlay network
    allow 127.0.0.1;
    allow 10.0.0.0/8;
    deny  all;
}
```

`stub_status` exposes a plain-text page:

```
Active connections: 3
server accepts handled requests
 76 76 76
Reading: 0 Writing: 1 Waiting: 2
```

#### Tell the Datadog agent where to find it

Create `datadog/nginx.d/conf.yaml`:

```yaml
init_config:

instances:
  - nginx_status_url: http://nginx-gateway/nginx_status
```

`nginx-gateway` resolves via the Docker Swarm overlay network DNS to the nginx service VIP. The agent scrapes this URL every 15 seconds and emits these metrics to Datadog:

| Metric | Description |
|---|---|
| `nginx.net.connections` | Active connections |
| `nginx.net.request_per_s` | Requests per second |
| `nginx.net.conn_opened_per_s` | Connections accepted per second |
| `nginx.net.conn_dropped_per_s` | Connections dropped per second |
| `nginx.net.reading` | Connections reading request |
| `nginx.net.writing` | Connections writing response |
| `nginx.net.waiting` | Idle keep-alive connections |

#### Mount the check config via Docker Swarm configs

In `docker-stack.yml`, the config file is mounted into the agent container without rebuilding the agent image:

```yaml
# Declare the config object (read from the local file at deploy time)
configs:
  nginx_check_config:
    file: ./datadog/nginx.d/conf.yaml

services:
  datadog-agent:
    configs:
      - source: nginx_check_config
        target: /etc/datadog-agent/conf.d/nginx.d/conf.yaml
```

The agent auto-discovers any `.yaml` file placed under `conf.d/nginx.d/` and runs the nginx check.

#### Verify the check is working

```bash
docker exec $(docker ps -q -f name=nginx-demo_datadog-agent) agent check nginx
```

Expected output:

```
nginx (9.2.0)
-------------
  Instance ID: nginx:e838dd3271511d05 [OK]
  Metric Samples: Last Run: 7, Total: 7
  version.raw: 1.28.2
```

### 2.2 — nginx log collection

#### Write JSON access logs with trace IDs

The nginx-datadog module exposes two variables that you use directly in `log_format`:

| Variable | Value |
|---|---|
| `$datadog_trace_id` | Hex 128-bit trace ID of the active span |
| `$datadog_span_id` | Hex 64-bit span ID of the active span |

Define a JSON log format using these variables:

```nginx
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

# Log to stdout so Docker captures it (agent tails container log files)
access_log /dev/stdout dd_json;
error_log  /dev/stderr warn;
```

A log line looks like:

```json
{
  "timestamp": "2026-02-18T07:17:23+00:00",
  "remote_addr": "10.0.0.2",
  "method": "GET",
  "uri": "/java/work",
  "status": 200,
  "request_time": 0.111,
  "upstream_addr": "10.0.2.5:80",
  "upstream_response_time": "0.111",
  "dd.trace_id": "699567830000000052313a8c56cef6ec",
  "dd.span_id": "52313a8c56cef6ec"
}
```

#### Tell the agent what source to apply to nginx logs

In `docker-stack.yml`, add a Docker label to the `nginx-gateway` service:

```yaml
nginx-gateway:
  labels:
    com.datadoghq.ad.logs: '[{"source":"nginx","service":"nginx-gateway"}]'
```

`source: nginx` tells the agent to apply the built-in **nginx log processing pipeline** in Datadog, which parses the access log fields automatically. `service: nginx-gateway` links the log to the service in APM.

#### How the agent collects container logs

In `docker-stack.yml`, the agent is configured with:

```yaml
DD_LOGS_ENABLED: "true"
DD_LOGS_CONFIG_CONTAINER_COLLECT_ALL: "true"
```

And the Docker socket and container log directory are mounted:

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
  - /var/lib/docker/containers:/var/lib/docker/containers:ro
```

The agent reads `/var/lib/docker/containers/<container-id>/<container-id>-json.log` for every running container. When it finds a container that has the `com.datadoghq.ad.logs` label, it applies the source and service tags from the label to every log line from that container.

---

## Section 3 — How to trace Java (Spring Boot) in Docker Swarm

### 3.1 — How dd-java-agent works

The Datadog Java tracer (`dd-java-agent.jar`) is a **Java agent** — a JAR attached to the JVM at startup via the standard `-javaagent` flag. It instruments Spring Boot automatically using bytecode injection (no code changes needed). It:

- Creates spans for every HTTP request, JDBC call, Redis command, etc.
- Reads environment variables (`DD_SERVICE`, `DD_ENV`, `DD_VERSION`) for Unified Service Tagging.
- Reads `DD_AGENT_HOST` / `DD_TRACE_AGENT_PORT` to find the Datadog agent.
- Reads incoming trace headers (`traceparent`, `x-datadog-trace-id`) to continue a distributed trace started by nginx.
- Injects `dd.trace_id` and `dd.span_id` into **SLF4J MDC** automatically when `DD_LOGS_INJECTION=true`.

### 3.2 — Bake dd-java-agent into the Docker image

`springboot-app/Dockerfile`:

```dockerfile
# ── Stage 1: Build the JAR ────────────────────────────────────────────────────
FROM wwongpai/maven:3.9-eclipse-temurin-17 AS build
WORKDIR /workspace
COPY pom.xml .
COPY src ./src
RUN mvn -q -DskipTests package

# ── Stage 2: Runtime image ────────────────────────────────────────────────────
FROM wwongpai/eclipse-temurin:17-jre
WORKDIR /app

# Download the latest dd-java-agent from Datadog's CDN shortlink.
# This always pulls the newest stable release at build time.
ADD https://dtdg.co/latest-java-tracer /datadog/dd-java-agent.jar

COPY --from=build /workspace/target/springboot-nginx-demo-1.0.0.jar app.jar

EXPOSE 8080

# Attach the agent to the JVM at every startup.
# JAVA_TOOL_OPTIONS is read automatically by the JVM — no changes to the
# application's own startup command are needed.
ENV JAVA_TOOL_OPTIONS="-javaagent:/datadog/dd-java-agent.jar"

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

No changes to `pom.xml` or application code are required — the agent works entirely through JVM instrumentation.

### 3.3 — Configure the service in docker-stack.yml

```yaml
springboot-app:
  image: wwongpai/springboot-nginx-demo:latest
  environment:
    # ── Unified Service Tagging ──────────────────────────────────────────
    # These three variables tag every trace, metric, and log from this
    # service so they can be correlated in Datadog.
    DD_SERVICE: "springboot-app"
    DD_ENV:     "demo"
    DD_VERSION: "1.0.0"

    # ── APM configuration ────────────────────────────────────────────────
    DD_TRACE_ENABLED: "true"

    # Tell the agent to merge dd.trace_id and dd.span_id into every
    # SLF4J log statement automatically (no logger code changes needed).
    DD_LOGS_INJECTION: "true"

    # In Docker Swarm, the agent runs as a global service. Use the
    # network alias so this service reaches whichever agent node is local.
    DD_AGENT_HOST: "datadog-agent"
    DD_TRACE_AGENT_PORT: "8126"

  labels:
    # Unified Service Tagging on the container (read by the agent)
    com.datadoghq.tags.service:  "springboot-app"
    com.datadoghq.tags.env:      "demo"
    com.datadoghq.tags.version:  "1.0.0"
    # Autodiscovery: source=java applies the Java log processing pipeline
    com.datadoghq.ad.logs: '[{"source":"java","service":"springboot-app"}]'
```

### 3.4 — How a Spring Boot trace looks in Datadog APM

The dd-java-agent auto-instruments Spring MVC. Each HTTP request becomes a trace with at minimum two spans:

```
springboot-app   servlet.request    GET /work       100 ms
  └── springboot-app  spring.handler  HelloController.work   ~0 ms
```

When called via nginx, the nginx span is the parent:

```
nginx-gateway    nginx.request      GET /java/work  101 ms
  └── springboot-app  servlet.request  GET /work   100 ms
        └── springboot-app  spring.handler  HelloController.work
```

### 3.5 — Verify Java traces are reaching the agent

```bash
docker exec $(docker ps -q -f name=nginx-demo_datadog-agent) agent status \
  | grep -A 5 "java"
```

Expected:

```
From java 17.0.17 (OpenJDK 64-Bit Server VM), client 1.59.0
  Traces received: 20 (25,590 bytes)
  Spans received: 40
```

---

## Section 4 — How to trace PHP (Laravel) in Docker Swarm

### 4.1 — How dd-trace-php works

The Datadog PHP tracer is a **PHP extension** (`.so` file) loaded by the PHP interpreter at startup. It uses the PHP extension mechanism (`datadog-setup.php`) and installs:

- `ddtrace.so` — the core APM extension
- An INI file at `/usr/local/etc/php/conf.d/98-ddtrace.ini` that auto-loads the extension for every PHP process (CLI, Apache, FPM, etc.)

It instruments Laravel automatically: HTTP requests, database queries, cache calls, queue jobs, etc. become spans with no application code changes. When `DD_LOGS_INJECTION=true`, it merges trace context into every Monolog log record.

### 4.2 — Bake dd-trace-php into the Docker image

`laravel-app/Dockerfile`:

```dockerfile
# ── Stage 1: Create a fresh Laravel 11 project ───────────────────────────────
FROM wwongpai/composer:2 AS build
WORKDIR /app
RUN composer create-project --no-interaction --prefer-dist laravel/laravel:^11.0 /app
COPY routes/web.php /app/routes/web.php
RUN cp /app/.env.example /app/.env && php /app/artisan key:generate --force

# ── Stage 2: Runtime image (PHP 8.4 + Apache) ────────────────────────────────
FROM wwongpai/php:8.4-apache
WORKDIR /var/www/html

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app /var/www/html

# Install the Datadog PHP tracer.
# datadog-setup.php is the official installer that:
#   1. Detects the PHP version and build configuration.
#   2. Downloads the correct ddtrace.so for the platform.
#   3. Writes the INI file that auto-loads the extension.
# --enable-appsec=no   → skip Application Security (not needed for this demo)
# --enable-profiling=no → skip continuous profiler (not needed for this demo)
RUN curl -L https://github.com/DataDog/dd-trace-php/releases/latest/download/datadog-setup.php \
       -o /tmp/dd-setup.php \
    && php /tmp/dd-setup.php --php-bin php --enable-appsec=no --enable-profiling=no \
    && rm -f /tmp/dd-setup.php

RUN rm -f /var/www/html/bootstrap/cache/*.php \
    && chown -R www-data:www-data /var/www/html \
    && chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache \
    && a2enmod rewrite

EXPOSE 80

ENV APACHE_DOCUMENT_ROOT=/var/www/html/public

RUN sed -ri \
      -e 's!/var/www/html!/var/www/html/public!g' \
      /etc/apache2/sites-available/*.conf \
    && sed -ri \
      -e 's!/var/www/!/var/www/html/public!g' \
      /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

CMD ["apache2-foreground"]
```

What `datadog-setup.php` installs:

```
/usr/local/lib/php/extensions/.../ddtrace.so      ← core tracing extension
/usr/local/etc/php/conf.d/98-ddtrace.ini          ← auto-loads extension on startup
/opt/datadog/dd-library/1.16.0/                   ← tracer library files
```

No changes to `composer.json` or any application code are needed.

### 4.3 — Configure the service in docker-stack.yml

```yaml
laravel-app:
  image: wwongpai/laravel-nginx-demo:latest
  environment:
    # ── Laravel settings ─────────────────────────────────────────────────
    APP_ENV:     "local"
    APP_DEBUG:   "true"
    # Use stderr so Docker captures logs and the agent can tail them.
    LOG_CHANNEL: "stderr"

    # ── Unified Service Tagging ──────────────────────────────────────────
    DD_SERVICE: "laravel-app"
    DD_ENV:     "demo"
    DD_VERSION: "1.0.0"

    # ── APM configuration ────────────────────────────────────────────────
    DD_TRACE_ENABLED: "true"

    # When enabled, dd-trace-php injects dd.trace_id and dd.span_id
    # into every Monolog log record automatically.
    DD_LOGS_INJECTION: "true"

    DD_AGENT_HOST:       "datadog-agent"
    DD_TRACE_AGENT_PORT: "8126"

  labels:
    com.datadoghq.tags.service:  "laravel-app"
    com.datadoghq.tags.env:      "demo"
    com.datadoghq.tags.version:  "1.0.0"
    # source=php applies the PHP log processing pipeline in Datadog
    com.datadoghq.ad.logs: '[{"source":"php","service":"laravel-app"}]'
```

### 4.4 — How a Laravel trace looks in Datadog APM

The dd-trace-php extension instruments Laravel's HTTP kernel. Each request becomes:

```
laravel-app   laravel.request    GET /work       100 ms
  └── laravel-app  laravel.action  Closure@routes/web.php   ~100 ms
```

When called via nginx, the nginx span is the parent:

```
nginx-gateway    nginx.request      GET /php/work   101 ms
  └── laravel-app  laravel.request  GET /work   100 ms
        └── laravel-app  laravel.action  Closure@routes/web.php
```

### 4.5 — Verify PHP traces are reaching the agent

```bash
docker exec $(docker ps -q -f name=nginx-demo_datadog-agent) agent status \
  | grep -A 5 -i "php\|laravel"
```

In the agent status, PHP traces appear as the largest trace group (many internal Laravel framework spans per request):

```
Traces received: 20 (247,533 bytes)
Spans received: 780
```

---

## Section 5 — Log collection and log–trace correlation

### 5.1 — How the agent collects logs from all containers

The Datadog agent is configured to tail every container's stdout/stderr:

```yaml
# docker-stack.yml — datadog-agent service
environment:
  DD_LOGS_ENABLED: "true"
  DD_LOGS_CONFIG_CONTAINER_COLLECT_ALL: "true"

volumes:
  # Required: agent reads Docker's metadata to discover containers
  - /var/run/docker.sock:/var/run/docker.sock:ro
  # Required: agent tails these files directly for log collection
  - /var/lib/docker/containers:/var/lib/docker/containers:ro
```

Docker writes every container's stdout and stderr to:

```
/var/lib/docker/containers/<container-id>/<container-id>-json.log
```

The agent tails these files. For each container, it reads the `com.datadoghq.ad.logs` Docker label to know which Datadog log pipeline to apply.

### 5.2 — How to tell the agent which log pipeline to use

Each service in `docker-stack.yml` has this label:

```yaml
# nginx — use the built-in nginx access log parsing pipeline
nginx-gateway:
  labels:
    com.datadoghq.ad.logs: '[{"source":"nginx","service":"nginx-gateway"}]'

# Spring Boot — use the built-in Java log parsing pipeline
springboot-app:
  labels:
    com.datadoghq.ad.logs: '[{"source":"java","service":"springboot-app"}]'

# Laravel — use the built-in PHP log parsing pipeline
laravel-app:
  labels:
    com.datadoghq.ad.logs: '[{"source":"php","service":"laravel-app"}]'
```

`source` maps to a Datadog **integration log pipeline** that applies grok parsers, remappers, and enrichment automatically. `service` links the log to the matching service in APM.

### 5.3 — Log format for Spring Boot (Java)

Log–trace correlation requires that the trace and span IDs appear in the log output in the standard Datadog field names (`dd.trace_id` and `dd.span_id`).

When `DD_LOGS_INJECTION=true`, dd-java-agent automatically inserts those values into **SLF4J MDC** (Mapped Diagnostic Context). MDC values are thread-local — they are attached to the current request's thread, so every log statement inside a request handler automatically includes the trace context.

To emit the MDC values in JSON, configure Logback. `springboot-app/src/main/resources/logback-spring.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <appender name="STDOUT" class="ch.qos.logback.core.ConsoleAppender">
    <encoder>
      <!--
        %X{key} reads a value from SLF4J MDC.
        dd-java-agent populates these MDC keys automatically:
          dd.trace_id  — the active trace ID
          dd.span_id   — the active span ID
          dd.service   — from DD_SERVICE env var
          dd.env       — from DD_ENV env var
          dd.version   — from DD_VERSION env var
        The :- syntax provides a fallback if the key is not set
        (e.g. for log statements outside a request context).
      -->
      <pattern>{"timestamp":"%d{yyyy-MM-dd'T'HH:mm:ss.SSSXXX}","level":"%level","service":"%X{dd.service:-springboot-nginx-demo}","env":"%X{dd.env:-}","version":"%X{dd.version:-}","dd.trace_id":"%X{dd.trace_id:-}","dd.span_id":"%X{dd.span_id:-}","logger":"%logger{36}","message":"%msg"}%n</pattern>
    </encoder>
  </appender>

  <root level="INFO">
    <appender-ref ref="STDOUT"/>
  </root>
</configuration>
```

The application code uses standard SLF4J — no Datadog imports needed:

```java
// HelloController.java
private static final Logger logger = LoggerFactory.getLogger(HelloController.class);

@GetMapping("/work")
public String work() throws InterruptedException {
    // dd-java-agent has already injected dd.trace_id into MDC for this thread.
    // This log statement will automatically include the trace ID.
    logger.info("Spring Boot work endpoint called");
    Thread.sleep(100);
    return "springboot-nginx-demo work done";
}
```

A Spring Boot log line with correlation looks like:

```json
{
  "timestamp": "2026-02-18T07:17:23.451+00:00",
  "level": "INFO",
  "service": "springboot-app",
  "env": "demo",
  "version": "1.0.0",
  "dd.trace_id": "699567830000000052313a8c56cef6ec",
  "dd.span_id": "52313a8c56cef6ec",
  "logger": "c.e.demo.HelloController",
  "message": "Spring Boot work endpoint called"
}
```

### 5.4 — Log format for Laravel (PHP)

When `DD_LOGS_INJECTION=true`, dd-trace-php hooks into **Monolog** (Laravel's logger) and appends the trace context to every log record's context array automatically.

No changes to `logging.php` or any application code are needed. The `LOG_CHANNEL=stderr` environment variable routes log output to stderr, which Docker captures and the agent tails.

The application code uses Laravel's standard `Log` facade:

```php
// routes/web.php
Route::get('/work', function () {
    // dd-trace-php has injected the trace context into Monolog automatically.
    Log::info('laravel-nginx-demo work hit');
    usleep(100000);
    return 'laravel-nginx-demo work done';
});
```

A Laravel log line with correlation looks like:

```
[2026-02-18 07:17:23] local.INFO: laravel-nginx-demo work hit
  {"dd.trace_id":"699567830000000052313a8c56cef6ec","dd.span_id":"52313a8c56cef6ec","dd.service":"laravel-app","dd.version":"1.0.0","dd.env":"demo"}
```

### 5.5 — Step-by-step: how log–trace correlation works end to end

Here is the full flow for a single `GET /java/work` request:

```
Step 1: Request arrives at nginx-gateway
        → ngx_http_datadog_module creates span A (trace_id=T, span_id=A)
        → Injects headers into proxy_pass: traceparent, x-datadog-trace-id=T

Step 2: nginx writes access log
        → $datadog_trace_id=T, $datadog_span_id=A embedded in JSON
        → Log line: { "dd.trace_id": "T", "dd.span_id": "A", "uri": "/java/work" }

Step 3: Request hits springboot-app
        → dd-java-agent reads traceparent header, extracts trace_id=T
        → Creates child span B (trace_id=T, span_id=B, parent_id=A)
        → Injects into SLF4J MDC: dd.trace_id=T, dd.span_id=B

Step 4: HelloController.work() calls logger.info(...)
        → Logback reads MDC, writes JSON log
        → Log line: { "dd.trace_id": "T", "dd.span_id": "B", "message": "work endpoint called" }

Step 5: Datadog agent collects both log lines and both spans
        → Sends spans to trace.agent.datadoghq.com
        → Sends logs to agent-http-intake.logs.datadoghq.com

Step 6: In Datadog Log Explorer
        → Find the nginx log line or Spring Boot log line
        → Click "View Trace" → jumps to the flame graph for trace T
        → Both the nginx span (A) and Spring Boot span (B) are visible
        → Click any span → "Logs" tab shows the correlated log lines
```

### 5.6 — Verify logs are being shipped

```bash
docker exec $(docker ps -q -f name=nginx-demo_datadog-agent) agent status \
  | grep -A 6 "Logs Agent"
```

Expected:

```
Logs Agent
==========
  Reliable: Sending compressed logs in HTTPS to agent-http-intake.logs.datadoghq.com on port 443
  LogsProcessed: 11412
  LogsSent: 11515
```

### 5.7 — Where to look in Datadog

| Goal | Where to go |
|---|---|
| See all logs from this stack | Log Explorer → filter `env:demo` |
| See nginx access logs with trace IDs | Log Explorer → filter `service:nginx-gateway` |
| See Spring Boot logs with trace IDs | Log Explorer → filter `service:springboot-app` |
| See Laravel logs with trace IDs | Log Explorer → filter `service:laravel-app` |
| Jump from a log line to its trace | Click any log → "View Trace" button |
| Jump from a trace span to its logs | APM → open any trace → click "Logs" tab on a span |
| nginx metrics | [nginx Overview Dashboard](https://app.datadoghq.com/dash/integration/21/nginx---overview) |
| Service map showing all 3 services | [APM → Service Map](https://app.datadoghq.com/apm/map?env=demo) → filter `env:demo` |

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

# Single requests
curl http://$HOST/java/
curl http://$HOST/java/work
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

# Run the nginx metrics check manually and verify
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
| `GET /nginx_status` | nginx | stub_status — internal, scraped by agent every 15 s (tracing disabled) |

---

## Security notes

- `DD_API_KEY` is passed via environment variable substitution (`${DD_API_KEY}`) in `docker-stack.yml` — it is **never hardcoded** in any committed file.
- The `.env` file (where you store the real key locally) is in `.gitignore`.
- Docker images contain **no secrets**. The API key is injected at container runtime by Docker Swarm.
