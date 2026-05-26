#!/bin/bash
set -e

# Quarkus アプリ実行
if [ -f /deployments/quarkus/quarkus-run.jar ]; then
    echo "Starting Quarkus app..."
    exec java -jar /deployments/quarkus/quarkus-run.jar
else
    echo "No executable found!"
    exit 1
fi