# ----------------------------
# Base: UBI9 + OpenJDK 21
# ----------------------------
FROM registry.access.redhat.com/ubi9/ubi

# Install required packages: COBOL build + OpenJDK
RUN dnf install -y \
    gcc make wget tar ncurses-devel gmp-devel libtool diffutils libdb-devel \
    java-21-openjdk \
 && dnf clean all

# ----------------------------
# Build GNU COBOL
# ----------------------------
WORKDIR /tmp
RUN wget https://ftp.gnu.org/gnu/gnucobol/gnucobol-3.2.tar.gz \
 && tar xzf gnucobol-3.2.tar.gz \
 && cd gnucobol-3.2 \
 && ./configure \
 && make -j$(nproc) \
 && make install

ENV LD_LIBRARY_PATH=/usr/local/lib

# ----------------------------
# Prepare COBOL app
# ----------------------------
WORKDIR /app
COPY customer-point.cbl .
RUN cobc -x customer-point.cbl -o customer-point

# ----------------------------
# Prepare Quarkus app
# ----------------------------
WORKDIR /deployments
COPY quarkus-app/lib/ ./lib/
COPY quarkus-app/*.jar ./
COPY quarkus-app/app/ ./app/
COPY quarkus-app/quarkus-run.jar ./
COPY quarkus-app/ ./quarkus/

# ----------------------------
# Entrypoint script
# ----------------------------
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]