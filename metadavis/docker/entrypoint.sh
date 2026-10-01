#!/usr/bin/env bash
#
# Container entry point for the MetaDAVis Galaxy Interactive Tool.
#
# Galaxy runs this (via the tool's <command>) inside the job's working
# directory, so everything that should end up in the Galaxy history has to be
# written there. MetaDAVis itself writes into its own directory
# (www/hmp2_output/...), which is why the app is copied into the job directory
# instead of being served from /opt/MetaDAVis.
#
# The three datasets the tool was given are staged by its <command> as
# metadavis_inputs/{otu,taxonomy,metadata}, and their paths are handed to the
# application as environment variables - the input format is fixed, the field
# separator is detected from each file header and the taxonomic level is chosen
# inside the application.
#
# Reducing a wide metadata table to the sample ids and the grouping condition is
# the tool's job, not the container's: metadavis-trim-metadata does it in the
# <command> and replaces metadavis_inputs/metadata with the result, so all that is
# left here is to hand the staged path to the application and report what the tool
# did (metadavis_trim.txt, written by the same tool).
#
# For a plain `docker run` the same script works, see the README.

set -euo pipefail

APP_SOURCE="${METADAVIS_APP_SOURCE:-/opt/MetaDAVis}"
JOB_DIR="${METADAVIS_JOB_DIR:-$PWD}"
PORT="${PORT:-8080}"
INPUT_DIR="$JOB_DIR/metadavis_inputs"
OUTPUT_DIR="${METADAVIS_OUTPUT_DIR:-$JOB_DIR/metadavis_outputs}"
APP_DIR="$JOB_DIR/app"
STARTUP_LOG="$JOB_DIR/metadavis_startup.txt"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
export METADAVIS_OUTPUT_DIR="$OUTPUT_DIR"

# Galaxy datasets have no meaningful file extension, so the staged copies keep
# the plain names above and the application detects the separator from the
# header line instead.
# Only export the datasets that were actually staged. A Galaxy job may carry
# none of them - the tool inputs are optional - and the application falls back to
# the browser upload or the example data in that case.
export_path() {
    local var="$1" path="$2"
    if [ -s "$path" ]; then
        export "$var=$path"
    else
        unset "$var" || true
    fi
}

export_path METADAVIS_OTU_TABLE "$INPUT_DIR/otu"
export_path METADAVIS_TAXONOMY_TABLE "$INPUT_DIR/taxonomy"
export_path METADAVIS_METADATA_FILE "$INPUT_DIR/metadata"

staged_report() {
    local path="$1" label="$2"
    if [ -s "$path" ]; then
        echo "$label $path ($(wc -c < "$path") bytes)"
    else
        echo "$label <not provided, upload in the browser>"
    fi
}

{
    echo "MetaDAVis Galaxy Interactive Tool"
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
    staged_report "$INPUT_DIR/otu" "OTU table: "
    staged_report "$INPUT_DIR/taxonomy" "taxonomy:   "
    staged_report "$INPUT_DIR/metadata" "metadata:   "
    if [ -s "$JOB_DIR/metadavis_trim.txt" ]; then
        echo "metadata:   $(cat "$JOB_DIR/metadavis_trim.txt")"
        echo "columns:    $(head -n 1 "$INPUT_DIR/metadata")"
    fi
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
