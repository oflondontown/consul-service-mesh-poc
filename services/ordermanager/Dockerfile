FROM docker.io/gradle:8.7-jdk17 AS build
WORKDIR /workspace
COPY . .
RUN gradle :services:ordermanager:bootJar --no-daemon

FROM docker.io/eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /workspace/services/ordermanager/build/libs/ordermanager.jar /app/app.jar
EXPOSE 8081
ENTRYPOINT ["java","-jar","/app/app.jar"]
