ARG BASE_IMAGE=rocker/shiny-verse:4.4.3
FROM ${BASE_IMAGE} AS dependencies
LABEL org.opencontainers.image.title="Holomics" \
      org.opencontainers.image.source="https://github.com/paulzierep/Holomics" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"
RUN apt-get update && apt-get install -y --no-install-recommends \
    libglpk40 libglib2.0-0 libgmp10 libgsl-dev libxml2-dev libssl-dev \
    libcurl4-openssl-dev gfortran git python3-venv net-tools cmake libnlopt-dev libgmp-dev libmpfr-dev \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/galaxy_ie_helpers \
    && /opt/galaxy_ie_helpers/bin/pip install --no-cache-dir galaxy-ie-helpers==0.3.0
ENV PATH="/opt/galaxy_ie_helpers/bin:$PATH"
COPY docker/install.R /opt/holomics-install.R
RUN APP_STAGE=deps Rscript /opt/holomics-install.R

FROM dependencies AS application
ARG APP_REPOSITORY=https://github.com/paulzierep/Holomics.git
ARG APP_REVISION=cbe14e26b4afd0f6ced2227b92c41f49a9c2679a
RUN git init -q /opt/Holomics \
    && git -C /opt/Holomics remote add origin "$APP_REPOSITORY" \
    && git -C /opt/Holomics fetch --depth 1 origin "$APP_REVISION" \
    && git -C /opt/Holomics checkout -q FETCH_HEAD \
    && APP_STAGE=app Rscript /opt/holomics-install.R \
    && rm -rf /opt/Holomics/.git
COPY docker/entrypoint.sh /usr/local/bin/holomics-entrypoint
RUN chmod 0755 /usr/local/bin/holomics-entrypoint
ENV PORT=8080
EXPOSE 8080
CMD ["/usr/local/bin/holomics-entrypoint"]
