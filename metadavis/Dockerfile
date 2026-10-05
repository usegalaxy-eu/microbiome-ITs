# MetaDAVis (https://github.com/GudaLab/MetaDAVis) packaged as a Galaxy
# Interactive Tool image.
#
# The upstream README recommends R >= 4.4.2 with Bioconductor >= 3.20; the
# 4.4.3 tag of rocker/shiny-verse is exactly that pairing (R 4.4.3, Bioconductor
# 3.20, shiny 1.10.0, ggplot2 3.5.2), which keeps us on the ggplot2 3.x/4.x
# boundary the app was written against. Bump the tag to 4.5.x/4.6.x only together
# with a check of the plot code.

ARG BASE_IMAGE=rocker/shiny-verse:4.4.3
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="MetaDAVis" \
      org.opencontainers.image.description="MetaDAVis R Shiny app, packaged for the Galaxy Interactive Tools framework" \
      org.opencontainers.image.source="https://github.com/GudaLab/MetaDAVis"

# No org.opencontainers.image.licenses label on purpose: the upstream repository
# carries no LICENSE file and no license metadata, so any license claim here
# would be unsourced. Add the label once the upstream license is confirmed.

# System libraries listed in the upstream README, minus the ones rocker/shiny
# already provides. libtiff-dev is the Ubuntu 24.04 name for libtiff5-dev, and
# libgsl-dev is needed by DirichletMultinomial (a dependency of decontam, and
# through it of microbiome), which BiocManager installs without failing the
# build if it cannot compile.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        gfortran \
        libcurl4-openssl-dev \
        libssl-dev \
        libxml2-dev \
        libfontconfig1-dev \
        libfreetype6-dev \
        libpng-dev \
        libjpeg-dev \
        libtiff-dev \
        libharfbuzz-dev \
        libfribidi-dev \
        libicu-dev \
        libgsl-dev \
        libglpk-dev \
        cmake \
        pkg-config \
        fonts-dejavu-core \
        fonts-texgyre \
        ca-certificates \
        curl \
        git \
        net-tools \
    && rm -rf /var/lib/apt/lists/*

# Python helper for talking back to the Galaxy API.
#
# galaxy_ie_helpers (https://github.com/bgruening/galaxy_ie_helpers) is what
# pushes a downloaded table or plot into the history of the running interactive
# session. It goes into its own virtual environment rather than into the system
# python, because Ubuntu marks that one as externally managed (PEP 668) and
# because the R stack of this image must not be able to reach it by accident.
#
# net-tools, installed above, is not optional: galaxy_ie_helpers determines the
# docker bridge address of its container with `netstat -nr`, so without it
# every upload would fail with a FileNotFoundError.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/galaxy_ie_helpers \
    && /opt/galaxy_ie_helpers/bin/pip install --no-cache-dir galaxy-ie-helpers \
    && /opt/galaxy_ie_helpers/bin/python -c "import galaxy_ie_helpers"

# Install the R dependencies before copying the app so that editing the app does
# not invalidate the (long) package build layer.
COPY docker/install.R /tmp/install.R
RUN Rscript --vanilla /tmp/install.R && rm -f /tmp/install.R

# Headless Chrome for plotly::save_image(), which the bulk export uses for the
# 3D plots. Best effort: without it everything else still works, only the static
# export of plotly figures fails.
RUN set -eux; \
    if curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; then \
        apt-get update \
        && apt-get install -y --no-install-recommends /tmp/chrome.deb \
        && rm -f /tmp/chrome.deb \
        && rm -rf /var/lib/apt/lists/*; \
    else \
        echo "Chrome could not be downloaded, plotly::save_image() will not work"; \
        rm -f /tmp/chrome.deb; \
    fi
ENV CHROMOTE_CHROME=/usr/bin/google-chrome

# The application is fetched while building rather than vendored in this
# packaging repository. The fork's `galaxy-it-adaptations` branch carries the
# Galaxy input format and the send-to-Galaxy integration.
ARG APP_REPOSITORY=https://github.com/paulzierep/MetaDAVis.git
ARG APP_REF=galaxy-it-adaptations
RUN git clone --depth 1 --branch "$APP_REF" "$APP_REPOSITORY" /opt/MetaDAVis \
    && rm -rf /opt/MetaDAVis/.git

# The port the app listens on. It has to match <port> in the tool XML, because
# Galaxy publishes exactly that container port for the interactive tool entry
# point. PORT is an env var so the same image can be run standalone on another
# port.
ARG PORT=8080
ENV PORT=$PORT
EXPOSE $PORT

COPY docker/entrypoint.sh /usr/local/bin/metadavis-entrypoint
RUN chmod 0755 /usr/local/bin/metadavis-entrypoint

# Reduces a wide metadata table to the sample ids plus the grouping condition,
# called by the tool's <command> before this container is started.
COPY docker/trim_metadata.py /usr/local/bin/metadavis-trim-metadata
RUN chmod 0755 /usr/local/bin/metadavis-trim-metadata

# CMD, not ENTRYPOINT: Galaxy overrides the command of an interactive tool job
# with the tool's own <command>, which has to reach the shell untouched.
CMD ["/usr/local/bin/metadavis-entrypoint"]
