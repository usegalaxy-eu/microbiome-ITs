# CMiNet Shiny app (https://github.com/solislemuslab/CMiNetShinyAPP) packaged as
# a Galaxy Interactive Tool image.
#
# The upstream README asks for R >= 4.3 and the Shinyverse stack; 4.4.3 is the
# same pairing rocker/shiny-verse already uses for MetaDAVis (R 4.4.3,
# Bioconductor 3.20, shiny 1.10.0, ggplot2 3.5.2). CMiNet imports WGCNA, and
# WGCNA from Bioconductor 3.20 is built against the ggplot2 3.x internals, so the
# pinned CRAN snapshot in docker/install.R matters here for the same reason it
# does for MetaDAVis.
ARG BASE_IMAGE=rocker/shiny-verse:4.4.3
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="CMiNet" \
      org.opencontainers.image.description="CMiNet R Shiny app, packaged for the Galaxy Interactive Tools framework" \
      org.opencontainers.image.source="https://github.com/solislemuslab/CMiNetShinyAPP" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

# System libraries. Everything the app itself needs is R-level (igraph, huge,
# gtools, SpiecEasi, SPRING, WGCNA), so this is mostly build tooling plus the
# curl/ssl/xml headers that several of those packages compile against.
#
# libglpk40, libglib2.0-0 and libgmp10 are runtime libraries of the *binary*
# builds that the pinned Posit snapshot serves. Without them install.packages()
# reports "DONE" and then requireNamespace() fails with a missing .so, which
# would only show up as an empty panel in an interactive session. The
# verification step in docker/install.R is what catches that at build time.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        gfortran \
        libcurl4-openssl-dev \
        libssl-dev \
        libxml2-dev \
        libgsl-dev \
        libglpk40 \
        libglib2.0-0 \
        libgmp10 \
        pkg-config \
        zip \
        unzip \
        ca-certificates \
        curl \
        git \
        net-tools \
    && rm -rf /var/lib/apt/lists/*

# Python helper for talking back to the Galaxy API.
#
# galaxy_ie_helpers (https://github.com/bgruening/galaxy_ie_helpers) is what
# pushes a downloaded network, edge list or archive into the history of the
# running interactive session. It goes into its own virtual environment rather
# than the system python, because Ubuntu marks that one as externally managed
# (PEP 668) and because the R stack of this image must not reach it by accident.
#
# net-tools, installed above, is not optional: galaxy_ie_helpers determines the
# docker bridge address of its container with `netstat -nr`, so without it every
# upload would fail with a FileNotFoundError.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/galaxy_ie_helpers \
    && /opt/galaxy_ie_helpers/bin/pip install --no-cache-dir galaxy-ie-helpers \
    && /opt/galaxy_ie_helpers/bin/python -c "import galaxy_ie_helpers"

# Install the R dependencies before copying the app so that editing the app does
# not invalidate the (long) package build layer. This is also where SpiecEasi,
# SPRING and CMiNet are compiled - expect this to take a while on a cold cache.
COPY docker/install.R /tmp/install.R
RUN Rscript --vanilla /tmp/install.R && rm -f /tmp/install.R

# The application is fetched while building rather than vendored in this
# packaging repository. The fork's branch contains the Galaxy input, the
# "Send to Galaxy" buttons and the history picker.
ARG APP_REPOSITORY=https://github.com/paulzierep/CMiNetShinyAPP.git
ARG APP_REF=galaxy-integration
ARG APP_REVISION=branch
ARG CACHE_BUSTER=
RUN set -eux; \
    echo "CB=$CACHE_BUSTER"; \
    if [ -d /tmp/local_cminet ]; then \
        cp -r /tmp/local_cminet /opt/CMiNetShinyAPP; \
    elif [ "$APP_REVISION" = "branch" ]; then \
        git clone --depth 1 --branch "$APP_REF" "$APP_REPOSITORY" /opt/CMiNetShinyAPP; \
    else \
        git init -q /opt/CMiNetShinyAPP; \
        git -C /opt/CMiNetShinyAPP remote add origin "$APP_REPOSITORY"; \
        git -C /opt/CMiNetShinyAPP fetch -q --depth 1 origin "$APP_REVISION"; \
        git -C /opt/CMiNetShinyAPP checkout -q FETCH_HEAD; \
    fi; \
    rm -rf /opt/CMiNetShinyAPP/.git

# The port the app listens on. It has to match <port> in the tool XML, because
# Galaxy publishes exactly that container port for the interactive tool entry
# point. PORT is an env var so the same image can be run standalone on another
# port.
ARG PORT=8080
ENV PORT=$PORT
EXPOSE $PORT

COPY docker/entrypoint.sh /usr/local/bin/cminet-entrypoint
RUN chmod 0755 /usr/local/bin/cminet-entrypoint

# CMD, not ENTRYPOINT: Galaxy overrides the command of an interactive tool job
# with the tool's own <command>, which has to reach the shell untouched.
CMD ["/usr/local/bin/cminet-entrypoint"]