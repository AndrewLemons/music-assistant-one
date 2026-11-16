# syntax=docker/dockerfile:1

# Music Assistant server with the optional Music Assistant One audio provider.
# The upstream entrypoint, /data volume, port, and runtime behavior are inherited unchanged.
# Dependabot proposes base updates; keep the tag and digest together.
FROM ghcr.io/music-assistant/server:2.10.12@sha256:7eb272e2e13da9a5d61dcbc4e1fcfc734776222b23f2825a9b5690d4427cfafb

LABEL org.opencontainers.image.title="Music Assistant One Server" \
      org.opencontainers.image.description="Music Assistant server with the Music Assistant One audio provider." \
      org.opencontainers.image.source="https://github.com/AndrewLemons/music-assistant-one" \
      org.opencontainers.image.documentation="https://github.com/AndrewLemons/music-assistant-one/tree/main/ServerCompanion" \
      org.opencontainers.image.authors="Andrew Lemons" \
      org.opencontainers.image.licenses="Apache-2.0"

# Install beside the built-in providers and precompile, so a non-root container needs no writes.
RUN --mount=type=bind,source=music_assistant_one,target=/tmp/music_assistant_one \
    providers="$("$VIRTUAL_ENV/bin/python" -c 'import music_assistant, pathlib; print(pathlib.Path(music_assistant.__file__).parent / "providers")')" \
    && cp -R /tmp/music_assistant_one "$providers/music_assistant_one" \
    && "$VIRTUAL_ENV/bin/python" -m compileall -q "$providers/music_assistant_one"
