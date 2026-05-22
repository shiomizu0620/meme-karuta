FROM haskell:9.6-slim AS builder
WORKDIR /build
COPY shuffle.cabal cabal.project ./
RUN cabal update && cabal build --only-dependencies -j4
COPY src/ src/
RUN cabal install exe:shuffle --installdir=/app --install-method=copy --overwrite-policy=always -j4

FROM debian:bookworm-slim
WORKDIR /app
RUN apt-get update && apt-get install -y libgmp10 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/shuffle ./shuffle
EXPOSE 5001
CMD ["./shuffle"]
