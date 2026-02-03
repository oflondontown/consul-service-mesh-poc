package com.example.consulmesh.webservice.ws;

import com.example.consulmesh.webservice.config.ServiceMetadata;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import java.time.Instant;

public class EchoWebSocketHandler extends TextWebSocketHandler {
    private final ServiceMetadata metadata;

    public EchoWebSocketHandler(ServiceMetadata metadata) {
        this.metadata = metadata;
    }

    @Override
    protected void handleTextMessage(WebSocketSession session, TextMessage message) throws Exception {
        String payload = "echo@" + Instant.now() + " " + metadata.serviceId() + ": " + message.getPayload();
        session.sendMessage(new TextMessage(payload));
    }
}
