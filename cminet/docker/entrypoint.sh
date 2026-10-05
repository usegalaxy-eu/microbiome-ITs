#!/usr/bin/env bash
#
# Container entry point for the CMiNet Galaxy Interactive Tool.
#
# Galaxy runs this (via the tool's <command>) inside the job's working directory,
# so everything that should end up in the Galaxy history has to be written there.
# CMiNet writes its Network/ and Binary_Network/ folders relative to its own
# working directory, which is why the app is copied into the job directory
# instead of being served from /opt/CMiNetShinyAPP.
#
# The abundance matrix (and optionally a weighted network) that the tool was
# given are staged by its <command> as cminet_inputs/{abundance,weighted_network},
# and their paths are handed to the application as environment variables. The
# app also lets the user import a dataset from the current Galaxy history, which
# repoints CMINET_INPUT at the downloaded copy; the original staged dataset is
# left alone so that behaviour is identical with and without a history.
#
# For a plain `docker run` the same script works, see the README.

set -euo pipefail

APP_SOURCE="${CMINET_APP_SOURCE:-/opt/CMiNetShinyAPP}"
JOB_DIR="${CMINET_JOB_DIR:-$PWD}"
PORT="${PORT:-8080}"
INPUT_DIR="$JOB_DIR/cminet_inputs"
OUTPUT_DIR="${CMINET_OUTPUT_DIR:-$JOB_DIR/cminet_outputs}"
APP_DIR="$JOB_DIR/app"
STARTUP_LOG="$JOB_DIR/cminet_startup.txt"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
export CMINET_OUTPUT_DIR="$OUTPUT_DIR"

# Galaxy datasets have no meaningful file extension, so the staged copies keep
# the plain names above and the application reads them by content.
# Only export the datasets that were actually staged. The abundance matrix is the
# only required input; a Galaxy job may carry none of them, and the application
# falls back to the browser upload or its own example data in that case.
export_path() {
    local var="$1" path="$2"
    if [ -s "$path" ]; then
        export "$var=$path"
    else
        unset "$var" || true
    fi
}

export_path CMINET_INPUT "$INPUT_DIR/abundance"
export_path CMINET_WEIGHTED_NETWORK "$INPUT_DIR/weighted_network"

staged_report() {
    local path="$1" label="$2"
    if [ -s "$path" ]; then
        echo "$label $path ($(wc -c < "$path") bytes)"
    else
        echo "$label <not provided, upload in the browser>"
    fi
}

{
    echo "CMiNet Galaxy Interactive Tool"
    echo "started:   $(date --iso-8601=seconds)"
    echo "port:      $PORT"
    echo "Galaxy URL: ${GALAXY_URL:-<not set>}"
    echo "Galaxy callback port: ${GALAXY_WEB_PORT:-<not set>}"
    echo "Galaxy history: ${HISTORY_ID:-<not set>}"
    if [ -n "${API_KEY:-}" ]; then
        echo "Galaxy API key: present"
    else
        echo "Galaxy API key: missing"
    fi
    echo "output directory: $OUTPUT_DIR"
    echo
    staged_report "$INPUT_DIR/abundance" "abundance matrix: "
    staged_report "$INPUT_DIR/weighted_network" "weighted network:  "
    echo
    echo "R session:"
    Rscript --vanilla -e 'cat(paste(utils::capture.output(sessionInfo()), collapse = "\n"), "\n")'
} > "$STARTUP_LOG" 2>&1

cat "$STARTUP_LOG"

mkdir -p "$APP_DIR"
cp -a "$APP_SOURCE/." "$APP_DIR/"

cd "$APP_DIR"

# shiny::runApp() rather than shiny-server: shiny-server requires a fixed `run_as`
# user and writes to root-owned /var/log and /var/lib, neither of which works in
# a container that Galaxy starts as the job owner.
exec Rscript --vanilla -e \
    "shiny::runApp('$APP_DIR', host = '0.0.0.0', port = $PORT, launch.browser = FALSE, quiet = FALSE)"