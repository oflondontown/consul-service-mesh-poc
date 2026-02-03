FROM docker.io/gradle:8.7-jdk17 AS build
WORKDIR /workspace
COPY . .
RUN gradle :services:itch-feed:jar --no-daemon

FROM docker.io/eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /workspace/services/itch-feed/build/libs/itch-feed.jar /app/app.jar
EXPOSE 9000
ENTRYPOINT ["java","-jar","/app/app.jar"]
