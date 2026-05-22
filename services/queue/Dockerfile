FROM eclipse-temurin:21-jdk AS builder

RUN apt-get update && apt-get install -y curl && \
    curl -fL "https://github.com/sbt/sbt/releases/download/v1.10.6/sbt-1.10.6.tgz" | tar xz -C /usr/local && \
    ln -s /usr/local/sbt/bin/sbt /usr/local/bin/sbt && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY build.sbt ./
COPY project/ ./project/
RUN sbt update

COPY src/ ./src/
RUN sbt assembly

FROM eclipse-temurin:21-jre-alpine

WORKDIR /app
COPY --from=builder /build/target/scala-2.13/queue.jar ./queue.jar

ENV PORT=5003
EXPOSE 5003
CMD ["java", "-jar", "queue.jar"]
