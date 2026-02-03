package com.example.consulmesh.refdata;

import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

public final class RefDataServer {
    private static final AtomicBoolean ACTIVE = new AtomicBoolean(true);

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(getenvOrDefault("PORT", "8082"));
        String serviceId = getenvOrDefault("SERVICE_ID", "refdata-unknown");
        String datacenter = getenvOrDefault("DATACENTER", "unknown");
        String instanceRole = getenvOrDefault("INSTANCE_ROLE", "unknown");

        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.setExecutor(Executors.newFixedThreadPool(8));

        server.createContext("/health", exchange -> {
            if (!ACTIVE.get()) {
                respondJson(exchange, 503, json(Map.of(
                        "status", "DOWN",
                        "serviceId", serviceId,
                        "datacenter", datacenter,
                        "instanceRole", instanceRole,
                        "time", Instant.now().toString()
                )));
                return;
            }
            respondJson(exchange, 200, json(Map.of(
                    "status", "UP",
                    "serviceId", serviceId,
                    "datacenter", datacenter,
                    "instanceRole", instanceRole,
                    "time", Instant.now().toString()
            )));
        });

        server.createContext("/api/refdata", exchange -> {
            if (!ACTIVE.get()) {
                respondJson(exchange, 503, json(Map.of(
                        "error", "refdata inactive",
                        "serviceId", serviceId,
                        "time", Instant.now().toString()
                )));
                return;
            }
            String path = exchange.getRequestURI().getPath(); // /api/refdata/<key>
            String[] parts = path.split("/", 4);
            String key = (parts.length >= 4) ? parts[3] : "";
            if (key.isBlank()) {
                respondJson(exchange, 400, json(Map.of("error", "missing key")));
                return;
            }
            String decodedKey = URLDecoder.decode(key, StandardCharsets.UTF_8);
            String value = "value-for(" + decodedKey + ")";

            respondJson(exchange, 200, json(Map.of(
                    "key", decodedKey,
                    "value", value,
                    "serviceId", serviceId,
                    "datacenter", datacenter,
                    "instanceRole", instanceRole,
                    "time", Instant.now().toString()
            )));
        });

        server.createContext("/admin/active", exchange -> {
            Map<String, String> query = parseQuery(exchange.getRequestURI());
            String value = query.get("value");
            if (value == null) {
                respondJson(exchange, 400, json(Map.of("error", "missing value=true|false")));
                return;
            }
            ACTIVE.set(Boolean.parseBoolean(value));
            respondJson(exchange, 200, json(Map.of(
                    "active", ACTIVE.get(),
                    "serviceId", serviceId,
                    "datacenter", datacenter,
                    "instanceRole", instanceRole,
                    "time", Instant.now().toString()
            )));
        });

        System.out.println("refdata started: http://0.0.0.0:" + port + " (id=" + serviceId + ", dc=" + datacenter + ")");
        server.start();
    }

    private static Map<String, String> parseQuery(URI uri) {
        Map<String, String> result = new HashMap<>();
        String raw = uri.getRawQuery();
        if (raw == null || raw.isBlank()) {
            return result;
        }
        for (String pair : raw.split("&")) {
            int idx = pair.indexOf('=');
            String key = idx >= 0 ? pair.substring(0, idx) : pair;
            String value = idx >= 0 ? pair.substring(idx + 1) : "";
            result.put(
                    URLDecoder.decode(key, StandardCharsets.UTF_8),
                    URLDecoder.decode(value, StandardCharsets.UTF_8)
            );
        }
        return result;
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
