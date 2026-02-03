package com.example.consulmesh.webservice.config;

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
                getenvOrDefault("SERVICE_NAME", "webservice"),
                getenvOrDefault("SERVICE_ID", "webservice-unknown"),
                getenvOrDefault("DATACENTER", "unknown"),
                getenvOrDefault("INSTANCE_ROLE", "unknown")
        );
    }

    private static String getenvOrDefault(String key, String defaultValue) {
        String value = System.getenv(key);
        return (value == null || value.isBlank()) ? defaultValue : value;
    }

    public String serviceName() {
        return serviceName;
    }

    public String serviceId() {
        return serviceId;
    }

    public String datacenter() {
        return datacenter;
    }

    public String instanceRole() {
        return instanceRole;
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
