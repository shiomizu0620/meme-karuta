FROM rust:latest AS builder
WORKDIR /app
COPY Cargo.toml ./
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
COPY --from=builder /app/target/release/judge /usr/local/bin/judge
EXPOSE 5002
CMD ["judge"]
