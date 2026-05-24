FROM elixir:1.16-alpine

WORKDIR /app

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get --frozen

COPY . .
RUN mix compile

EXPOSE 4000
CMD ["mix", "run", "--no-halt"]
