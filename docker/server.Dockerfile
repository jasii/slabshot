# Slabshot dedicated server. Runs the project with the stock headless Godot
# binary (no export templates needed). Build from the repo root:
#   docker build -f docker/server.Dockerfile -t slabshot-server .
ARG GODOT_VERSION=4.7.2

FROM debian:bookworm-slim AS build
ARG GODOT_VERSION
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget unzip \
 && rm -rf /var/lib/apt/lists/*
RUN wget -q "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" -O /tmp/godot.zip \
 && unzip -q /tmp/godot.zip -d /tmp/godot \
 && mv /tmp/godot/Godot_v${GODOT_VERSION}-stable_linux.x86_64 /opt/godot \
 && chmod +x /opt/godot
COPY . /game
# Build the .godot import cache (global class names) at image build time.
RUN HOME=/tmp /opt/godot --headless --path /game --import

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libfontconfig1 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -r -u 10001 -m -d /home/slab slab
COPY --from=build /opt/godot /opt/godot
COPY --from=build --chown=slab:slab /game /game
USER slab
ENV SLAB_PORT=27500 \
    SLAB_NAME="Slabshot server" \
    SLAB_MODE=ffa \
    SLAB_MAX=64
EXPOSE 27500/udp 27501/udp
ENTRYPOINT ["/opt/godot", "--headless", "--path", "/game", "--", "--server"]
