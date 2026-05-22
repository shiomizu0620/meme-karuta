FROM gcc:13-bookworm AS builder

WORKDIR /build
COPY serializer.h serializer.c Makefile ./
RUN make

FROM debian:bookworm-slim

WORKDIR /app
COPY --from=builder /build/serializer .

EXPOSE 5004
CMD ["./serializer"]
