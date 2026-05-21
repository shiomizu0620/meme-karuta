FROM elixir:1.16-alpine

WORKDIR /app

COPY mix.exs ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get

COPY . .
RUN mix compile

EXPOSE 4000
CMD ["mix", "run", "--no-halt"]
