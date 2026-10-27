# Gephi Lite is used as upstream publishes it
# (https://github.com/gephi/gephi-lite publishes container images; we build
# and push gephi-lite-gxit to quay.io/galaxy so the interactive tool can
# reference it). This Dockerfile mirrors upstream's approach but can be used
# to build and publish from this repo.
ARG APP_VERSION=latest
FROM gephi/gephi-lite:${APP_VERSION}

# Galaxy interactive tools expect a job script appended to the container
# command. The upstream image uses nginx as entrypoint; overriding to a
# no-op entrypoint leaves tini or nothing in the way and lets Galaxy run
# the job script. Most images in this repo keep tini as PID 1 via
# ENTRYPOINT ["tini", "--"] or similar; nginx starts fine under tini too.
ENTRYPOINT []
CMD []
