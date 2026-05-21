FROM haskell:9.6-slim AS builder
WORKDIR /app
COPY shuffle.cabal cabal.project ./
RUN cabal update && cabal build --only-dependencies -j4
COPY src/ src/
RUN cabal build -j4 && \
    cp $(cabal list-bin shuffle) /app/shuffle-exe

FROM debian:bookworm-slim
WORKDIR /app
RUN apt-get update && apt-get install -y libgmp10 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/shuffle-exe ./shuffle
EXPOSE 5001
CMD ["./shuffle"]
