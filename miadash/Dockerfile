FROM rocker/shiny-verse:4.6.1

LABEL org.opencontainers.image.title="miaDash" \
      org.opencontainers.image.description="miaDash R package and Shiny app, packaged for the Galaxy Interactive Tools framework" \
      org.opencontainers.image.source="https://github.com/paulzierep/miaDash" \
      org.opencontainers.image.licenses="Artistic-2.0"

# Build tooling for the Bioconductor dependency chain (iSEE, mia, scater and
# friends) and the runtime helpers the export formats need.
#
# - zip: utils::zip is what writes the Mothur and QIIME2 export archives
# - libicu-dev/libharfbuzz-dev/libfribidi-dev: textshaping/systemfonts, which
#   the shiny-verse stack builds against
# - libglpk40, libglib2.0-0 and libgmp10 are runtime libraries of the *binary*
#   builds that the pinned Posit snapshot serves (igraph is in the iSEE chain
#   and its binary links against libglpk.so.40). Without them install.packages()
#   reports "DONE" and then requireNamespace() fails with a missing .so, which
#   would only show up as an empty panel in an interactive session. The
#   verification step in docker/install.R is what catches that at build time.
# - libgsl-dev: DirichletMultinomial (mia's dependency) has no binary build and
#   compiles against the GSL headers (gsl/gsl_rng.h, gsl-config).
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
        libglpk40 \
        libglib2.0-0 \
        libgmp10 \
        libgsl-dev \
        cmake \
        pkg-config \
        fonts-dejavu-core \
        fonts-texgyre \
        ca-certificates \
        curl \
        git \
        net-tools \
        python3-venv \
        zip \
    && rm -rf /var/lib/apt/lists/*

# galaxy-ie-helpers talks to the Galaxy API from inside the container. Its own
# virtualenv keeps it and its bioblend dependency off the R side.
RUN python3 -m venv /opt/galaxy_ie_helpers \
    && /opt/galaxy_ie_helpers/bin/pip install --no-cache-dir galaxy-ie-helpers
ENV PATH="/opt/galaxy_ie_helpers/bin:$PATH"

# Dependencies first, on their own layer. This is the tens-of-minutes part and
# it only changes when install.R changes, so keeping it ahead of the clone is
# what makes an app-only rebuild take a minute instead of half an hour.
#
# install.R is copied to /tmp rather than run as docker/install.R because the
# image's working directory is /, not the build context.
COPY docker/install.R /tmp/install.R
RUN MIADASH_DEPS_ONLY=1 Rscript --vanilla /tmp/install.R

# Fetch the application while building rather than vendoring it in this
# packaging repository. The fork's `galaxy-it-adaptations` branch carries the
# Send-to-Galaxy integration and the staged-input import. ARGs keep the source
# overridable for development builds.
#
# APP_REVISION is not decoration: a RUN layer is cached on its command string and
# build args, and BuildKit cannot see that the remote branch moved. Cloning a
# branch under a constant APP_REF therefore reused the previously cached clone,
# so a rebuild silently produced an image containing the *old* app. Pinning the
# commit makes the layer key change whenever the app changes.
ARG APP_SOURCE=/opt/src/miaDash
ARG APP_REPOSITORY=https://github.com/paulzierep/miaDash.git
ARG APP_REF=galaxy-it-adaptations
ARG CACHE_BUSTER
ARG APP_REVISION=branch
RUN set -eux; \
    echo "CB=$CACHE_BUSTER"; \
    if [ "$APP_REVISION" = "branch" ]; then \
        git clone --depth 1 --branch "$APP_REF" "$APP_REPOSITORY" "$APP_SOURCE"; \
    else \
        git init -q "$APP_SOURCE"; \
        git -C "$APP_SOURCE" remote add origin "$APP_REPOSITORY"; \
        git -C "$APP_SOURCE" fetch -q --depth 1 origin "$APP_REVISION"; \
        git -C "$APP_SOURCE" checkout -q FETCH_HEAD; \
    fi; \
    rm -rf "$APP_SOURCE/.git"

# The app package itself, plus the verification that it loads and builds. Runs
# after the clone, so a new app commit costs a minute rather than a full rebuild.
# The source tree is dropped afterwards because the app runs from the installed
# library.
ENV MIADASH_SOURCE=$APP_SOURCE
RUN MIADASH_APP_ONLY=1 Rscript --vanilla /tmp/install.R \
    && rm -f /tmp/install.R

# The port the app listens on. It has to match <port> in the tool XML, because
# Galaxy publishes exactly that container port for the interactive tool entry
# point. PORT is an env var so the same image can also be run standalone on
# another port.
ARG PORT=8080
ENV PORT=$PORT
EXPOSE $PORT

COPY docker/entrypoint.sh /usr/local/bin/miadash-entrypoint
RUN chmod 0755 /usr/local/bin/miadash-entrypoint

# CMD, not ENTRYPOINT: Galaxy overrides the command of an interactive tool job
# with the tool's own <command>, which has to reach the shell untouched. An
# ENTRYPOINT here would turn the tool's command into arguments to this script
# instead of replacing it.
CMD ["/usr/local/bin/miadash-entrypoint"]
