# LibreQDA is used exactly as upstream publishes it
# (https://gitlab.com/bin-cirst/libreqda/libre-qda builds and pushes
# phunudes/libreqda from its own CI). Nothing is rebuilt and no app code is
# changed; the only adjustment is the ENTRYPOINT.
#
# Upstream's ENTRYPOINT is ["tini", "--", "libreqda", "--no-browser",
# "--bind=0.0.0.0"]. Galaxy starts an interactive-tool job by appending a job
# script to the container command, which with that ENTRYPOINT would be passed
# to libreqda as extra CLI arguments and break the launch. Keeping only tini
# (a good PID 1 to keep) leaves the job script in charge, and it runs the very
# same command the upstream entrypoint would have.
ARG APP_VERSION=1.2.1
FROM phunudes/libreqda:${APP_VERSION}

ENTRYPOINT ["tini", "--"]
CMD []
