package com.redhat;

import org.apache.camel.Exchange;
import org.apache.camel.builder.RouteBuilder;

import jakarta.enterprise.context.ApplicationScoped;

@ApplicationScoped
public class OrderRoute extends RouteBuilder {

    @Override
    public void configure() throws Exception {

        from("direct:getOrders")
                .routeId("order-route")

                .setHeader(Exchange.HTTP_METHOD, constant("GET"))

                .setBody(simple("""
                    [
                      {
                        "orderId": "A001",
                        "amount": 1200
                      },
                      {
                        "orderId": "A002",
                        "amount": 3400
                      }
                    ]
                """))

                .setHeader("type", constant("orders"));
    }
}