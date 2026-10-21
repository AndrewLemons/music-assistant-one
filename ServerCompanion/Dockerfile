ARG MUSIC_ASSISTANT_IMAGE=ghcr.io/music-assistant/server:2.10.1
FROM ${MUSIC_ASSISTANT_IMAGE}
COPY music_assistant_one /tmp/music_assistant_one
RUN /app/venv/bin/python -c "import pathlib, shutil, music_assistant; shutil.copytree('/tmp/music_assistant_one', pathlib.Path(music_assistant.__file__).parent / 'providers/music_assistant_one', dirs_exist_ok=True)" \
    && rm -rf /tmp/music_assistant_one
