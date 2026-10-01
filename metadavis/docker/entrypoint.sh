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
# metadavis_inputs/{otu,taxonomy,metadata}. Only their paths are handed to the
# application, as environment variables - the input format is fixed, the field
# separator is detected from each file header and the taxonomic level is chosen
# inside the application.
#
# For a plain `docker run` the same script works, see the README.

set -euo pipefail

APP_SOURCE="${METADAVIS_APP_SOURCE:-/opt/MetaDAVis}"
JOB_DIR="${METADAVIS_JOB_DIR:-$PWD}"
PORT="${PORT:-8080}"
INPUT_DIR="$JOB_DIR/metadavis_inputs"
APP_DIR="$JOB_DIR/app"
STARTUP_LOG="$JOB_DIR/metadavis_startup.txt"

mkdir -p "$INPUT_DIR"

# Galaxy datasets have no meaningful file extension, so the staged copies keep
# the plain names above and the application detects the separator from the
# header line instead.
export METADAVIS_OTU_TABLE="$INPUT_DIR/otu"
export METADAVIS_TAXONOMY_TABLE="$INPUT_DIR/taxonomy"
export METADAVIS_METADATA_FILE="$INPUT_DIR/metadata"

staged_report() {
    local path="$1" label="$2"
    if [ -s "$path" ]; then
        echo "$label:     $path ($(wc -c < "$path") bytes)"
    else
        echo "$label: <not staged, upload in the browser>"
    fi
}

{
    echo "MetaDAVis Galaxy Interactive Tool"
    echo "started:   $(date --iso-8601=seconds)"
    echo "port:      $PORT"
    echo
    staged_report "$METADAVIS_OTU_TABLE" "OTU table"
    staged_report "$METADAVIS_TAXONOMY_TABLE" "taxonomy"
    staged_report "$METADAVIS_METADATA_FILE" "metadata"
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