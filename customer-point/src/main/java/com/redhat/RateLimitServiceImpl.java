package com.redhat;

import java.time.Duration;
import java.util.UUID;

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

    // ConfigMap / application.properties から取得
    @ConfigProperty(name = "ratelimit.window.ms")
    long windowMs;

    @ConfigProperty(name = "ratelimit.max.requests")
    int maxRequests;

    /**
     * Sliding Window Rate Limit (Redis ZSET)
     */
    private static final String LUA_SCRIPT = """
        local key = KEYS[1]

        local now = tonumber(ARGV[1])
        local window = tonumber(ARGV[2])
        local limit = tonumber(ARGV[3])
        local member = ARGV[4]

        -- 古いデータ削除
        redis.call("ZREMRANGEBYSCORE", key, 0, now - window)
        redis.call("ZREMRANGEBYRANK", key, 0, -1) 

        -- 現在の件数
        local current = redis.call("ZCARD", key)

        -- 上限チェック
        if current >= limit then
            return 0
        end

        -- 登録
        redis.call("ZADD", key, now, member)

        -- TTL
        redis.call("EXPIRE", key, math.ceil(window / 1000))

        return 1
        """;

    @Override
    public void shouldRateLimit(
            RateLimitRequest request,
            StreamObserver<RateLimitResponse> responseObserver) {

        try {

            // ★ descriptorベースのキー生成（重要）
            String key = buildKey(request);

            long now = System.currentTimeMillis();
            String member = now + "-" + UUID.randomUUID();

            Integer allowed =
                    redis.send(
                            Request.cmd(Command.EVAL)
                                    .arg(LUA_SCRIPT)
                                    .arg("1")
                                    .arg(key)
                                    .arg(String.valueOf(now))
                                    .arg(String.valueOf(windowMs))
                                    .arg(String.valueOf(maxRequests))
                                    .arg(member))
                    .await()
                    .atMost(Duration.ofSeconds(2))
                    .toInteger();

            RateLimitResponse.Code code =
                    allowed == 1
                            ? RateLimitResponse.Code.OK
                            : RateLimitResponse.Code.OVER_LIMIT;

            responseObserver.onNext(
                    RateLimitResponse.newBuilder()
                            .setOverallCode(code)
                            .build()
            );
            responseObserver.onCompleted();

        } catch (Exception e) {

            e.printStackTrace();

            // fail-open（障害時は通す）
            responseObserver.onNext(
                    RateLimitResponse.newBuilder()
                            .setOverallCode(RateLimitResponse.Code.OK)
                            .build()
            );
            responseObserver.onCompleted();
        }
    }

    /**
     * Envoy descriptor を使ったキー生成
     */
    private String buildKey(RateLimitRequest request) {

        if (request.getDescriptorsList() == null
                || request.getDescriptorsList().isEmpty()) {
            return "global";
        }

        StringBuilder sb = new StringBuilder();

        request.getDescriptorsList().forEach(d -> {
            d.getEntriesList().forEach(e -> {
                sb.append(e.getKey())
                  .append(":")
                  .append(e.getValue())
                  .append("|");
            });
        });

        return sb.length() == 0
                ? "global"
                : sb.toString();
    }
}