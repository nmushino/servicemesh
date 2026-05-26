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

      .setBody(constant("""
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

      .unmarshal().json()

      .setHeader("type", constant("orders"));
    }
}