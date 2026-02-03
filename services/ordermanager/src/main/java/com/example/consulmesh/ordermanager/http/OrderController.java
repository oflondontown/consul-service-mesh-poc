package com.example.consulmesh.ordermanager.http;

import com.example.consulmesh.ordermanager.config.ServiceMetadata;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

@RestController
public class OrderController {
    private final ServiceMetadata metadata;
    private final RestClient refData;

    public OrderController(ServiceMetadata metadata, RestClient refDataRestClient) {
        this.metadata = metadata;
        this.refData = refDataRestClient;
    }

    @GetMapping(value = "/health", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> health() {
        Map<String, Object> body = new LinkedHashMap<>(metadata.asMap());
        body.put("status", "UP");
        body.put("time", Instant.now().toString());
        return body;
    }

    @GetMapping(value = "/api/orders/{orderId}", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> order(@PathVariable("orderId") String orderId) {
        String refKey = "symbol:" + orderId;
        Object ref = refData.get()
                .uri("/api/refdata/{key}", refKey)
                .retrieve()
                .body(Object.class);

        Map<String, Object> body = new LinkedHashMap<>(metadata.asMap());
        body.put("time", Instant.now().toString());
        body.put("orderId", orderId);
        body.put("refdata", ref);
        body.put("result", Map.of("status", "ACCEPTED"));
        return body;
    }
}
