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

# Truncated here, then appended to below, because the input normalization runs
# before the log is assembled and has somewhere to say what it did.
: > "$STARTUP_LOG"

# The application reads every table with read.csv(), which always splits on commas
# and never guesses. The tool, however, declares format="tabular,csv" and copies
# the Galaxy dataset in unchanged, so a tab- or semicolon-separated file arrives
# intact and read.csv() folds each row into a single field: a 2x0 matrix with no
# taxa columns, and the analysis then runs on nothing instead of complaining.
# Rewrite anything that is not already comma-separated, here, before the app is
# started.
#
# Comma-separated input is returned untouched rather than round-tripped, so the
# path that every existing test and every CSV user exercises cannot change. A file
# that cannot be read as one rectangular table is also left alone: the app then
# behaves exactly as it did before, which is no worse than the input we were given.
#
# The converted file is written next to the original rather than over it, and
# export_path below prefers it. Overwriting in place fails when the staged file
# cannot be written to - a read-only mount, or a dataset staged outside the job
# directory - and the tool would then silently fall back to the unconverted file,
# which is the bug this whole function exists to fix.
#
# The write can still fail when the whole input directory is read-only. There is
# nowhere else to put it that the application would find, so that is reported and
# the unconverted file is used, exactly as before this function existed.
normalize_to_csv() {
    local path="$1" label="$2" script status
    [ -s "$path" ] || return 0
    script="$(mktemp)"
    cat > "$script" <<'NORMALIZE_R'
args <- commandArgs(trailingOnly = TRUE)
path <- args[[1]]
if (is.na(path) || !file.exists(path)) quit(status = 3L)

count_ch <- function(s, ch) {
    m <- gregexpr(ch, s, fixed = TRUE)[[1]]
    if (length(m) == 0L || m[[1]] == -1L) 0L else length(m)
}

# Sniff the first line only: taxon and sample names may legitimately contain the
# other characters, but the header tells us how the columns are separated.
header <- readLines(path, n = 1L, warn = FALSE)
if (length(header) != 1L) quit(status = 3L)
header <- sub("\r$", "", header)

counts <- c(comma = count_ch(header, ","),
            tab   = count_ch(header, "\t"),
            semi  = count_ch(header, ";"))
sep <- names(counts)[which.max(counts)]
# which.max breaks ties towards "comma", so a header that looks like both is left
# as it is rather than being converted on a guess.
if (is.na(sep) || counts[[sep]] < 1L || sep == "comma") quit(status = 0L)
# read.table's sep= wants a single byte, and "tab" from counts above is not one.
sep_ch <- switch(sep, tab = "\t", semi = ";")
# separators in the header, so the header carries one more field than that.
n_cols <- counts[[sep]] + 1L

# Everything as text, and with quoting switched off: this re-separates a file, it
# does not parse one, so every byte has to survive as data. Reading with quote=""
# is what keeps a taxon name containing a double quote intact instead of having
# read.table helpfully unescape it.
df <- tryCatch(
    utils::read.table(path, header = TRUE, sep = sep_ch, quote = "",
                      colClasses = "character", check.names = FALSE,
                      comment.char = "", stringsAsFactors = FALSE),
    error = function(e) NULL
)
# A header that is shorter than the data makes read.table swallow the first column
# as row names. Bail rather than write a table with a column missing.
if (is.null(df) || length(df) != n_cols) quit(status = 3L)

# Written beside the input, not over it, and reported by name so the caller can
# point the application at it. 4 is the exit code for "fine, just not mine".
out <- paste0(path, ".csv")
written <- tryCatch({
    # qmethod="double" rather than R's default "escape": the default emits
    # backslash quoting, which is not CSV as anyone else reads it.
    utils::write.table(df, out, sep = ",", row.names = FALSE, quote = TRUE,
                       qmethod = "double")
    TRUE
}, error = function(e) FALSE)
if (!written) {
    unlink(out)
    quit(status = 3L)
}

cat(sprintf("%s: %d %s-separated column(s) in the header, converted to %s\n",
            basename(path), n_cols, if (sep == "tab") "tab" else "semicolon",
            basename(out)))
quit(status = 4L)
NORMALIZE_R
    status=0
    Rscript --vanilla "$script" "$path" >> "$STARTUP_LOG" 2>&1 || status=$?
    rm -f "$script"
    case "$status" in
        0) rm -f "$path.csv" ;;
        4) : ;;
        3) echo "$label: could not be converted (read error, or not a single rectangular table), handed to the app unchanged - a tab separated dataset will not be readable by the app" >> "$STARTUP_LOG" ;;
        *) echo "$label: CSV conversion failed (Rscript exit $status), handed to the app unchanged" >> "$STARTUP_LOG" ;;
    esac
    return 0
}

normalize_to_csv "$INPUT_DIR/abundance" "abundance matrix:"
normalize_to_csv "$INPUT_DIR/weighted_network" "weighted network:"

# One leading space from the label, so the log lines line up. The path is
# reported here so that it is obvious which copy the application is reading when
# normalize_to_csv has produced one.
staged_report() {
    local path="$1" label="$2"
    if [ -s "$path" ]; then
        echo "$label $path ($(wc -c < "$path") bytes)"
    else
        echo "$label <not provided, upload in the browser>"
    fi
}

# Point the application at the converted copy if normalize_to_csv produced one,
# otherwise at the dataset as it was staged. Galaxy datasets have no meaningful
# file extension, so the staged copies keep the plain names above and the
# application reads them by content.
# Only export the datasets that were actually staged. The abundance matrix is the
# only required input; a Galaxy job may carry none of them, and the application
# falls back to the browser upload or its own example data in that case.
export_path() {
    local var="$1" converted="$2" path="$3"
    if [ -s "$converted" ]; then
        export "$var=$converted"
    elif [ -s "$path" ]; then
        export "$var=$path"
    else
        unset "$var" || true
    fi
}

export_path CMINET_INPUT "$INPUT_DIR/abundance.csv" "$INPUT_DIR/abundance"
export_path CMINET_WEIGHTED_NETWORK "$INPUT_DIR/weighted_network.csv" "$INPUT_DIR/weighted_network"

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
    staged_report "${CMINET_INPUT:-$INPUT_DIR/abundance}" "abundance matrix: "
    staged_report "${CMINET_WEIGHTED_NETWORK:-$INPUT_DIR/weighted_network}" "weighted network:  "
    echo
    echo "R session:"
    Rscript --vanilla -e 'cat(paste(utils::capture.output(sessionInfo()), collapse = "\n"), "\n")'
} >> "$STARTUP_LOG" 2>&1

cat "$STARTUP_LOG"

# Test seam: stop once the inputs are staged, normalised and reported, before the
# app is copied and Shiny is started, so the test suite can exercise the input
# handling on its own. Set only by tests/normalize_test.R.
if [ "${CMINET_NORMALIZE_ONLY:-0}" = "1" ]; then
    exit 0
fi

mkdir -p "$APP_DIR"
cp -a "$APP_SOURCE/." "$APP_DIR/"

cd "$APP_DIR"

# shiny::runApp() rather than shiny-server: shiny-server requires a fixed `run_as`
# user and writes to root-owned /var/log and /var/lib, neither of which works in
# a container that Galaxy starts as the job owner.
exec Rscript --vanilla -e \
    "shiny::runApp('$APP_DIR', host = '0.0.0.0', port = $PORT, launch.browser = FALSE, quiet = FALSE)"