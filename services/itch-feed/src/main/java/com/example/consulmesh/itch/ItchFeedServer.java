package com.example.consulmesh.itch;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

public final class ItchFeedServer {
    private static final ConcurrentHashMap<Socket, ClientState> CLIENTS = new ConcurrentHashMap<>();

    private static final class ClientState {
        private final Socket socket;
        private volatile boolean loggedIn;
        private volatile boolean subscribed;

        private ClientState(Socket socket) {
            this.socket = socket;
        }
    }

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(getenvOrDefault("PORT", "9000"));
        String serviceId = getenvOrDefault("SERVICE_ID", "itch-feed-unknown");
        String datacenter = getenvOrDefault("DATACENTER", "unknown");

        ServerSocket serverSocket = new ServerSocket();
        serverSocket.bind(new InetSocketAddress("0.0.0.0", port));

        var clientExecutor = Executors.newCachedThreadPool();
        ScheduledExecutorService scheduler = Executors.newScheduledThreadPool(1);
        AtomicLong seq = new AtomicLong(0);
        scheduler.scheduleAtFixedRate(() -> broadcast(serviceId, datacenter, seq.incrementAndGet()), 0, 1, TimeUnit.SECONDS);

        System.out.println("itch-feed started: tcp://0.0.0.0:" + port + " (id=" + serviceId + ", dc=" + datacenter + ")");

        while (true) {
            Socket socket = serverSocket.accept();
            socket.setTcpNoDelay(true);
            ClientState state = new ClientState(socket);
            CLIENTS.put(socket, state);
            System.out.println("itch-feed client connected: " + socket.getRemoteSocketAddress());

            clientExecutor.submit(() -> handleClient(state));
        }
    }

    private static void broadcast(String serviceId, String datacenter, long seq) {
        String line = "ITCH|" + Instant.now() + "|" + datacenter + "|" + serviceId + "|seq=" + seq + "\n";
        for (ClientState state : CLIENTS.values()) {
            if (!state.subscribed) {
                continue;
            }
            try {
                BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(state.socket.getOutputStream(), StandardCharsets.UTF_8));
                writer.write(line);
                writer.flush();
            } catch (Exception e) {
                CLIENTS.remove(state.socket);
                try {
                    state.socket.close();
                } catch (Exception ignored) {
                }
            }
        }
    }

    private static void handleClient(ClientState state) {
        Socket socket = state.socket;
        try {
            BufferedReader reader = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
            BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8));

            String line;
            while ((line = reader.readLine()) != null) {
                String trimmed = line.trim();
                if (trimmed.isEmpty()) {
                    continue;
                }

                if (trimmed.startsWith("LOGIN")) {
                    state.loggedIn = true;
                    writer.write("LOGIN-OK\n");
                    writer.flush();
                    continue;
                }

                if (trimmed.startsWith("SUBSCRIBE")) {
                    state.subscribed = true;
                    writer.write("SUBSCRIBE-OK\n");
                    writer.flush();
                    continue;
                }

                writer.write("IGNORED\n");
                writer.flush();
            }
        } catch (Exception ignored) {
        } finally {
            CLIENTS.remove(socket);
            try {
                socket.close();
            } catch (Exception ignored) {
            }
            System.out.println("itch-feed client disconnected: " + socket.getRemoteSocketAddress());
        }
    }

    private static String getenvOrDefault(String key, String defaultValue) {
        String value = System.getenv(key);
        return (value == null || value.isBlank()) ? defaultValue : value;
    }
}
