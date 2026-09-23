FROM debian:bookworm-slim

ARG GODOT_VERSION=4.7.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates wget unzip libfontconfig1 libx11-6 libxcursor1 libxinerama1 libxi6 libxrandr2 libasound2 libpulse0 libgl1 \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q "https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" -O /tmp/godot.zip \
    && unzip /tmp/godot.zip -d /usr/local/bin \
    && mv "/usr/local/bin/Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot \
    && chmod +x /usr/local/bin/godot \
    && rm /tmp/godot.zip

WORKDIR /app
COPY . /app
ENV PORT=10000
CMD ["/usr/local/bin/godot", "--headless", "--path", "/app"]
