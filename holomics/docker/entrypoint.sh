#!/usr/bin/env bash
set -euo pipefail
export HOLOMICS_INPUT_DIR="${HOLOMICS_INPUT_DIR:-$PWD/holomics_inputs}"
export HOLOMICS_OUTPUT_DIR="${HOLOMICS_OUTPUT_DIR:-$PWD/holomics_outputs}"
export OMP_NUM_THREADS="${GALAXY_SLOTS:-1}"
export OPENBLAS_NUM_THREADS="${GALAXY_SLOTS:-1}"
mkdir -p "$HOLOMICS_OUTPUT_DIR"
{
    echo "Holomics Galaxy Interactive Tool"
    echo "Port: ${PORT:-8080}"
    echo "Output directory: $HOLOMICS_OUTPUT_DIR"
    cat /opt/holomics-session-info.txt
} > "${HOLOMICS_STARTUP_LOG:-$PWD/holomics_startup.txt}"
if [ "${HOLOMICS_STARTUP_ONLY:-0}" = 1 ]; then exit 0; fi
exec Rscript -e 'Holomics::run_app(options = list(host = "0.0.0.0", port = as.integer(Sys.getenv("PORT", "8080")), launch.browser = FALSE))'
