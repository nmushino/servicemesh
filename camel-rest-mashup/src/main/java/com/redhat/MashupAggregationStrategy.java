package com.redhat;

import java.util.HashMap;
import java.util.Map;

import org.apache.camel.AggregationStrategy;
import org.apache.camel.Exchange;

public class MashupAggregationStrategy
        implements AggregationStrategy {

    @Override
    public Exchange aggregate(
            Exchange oldExchange,
            Exchange newExchange) {

        if (oldExchange == null) {
            Map<String, Object> map = new HashMap<>();
            String type =
                    newExchange.getMessage()
                            .getHeader("type", String.class);
            map.put(
                    type,
                    newExchange.getMessage()
                            .getBody(String.class));
            newExchange.getMessage().setBody(map);
            return newExchange;
        }

        Map<String, Object> map = oldExchange.getMessage().getBody(Map.class);
        String type =
                newExchange.getMessage()
                        .getHeader("type", String.class);
        map.put(
                type,
                newExchange.getMessage()
                        .getBody(String.class));
        oldExchange.getMessage().setBody(map);
        return oldExchange;
    }
}