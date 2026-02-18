# Multi-stage build: Maven compile → slim JRE runtime with dd-java-agent pre-baked.

# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM wwongpai/maven:3.9-eclipse-temurin-17 AS build
WORKDIR /workspace
COPY pom.xml .
COPY src ./src
RUN mvn -q -DskipTests package

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM wwongpai/eclipse-temurin:17-jre
WORKDIR /app

# Download the latest Datadog Java APM tracer
ADD https://dtdg.co/latest-java-tracer /datadog/dd-java-agent.jar

COPY --from=build /workspace/target/springboot-nginx-demo-1.0.0.jar app.jar

EXPOSE 8080

# Attach the Datadog Java agent at JVM startup
ENV JAVA_TOOL_OPTIONS="-javaagent:/datadog/dd-java-agent.jar"

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
