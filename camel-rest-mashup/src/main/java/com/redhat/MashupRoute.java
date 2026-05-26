package com.redhat;

import org.apache.camel.builder.RouteBuilder;

import jakarta.enterprise.context.ApplicationScoped;

@ApplicationScoped
public class MashupRoute extends RouteBuilder {

    @Override
    public void configure() throws Exception {

        restConfiguration()
                .component("platform-http")
                .host("0.0.0.0")
                .port(8080);

        rest("/api")
                .get("/dashboard/{id}")
                .produces("application/json")
                .to("direct:mashup");

        from("direct:mashup")
                .routeId("mashup-route")

                .log("Mashup request id=${header.id}")

                .multicast(new MashupAggregationStrategy())
                    .parallelProcessing()

                    .to(
                            "direct:getCustomer",
                            "direct:getPoint",
                            "direct:getOrders"
                    )

                .end()

                .marshal().json();
    }
}