package com.redhat;

import org.apache.camel.Exchange;
import org.apache.camel.builder.RouteBuilder;

import jakarta.enterprise.context.ApplicationScoped;

@ApplicationScoped
public class PointRoute extends RouteBuilder {

    @Override
    public void configure() throws Exception {

        from("direct:getPoint")
                .routeId("point-route")

                .setHeader(Exchange.HTTP_METHOD, constant("GET"))

                .setBody(simple("""
                    {
                      "point": 12800,
                      "rank": "Platinum"
                    }
                """))

                .setHeader("type", constant("point"));
    }
}