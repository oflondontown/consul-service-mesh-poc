FROM docker.io/gradle:8.7-jdk17 AS build
WORKDIR /workspace
COPY . .
RUN gradle :services:itch-consumer:jar --no-daemon

FROM docker.io/eclipse-temurin:17-jdk
WORKDIR /app
COPY --from=build /workspace/services/itch-consumer/build/libs/itch-consumer.jar /app/app.jar
EXPOSE 9100
ENTRYPOINT ["java","-jar","/app/app.jar"]
