#!/usr/bin/env bash
#
# Container entry point for the miaDash Galaxy Interactive Tool.
#
# Galaxy runs this (via the tool's <command>) inside the job's working directory,
# so everything that should end up in the Galaxy history has to be written there.
#
# The raw tables the tool was given are staged by its <command> as
# miadash_inputs/{assay.tsv,coldata.tsv,rowdata.tsv,row.tree}, and their paths
# are handed to the application as environment variables (MIADASH_ASSAY, ...).
# The application imports them at session start through the same constructor its
# "Raw Data" tab uses (R/galaxy_input.R on the fork's galaxy-it-adaptations
# branch). Only the datasets that were actually staged are exported: an unset or
# empty variable means "nothing staged" and the app starts with an empty
# dashboard, ready for a browser upload.
#
# The app is an R package installed into the image, so there is no app directory
# to copy around: the app object is built and handed to shiny::runApp(), like the
# MicrobiomeProfiler image next door.
#
# MIADASH_STARTUP_LOG is the declared startup-log dataset Galaxy hands in, so the
# log is written straight into the output instead of being copied out of the job
# directory at the end of the session. MIADASH_LOG_DIR is the job directory: the
# upload log is a diagnostic and must stay out of the discovered output directory.
#
# For a plain `docker run` the same script works, see the README.

set -euo pipefail

JOB_DIR="${MIADASH_JOB_DIR:-$PWD}"
PORT="${PORT:-8080}"
INPUT_DIR="$JOB_DIR/miadash_inputs"
OUTPUT_DIR="${MIADASH_OUTPUT_DIR:-$JOB_DIR/miadash_outputs}"
# The declared startup log output when the tool XML provides it (Galaxy hands
# the dataset path in), and a file in the job directory otherwise (plain
# `docker run`).
STARTUP_LOG="${MIADASH_STARTUP_LOG:-$JOB_DIR/miadash_startup.txt}"
# Where the upload log goes. Deliberately not the output directory: Galaxy turns
# every file in there into a dataset of the results collection, and a log is not a
# result.
LOG_DIR="${MIADASH_LOG_DIR:-$JOB_DIR}"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$LOG_DIR"
mkdir -p "$(dirname "$STARTUP_LOG")"
export MIADASH_OUTPUT_DIR="$OUTPUT_DIR"
export MIADASH_LOG_DIR="$LOG_DIR"

# Truncated here, then appended to below, because the input report runs before
# the log is assembled and has somewhere to say what it did.
: > "$STARTUP_LOG"

# Export a staged input only when it is a non-empty file. Galaxy datasets have
# no meaningful file extension, so the staged copies keep the fixed names above
# and the application reads them by content.
export_staged() {
    local var="$1" path="$2"
    if [ -s "$path" ]; then
        export "$var=$path"
    else
        unset "$var" || true
    fi
}

export_staged MIADASH_ASSAY "$INPUT_DIR/assay.tsv"
export_staged MIADASH_COLDATA "$INPUT_DIR/coldata.tsv"
export_staged MIADASH_ROWDATA "$INPUT_DIR/rowdata.tsv"
export_staged MIADASH_ROWTREE "$INPUT_DIR/row.tree"

# One leading space from the label, so the log lines line up.
staged_report() {
    local var_value="$1" label="$2"
    if [ -n "$var_value" ]; then
        echo "$label $var_value ($(wc -c < "$var_value") bytes)"
    else
        echo "$label <not provided, upload in the browser>"
    fi
}

{
    echo "miaDash Galaxy Interactive Tool"
    echo "started:    $(date --iso-8601=seconds)"
    echo "port:       $PORT"
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
    staged_report "${MIADASH_ASSAY:-}" "abundance table:"
    staged_report "${MIADASH_COLDATA:-}" "sample data:    "
    staged_report "${MIADASH_ROWDATA:-}" "taxa data:      "
    staged_report "${MIADASH_ROWTREE:-}" "taxa tree:      "
    echo
    echo "R session:"
    Rscript --vanilla -e 'cat(paste(utils::capture.output(sessionInfo()), collapse = "\n"), "\n")'
} >> "$STARTUP_LOG" 2>&1

cat "$STARTUP_LOG"

# Test seam: stop once the inputs are staged and reported, before Shiny is
# started, so the test suite can exercise the input handling on its own. Set
# only by `make startup-test`.
if [ "${MIADASH_STARTUP_ONLY:-0}" = "1" ]; then
    exit 0
fi

# shiny::runApp() rather than shiny-server: shiny-server requires a fixed `run_as`
# user and writes to root-owned /var/log and /var/lib, neither of which works in
# a container that Galaxy starts as the job owner.
#
# The explicit host = "0.0.0.0" matters: runApp() binds to 127.0.0.1 unless told
# otherwise, which would make the app unreachable from outside the container, and
# Galaxy reaches the job container over a bridge IP rather than on its loopback.
# The port comes from $PORT, which the Dockerfile sets from ARG PORT and which
# has to match <port> in the tool XML.
#
# library(miaDash) before the call: miaDash() uses shiny's addResourcePath()
# unqualified and the NAMESPACE only imports stopApp, so it needs the package
# (and with it shiny, a Depends) attached - the way upstream documents it.
exec R --vanilla -q -e \
    "suppressPackageStartupMessages(library(miaDash)); shiny::runApp(miaDash::miaDash(), host = '0.0.0.0', port = ${PORT}, launch.browser = FALSE)"
