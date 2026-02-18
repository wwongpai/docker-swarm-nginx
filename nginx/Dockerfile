# Custom nginx image with the Datadog nginx tracing module baked in.
# Supports linux/amd64 and linux/arm64 via TARGETARCH (set automatically by docker buildx).

FROM nginx:1.28.2

# TARGETARCH is set automatically by docker buildx (arm64 or amd64).
# Do NOT provide a default — letting BuildKit set it correctly.
ARG TARGETARCH

ENV DD_NGINX_MODULE_VERSION=v1.12.0
ENV NGINX_VERSION=1.28.2

# Install the Datadog nginx module (.so) for the matching nginx version and arch
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
