package com.example.consulmesh.webservice.ws;

import com.example.consulmesh.webservice.config.ServiceMetadata;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;

@Configuration
@EnableWebSocket
public class EchoWebSocketConfig implements WebSocketConfigurer {
    private final ServiceMetadata metadata;

    public EchoWebSocketConfig(ServiceMetadata metadata) {
        this.metadata = metadata;
    }

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(new EchoWebSocketHandler(metadata), "/ws/echo")
                .setAllowedOrigins("*");
    }
}
