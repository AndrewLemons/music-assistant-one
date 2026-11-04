# syntax=docker/dockerfile:1

# The App Review server: the published server image plus a synthesized sample library and an
# entrypoint that starts every container as a fresh, seeded install. See ServerCompanion/README.md.
ARG SERVER_IMAGE=music-assistant-one-server:local

# Audio is architecture-independent, so synthesize it once on the build machine.
FROM --platform=$BUILDPLATFORM ${SERVER_IMAGE} AS samples
COPY samples.py /tmp/samples.py
RUN python /tmp/samples.py /review-media

FROM ${SERVER_IMAGE}
LABEL org.opencontainers.image.title="Music Assistant One Review Server" \
      org.opencontainers.image.description="Stateless Music Assistant demo for App Review: fresh, seeded install on every start."
COPY --from=samples /review-media /review-media
COPY seed.py /review/seed.py
ENV REVIEW_USERNAME=apple-review
ENTRYPOINT ["python", "/review/seed.py"]
