FROM rust:1 as build-env
WORKDIR /app
COPY . /app
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y cmake
RUN cargo build --release

FROM gcr.io/distroless/cc-debian12
COPY --from=build-env /app/target/release/pproxy /
ENTRYPOINT ["/pproxy"]


# docker build --rm=true -t pproxy ~/devel/scripts/man/nextcloud/pproxy
# docker run --volume ~/devel/pingora-tests/keys:/keys:ro -it --rm -p 443:443 --name pproxy --hostname pproxy pproxy --log-level debug --listen-ip-port 0.0.0.0:443 --dest-ip-port 127.0.0.1:12345 --priv-key /keys/server-key.pem --cert /keys/server-cert.pem --ca /keys/CA.crt.pem
