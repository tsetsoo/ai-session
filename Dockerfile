FROM rust:bookworm AS builder
WORKDIR /app

RUN rustup default nightly

COPY Cargo.toml Cargo.lock ./
COPY crates ./crates

RUN cargo build --release -p todo-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app

COPY --from=builder /app/target/release/todo-server /usr/local/bin/todo-server

RUN mkdir -p /app/data
EXPOSE 8080

CMD ["todo-server", "--db", "/app/data/todos.db", "--addr", "0.0.0.0:8080"]
