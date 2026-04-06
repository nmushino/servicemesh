package com.redhat.cobol;

import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.reactive.messaging.Incoming;
import org.eclipse.microprofile.reactive.messaging.Outgoing;

import java.io.*;

@ApplicationScoped
public class CobolKafkaProcessor {

    @Incoming("input-topic")
    @Outgoing("output-topic")
    public String process(String amount) throws Exception {

        // COBOL プロセス呼び出し
        ProcessBuilder pb = new ProcessBuilder("/app/customer-point");
        Process process = pb.start();

        try (OutputStream os = process.getOutputStream()) {
            os.write((amount + "\n").getBytes());
            os.flush();
        }

        String result;
        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(process.getInputStream()))) {
            result = reader.readLine();
        }

        process.waitFor();
        return result;
    }
}