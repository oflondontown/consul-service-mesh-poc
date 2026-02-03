FROM docker.io/gradle:8.7-jdk17 AS build
WORKDIR /workspace
COPY . .
RUN gradle :services:refdata:jar --no-daemon

FROM docker.io/eclipse-temurin:17-jdk
WORKDIR /app
COPY --from=build /workspace/services/refdata/build/libs/refdata.jar /app/app.jar
EXPOSE 8082
ENTRYPOINT ["java","-jar","/app/app.jar"]
