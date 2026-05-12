package com.redhat;

import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

@Path("/customerpoint")
public class PointResource {

    @POST
    @Consumes(MediaType.WILDCARD)
    @Produces(MediaType.TEXT_PLAIN)
    public String calcPoint(String body) {

        if (body == null || body.isEmpty()) {
            return "NG: empty";
        }

        return "OK: " + body;
    }
}