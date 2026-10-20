# syntax=docker/dockerfile:1

# Debian rather than Alpine: Ortex links ONNX Runtime, built for glibc.
ARG BUILDER_IMAGE="docker.io/hexpm/elixir:1.20.4-erlang-29.1.1-debian-trixie-20261005-slim@sha256:3f936c778234d0cce9d91dd61013cd2c830a215334bea598e4f5c666f8bb95bf"
ARG RUNNER_IMAGE="docker.io/library/debian:trixie-20261005-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f"

FROM ${BUILDER_IMAGE} AS builder

# Cargo builds the Ortex NIF and fetches ONNX Runtime next to it.
RUN apt-get update && \
  apt-get install -y --no-install-recommends build-essential git ca-certificates cargo && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && \
  mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Compiling first writes the colocated CSS and hooks the assets import.
RUN mix compile
RUN mix assets.setup && mix assets.deploy

# The model ships in the image, so the server starts without reaching
# Hugging Face.
ENV XDG_CACHE_HOME="/app/cache"
RUN mix anonimized_mcp.download_model

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update && \
  apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl && \
  sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen && \
  rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

ENV MIX_ENV="prod"
ENV XDG_CACHE_HOME="/app/cache"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/anonimized_mcp ./
COPY --from=builder --chown=nobody:root /app/cache ./cache

USER nobody

# The endpoint starts only after the model has loaded.
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=60s \
  CMD curl --fail --silent --show-error --output /dev/null http://127.0.0.1:4000/ || exit 1

CMD ["sh", "-c", "/app/bin/migrate && exec /app/bin/server"]
