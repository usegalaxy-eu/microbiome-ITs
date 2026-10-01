FROM rocker/shiny-verse:4.4.3

LABEL org.opencontainers.image.title="MicrobiomeProfiler" \
      org.opencontainers.image.description="MicrobiomeProfiler R package and Shiny app, packaged for the Galaxy Interactive Tools framework" \
      org.opencontainers.image.source="https://github.com/paulzierep/MicrobiomeProfiler" \
      org.opencontainers.image.licenses="GPL-2.0-or-later"

# Build tooling for the clusterProfiler/golem/ggtree dependency chain.
#
# - libgsl-dev:  DirichletMultinomial's C++ headers include gsl_rng.h
# - libglpk-dev: the igraph build links against libglpk.so.40
# - cmake/pkg-config: nloptr's configure refuses to build without cmake
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
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/galaxy_ie_helpers \
    && /opt/galaxy_ie_helpers/bin/pip install --no-cache-dir galaxy-ie-helpers
ENV PATH="/opt/galaxy_ie_helpers/bin:$PATH"

# Fetch the application while building rather than vendoring it in this
# packaging repository. ARGs keep the source overridable for development builds.
ARG APP_SOURCE=/opt/src/MicrobiomeProfiler
ARG APP_REPOSITORY=https://github.com/paulzierep/MicrobiomeProfiler.git
ARG APP_REF=galaxy-output
RUN git clone --depth 1 --branch "$APP_REF" "$APP_REPOSITORY" "$APP_SOURCE" \
    && rm -rf "$APP_SOURCE/.git"

# Dependencies and the package itself are installed together. The source tree
# is dropped afterwards because the app runs from the installed library.
# (install.R is copied to /tmp rather than run as docker/install.R because the
# image's working directory is /, not the build context.)
ENV MICROBIOMEPROFILER_SOURCE=$APP_SOURCE
COPY docker/install.R /tmp/install.R
RUN Rscript --vanilla /tmp/install.R && rm -f /tmp/install.R && rm -rf $APP_SOURCE

# The port the app listens on. It has to match <port> in the tool XML, because
# Galaxy publishes exactly that container port for the interactive tool entry
# point. PORT is an env var so the same image can also be run standalone on
# another port.
ARG PORT=8080
ENV PORT=$PORT
EXPOSE $PORT

COPY docker/entrypoint.sh /usr/local/bin/microbiomeprofiler-entrypoint
RUN chmod 0755 /usr/local/bin/microbiomeprofiler-entrypoint

# CMD, not ENTRYPOINT: Galaxy overrides the command of an interactive tool job
# with the tool's own <command>, which has to reach the shell untouched. An
# ENTRYPOINT here would turn the tool's command into arguments to this script
# instead of replacing it.
CMD ["/usr/local/bin/microbiomeprofiler-entrypoint"]
