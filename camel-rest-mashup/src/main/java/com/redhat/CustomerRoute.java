package com.redhat;

import org.apache.camel.Exchange;
import org.apache.camel.builder.RouteBuilder;

import jakarta.enterprise.context.ApplicationScoped;

@ApplicationScoped
public class CustomerRoute extends RouteBuilder {

    @Override
    public void configure() throws Exception {

        from("direct:getCustomer")
            .routeId("customer-route")

            .setHeader(Exchange.HTTP_METHOD, constant("GET"))

            // 本来は外部API
            //.toD("http://customer-api/customers/${header.id}")

            // サンプル用Mock
            .setBody(simple("""
            {
              "id": "${header.id}",
              "name": "Taro Yamada",
              "status": "Gold"
            }
            """))

            .unmarshal().json()

            .setHeader("type", constant("customer"));
    }
}