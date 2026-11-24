FROM debian:bookworm-slim
ARG TARGETARCH
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*
RUN --mount=type=secret,id=build_ca \
    set -eu; \
    if [ "$TARGETARCH" = amd64 ]; then \
        arch=x86_64; sum=39859282ce677fce19e6eb45c37596a90a25c324c95b4e7e02d428b6cae294a1; \
    elif [ "$TARGETARCH" = arm64 ]; then \
        arch=aarch64; sum=f8d7d63384fad5edfaf5423b0ff1a1dbca9c44ec43beaa35c234b20a584aea66; \
    else echo 'This build requires amd64 or arm64.'; exit 1; fi; \
    if [ -s /run/secrets/build_ca ]; then export CURL_CA_BUNDLE=/run/secrets/build_ca; fi; \
    name="lune-0.11.1-linux-$arch.zip"; \
    curl -fsSL --retry 3 "https://github.com/lune-org/lune/releases/download/v0.11.1/$name" -o /tmp/lune.zip; \
    printf '%s  /tmp/lune.zip\n' "$sum" | sha256sum -c -; \
    unzip -q /tmp/lune.zip lune -d /usr/local/bin; \
    chmod 755 /usr/local/bin/lune; \
    rm /tmp/lune.zip
WORKDIR /srv/pot
COPY --chown=65534:65534 luau/ /srv/pot/
USER 65534:65534
