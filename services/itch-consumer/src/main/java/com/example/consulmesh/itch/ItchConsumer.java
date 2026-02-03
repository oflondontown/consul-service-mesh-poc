package com.example.consulmesh.itch;

import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.BufferedWriter;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.concurrent.Executors;

public final class ItchConsumer {
    public static void main(String[] args) throws Exception {
        int httpPort = Integer.parseInt(getenvOrDefault("PORT", "9100"));
        String itchHost = getenvOrDefault("ITCH_HOST", "localhost");
        int itchPort = Integer.parseInt(getenvOrDefault("ITCH_PORT", "19000"));
        String username = getenvOrDefault("ITCH_USERNAME", "demo");
        String password = getenvOrDefault("ITCH_PASSWORD", "demo");
        String subscription = getenvOrDefault("ITCH_SUBSCRIPTION", "all");
        String serviceId = getenvOrDefault("SERVICE_ID", "itch-consumer-unknown");
        String datacenter = getenvOrDefault("DATACENTER", "unknown");

        startHealthServer(httpPort, serviceId, datacenter, itchHost, itchPort);

        System.out.println("itch-consumer started: http://0.0.0.0:" + httpPort + " (id=" + serviceId + ", dc=" + datacenter + ")");
        consumeLoop(itchHost, itchPort, serviceId, username, password, subscription);
    }

    private static void consumeLoop(String host, int port, String serviceId, String username, String password, String subscription)
            throws InterruptedException {
        Duration backoff = Duration.ofSeconds(1);
        while (true) {
            try (Socket socket = new Socket()) {
                socket.connect(new InetSocketAddress(host, port), 2000);
                socket.setTcpNoDelay(true);
                System.out.println("itch-consumer connected to " + host + ":" + port);

                BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8));
                writer.write("LOGIN|user=" + username + "|pass=" + password + "\n");
                writer.write("SUBSCRIBE|channels=" + subscription + "\n");
                writer.flush();

                BufferedReader reader = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                String line;
                while ((line = reader.readLine()) != null) {
                    System.out.println("itch-consumer[" + serviceId + "] " + line);
                }
            } catch (Exception e) {
                System.out.println("itch-consumer connection failed: " + e.getMessage());
            }

            Thread.sleep(backoff.toMillis());
            if (backoff.compareTo(Duration.ofSeconds(10)) < 0) {
                backoff = backoff.multipliedBy(2);
            }
        }
    }

    private static void startHealthServer(int port, String serviceId, String datacenter, String itchHost, int itchPort) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.setExecutor(Executors.newFixedThreadPool(2));
        server.createContext("/health", exchange -> respondJson(exchange, 200, json(Map.of(
                "status", "UP",
                "serviceId", serviceId,
                "datacenter", datacenter,
                "itchUpstream", itchHost + ":" + itchPort,
                "time", Instant.now().toString()
        ))));
        server.start();
    }

    private static void respondJson(HttpExchange exchange, int statusCode, String json) throws IOException {
        Headers headers = exchange.getResponseHeaders();
        headers.set("Content-Type", "application/json; charset=utf-8");
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(statusCode, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        } finally {
            exchange.close();
        }
    }

    private static String getenvOrDefault(String key, String defaultValue) {
        String value = System.getenv(key);
        return (value == null || value.isBlank()) ? defaultValue : value;
    }

    private static String json(Map<String, Object> map) {
        StringBuilder sb = new StringBuilder();
        sb.append('{');
        boolean first = true;
        for (Map.Entry<String, Object> entry : map.entrySet()) {
            if (!first) {
                sb.append(',');
            }
            first = false;
            sb.append('"').append(escape(entry.getKey())).append('"').append(':');
            sb.append(valueToJson(entry.getValue()));
        }
        sb.append('}');
        return sb.toString();
    }

    private static String valueToJson(Object value) {
        if (value == null) {
            return "null";
        }
        if (value instanceof Boolean || value instanceof Number) {
            return value.toString();
        }
        return "\"" + escape(String.valueOf(value)) + "\"";
    }

    private static String escape(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
