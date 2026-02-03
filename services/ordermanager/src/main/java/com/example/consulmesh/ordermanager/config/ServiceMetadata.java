package com.example.consulmesh.ordermanager.config;

import java.util.Map;

public final class ServiceMetadata {
    private final String serviceName;
    private final String serviceId;
    private final String datacenter;
    private final String instanceRole;

    public ServiceMetadata(String serviceName, String serviceId, String datacenter, String instanceRole) {
        this.serviceName = serviceName;
        this.serviceId = serviceId;
        this.datacenter = datacenter;
        this.instanceRole = instanceRole;
    }

    public static ServiceMetadata fromEnv() {
        return new ServiceMetadata(
                getenvOrDefault("SERVICE_NAME", "ordermanager"),
                getenvOrDefault("SERVICE_ID", "ordermanager-unknown"),
                getenvOrDefault("DATACENTER", "unknown"),
                getenvOrDefault("INSTANCE_ROLE", "unknown")
        );
    }

    private static String getenvOrDefault(String key, String defaultValue) {
        String value = System.getenv(key);
        return (value == null || value.isBlank()) ? defaultValue : value;
    }

    public Map<String, Object> asMap() {
        return Map.of(
                "service", serviceName,
                "serviceId", serviceId,
                "datacenter", datacenter,
                "instanceRole", instanceRole
        );
    }
}
