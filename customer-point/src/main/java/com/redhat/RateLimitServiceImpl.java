package com.redhat;

import java.util.Map;

import jakarta.inject.Inject;
import jakarta.inject.Singleton;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import io.grpc.stub.StreamObserver;
import io.quarkus.grpc.GrpcService;
import io.vertx.mutiny.redis.client.Command;
import io.vertx.mutiny.redis.client.Redis;
import io.vertx.mutiny.redis.client.Request;

import envoy.service.ratelimit.v3.RateLimitRequest;
import envoy.service.ratelimit.v3.RateLimitResponse;
import envoy.service.ratelimit.v3.RateLimitServiceGrpc;

@GrpcService
@Singleton
public class RateLimitServiceImpl
        extends RateLimitServiceGrpc.RateLimitServiceImplBase {

    @Inject
    Redis redis;

    @ConfigProperty(name = "ratelimit.window-seconds", defaultValue = "60")
    long windowSeconds;
    @ConfigProperty(name = "ratelimit.gold-limit", defaultValue = "30")
    long goldLimit;
    @ConfigProperty(name = "ratelimit.silver-limit", defaultValue = "15")
    long silverLimit;
    @ConfigProperty(name = "ratelimit.free-limit", defaultValue = "5")
    long freeLimit;

    @Override
    public void shouldRateLimit(
            RateLimitRequest request,
            StreamObserver<RateLimitResponse> responseObserver) {

        String clientKey = buildKey(request);
        String tenant = extractTenant(clientKey);
        long limit = resolveLimit(tenant);
        String redisKey = "rl:" + clientKey;

        redis.send(
                Request.cmd(Command.INCR)
                        .arg(redisKey))
        .subscribe()
        .with(

            response -> {

                long count =
                        Long.parseLong(response.toString());

                // 初回のみTTL設定
                if (count == 1) {

                    redis.send(
                            Request.cmd(Command.EXPIRE)
                                    .arg(redisKey)
                                    .arg(String.valueOf(
                                            windowSeconds)))
                    .subscribe()
                    .with(
                            x -> {},
                            Throwable::printStackTrace
                    );
                }

                boolean allowed = count <= limit;

                System.out.println(
                        "RateLimit"
                        + " tenant=" + tenant
                        + " key=" + redisKey
                        + " count=" + count
                        + " limit=" + limit
                        + " allowed=" + allowed
                );

                responseObserver.onNext(
                        RateLimitResponse.newBuilder()
                                .setOverallCode(
                                        allowed
                                                ? RateLimitResponse.Code.OK
                                                : RateLimitResponse.Code.OVER_LIMIT)
                                .build()
                );

                responseObserver.onCompleted();
            },

            failure -> {

                failure.printStackTrace();

                // fail-open
                responseObserver.onNext(
                        RateLimitResponse.newBuilder()
                                .setOverallCode(
                                        RateLimitResponse.Code.OK)
                                .build()
                );

                responseObserver.onCompleted();
            }
        );
    }

    /**
     * tenant別limit
     */
    private long resolveLimit(String tenant) {

        return switch (tenant) {
            case "gold" -> goldLimit;
            case "silver" -> silverLimit;
            case "free" -> freeLimit;
            default -> freeLimit;
        };
    }

    /**
     * tenant抽出
     */
    private String extractTenant(String key) {

        for (String token : key.split("\\|")) {

            if (token.startsWith("tenant:")) {
                return token.substring("tenant:".length());
            }
        }

        return "free";
    }

    /**
     * Envoy descriptor -> Redis key
     */
    private String buildKey(RateLimitRequest request) {

        if (request.getDescriptorsList().isEmpty()) {
            return "tenant:free";
        }

        StringBuilder sb = new StringBuilder();

        request.getDescriptorsList().forEach(d ->
            d.getEntriesList().forEach(e ->
                sb.append(e.getKey())
                  .append(":")
                  .append(e.getValue())
                  .append("|")
            )
        );

        // 最後の "|" 削除
        if (sb.length() > 0) {
            sb.setLength(sb.length() - 1);
        }

        return sb.toString();
    }
}