package com.example.consulmesh.webservice.http;

import com.example.consulmesh.webservice.config.ServiceMetadata;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

@RestController
public class WebController {
    private final ServiceMetadata metadata;
    private final RestClient refData;
    private final RestClient orderManager;

    public WebController(
            ServiceMetadata metadata,
            @Qualifier("refDataRestClient") RestClient refDataRestClient,
            @Qualifier("orderManagerRestClient") RestClient orderManagerRestClient
    ) {
        this.metadata = metadata;
        this.refData = refDataRestClient;
        this.orderManager = orderManagerRestClient;
    }

    @GetMapping(value = "/health", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> health() {
        Map<String, Object> body = new LinkedHashMap<>(metadata.asMap());
        body.put("status", "UP");
        body.put("time", Instant.now().toString());
        return body;
    }

    @GetMapping(value = "/api/refdata/{key}", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> refData(@PathVariable("key") String key) {
        Object upstreamResponse = refData.get()
                .uri("/api/refdata/{key}", key)
                .retrieve()
                .body(Object.class);

        Map<String, Object> body = new LinkedHashMap<>(metadata.asMap());
        body.put("time", Instant.now().toString());
        body.put("requestedKey", key);
        body.put("refdata", upstreamResponse);
        return body;
    }

    @GetMapping(value = "/api/orders/{orderId}", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> order(@PathVariable("orderId") String orderId) {
        Object upstreamResponse = orderManager.get()
                .uri("/api/orders/{orderId}", orderId)
                .retrieve()
                .body(Object.class);

        Map<String, Object> body = new LinkedHashMap<>(metadata.asMap());
        body.put("time", Instant.now().toString());
        body.put("orderId", orderId);
        body.put("ordermanager", upstreamResponse);
        return body;
    }
}
