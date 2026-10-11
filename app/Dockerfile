# syntax=docker/dockerfile:1

# build stage: compile a fat jar with a cached dependency layer
FROM gradle:9.8.1-jdk21-alpine AS build
WORKDIR /src
COPY settings.gradle.kts build.gradle.kts gradle.properties ./
RUN --mount=type=cache,target=/home/gradle/.gradle gradle dependencies --no-daemon -q > /dev/null
COPY src ./src
RUN --mount=type=cache,target=/home/gradle/.gradle gradle buildFatJar --no-daemon -q

# runtime stage: jre only, non-root
FROM eclipse-temurin:21-jre-alpine
# numeric uid so the pod securityContext can verify runAsNonRoot
RUN addgroup -S -g 10001 app && adduser -S -u 10001 -G app app
WORKDIR /app
COPY --from=build /src/build/libs/app.jar /app/app.jar
USER 10001
EXPOSE 8080
ENV JAVA_OPTS="-Xms64m -Xmx320m -XX:+UseSerialGC"
# exec keeps the jvm as pid 1 so it receives SIGTERM
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
