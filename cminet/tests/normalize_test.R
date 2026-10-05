#!/usr/bin/env Rscript
#
# Input handling of the container entry point.
#
# The tool declares format="tabular,csv" and copies the Galaxy dataset into the
# job unchanged, but the application reads every table with read.csv(), which only
# ever splits on commas. A tab-separated file therefore arrives as one field per
# row: a 2 x 0 matrix with no taxa, and the analysis runs on nothing instead of
# complaining. The entry point re-separates anything that is not already comma
# separated, and this is what holds that conversion to account.
#
# The real entry point is exercised with CMINET_NORMALIZE_ONLY set, which stops
# before Shiny is started. Each case is read back through the path the entry point
# hands the application, which is what makes this a test of the input handling
# rather than of a helper:
#   docker run --rm -v "$PWD/tests:/tests:ro" cminet-gxit:latest \
#       /tests/normalize_test.R /usr/local/bin/cminet-entrypoint

args <- commandArgs(trailingOnly = TRUE)
entrypoint <- if (length(args) >= 1) args[[1]] else "/usr/local/bin/cminet-entrypoint"

failures <- 0L
ok <- function(label, condition) {
    if (isTRUE(condition)) {
        cat(sprintf("PASS - %s\n", label))
    } else {
        cat(sprintf("FAIL - %s\n", label))
        failures <<- failures + 1L
    }
}

cat(sprintf("== staged input normalisation (entry point: %s)\n", entrypoint))

# Stage a file the way the tool's <command> does, run the entry point, and hand
# back the path the entry point tells the application to read. The entry point
# picks the converted copy when it made one, so that is what has to be read back.
run_entrypoint <- function(name, content, input = "abundance") {
    job <- file.path(tempdir(), paste0("cminet-job-", name))
    unlink(job, recursive = TRUE)
    dir.create(file.path(job, "cminet_inputs"), recursive = TRUE)
    writeLines(content, file.path(job, "cminet_inputs", input))
    # Run the entry point and read back which file it resolved for the application.
    # That path comes from the startup log's "abundance matrix:" line, which the
    # entry point prints from the very env var the application is given - so the
    # test asserts on the real hand-off rather than on a guess about which of the
    # two files on disk is meant to be used.
    # The colon matters: the conversion notice above is "abundance: ..." and would
    # otherwise match a looser pattern.
    label <- if (input == "abundance") "abundance matrix:" else "weighted network:"
    log <- system2("bash", c(shQuote(entrypoint)),
                   env = c(sprintf("CMINET_JOB_DIR=%s", shQuote(job)),
                           "CMINET_NORMALIZE_ONLY=1"),
                   stdout = TRUE, stderr = FALSE)
    # "abundance matrix:  /some/path (55 bytes)". The log lines the path for humans
    # and pad it to line up with the weighted network below it, so the leading
    # whitespace is dropped rather than matched exactly.
    line <- grep(sprintf("^%s ", label), log, value = TRUE)
    if (!length(line)) return("")
    hit <- sub(sprintf("^%s +", label), "", line[[1]])
    hit <- sub(" \\([0-9]+ bytes\\)$", "", hit)
    if (!nzchar(hit)) return("")
    hit
}

# What the application sees, which is the only thing that actually matters.
as_app_reads <- function(path) {
    df <- tryCatch(utils::read.csv(path, row.names = 1, check.names = FALSE),
                   error = function(e) NULL, warning = function(w) NULL)
    if (is.null(df) || ncol(df) == 0L) return(NULL)
    as.character(as.matrix(df))
}

# The values as they were written, read with the delimiter they were written in.
as_written <- function(content, sep) {
    tmp <- tempfile()
    on.exit(unlink(tmp))
    writeLines(content, tmp)
    df <- utils::read.table(tmp, header = TRUE, sep = sep, quote = "",
                            colClasses = "character", check.names = FALSE,
                            comment.char = "", stringsAsFactors = FALSE)
    as.character(sub("\r$", "", as.matrix(df[, -1, drop = FALSE])))
}

check_lossless <- function(name, content, sep) {
    staged <- run_entrypoint(name, content)
    got <- as_app_reads(staged)
    ok(sprintf("%s survives conversion unchanged", name),
       !is.null(got) && identical(got, as_written(content, sep)))
    invisible(staged)
}

cat("\n== a tab separated dataset, the case that used to break\n")
check_lossless("tab",
               c("Sample\tA\tB\tC", "s1\t5\t3\t9", "s2\t7\t2\t8"),
               "\t")

cat("\n== other separators and awkward bytes\n")
check_lossless("semicolon", c("Sample;A;B", "s1;5;3", "s2;7;2"), ";")
check_lossless("windows line endings", c("Sample\tA\tB", "s1\t1\t2", "s2\t3\t4"), "\t")
check_lossless("a value containing a comma", c("Sample\tA\tB", "s1\t1,5\t2"), "\t")
check_lossless("a value containing a quote", c("Sample\tA\tB", "s1\t\"he said \"\"hi\"\"\"\t2"), "\t")

cat("\n== the abundance matrix really is a matrix afterwards\n")
tabbed <- run_entrypoint("shape", c("Sample\tA\tB\tC", "s1\t5\t3\t9", "s2\t7\t2\t8"))
shape <- tryCatch(utils::read.csv(tabbed, row.names = 1, check.names = FALSE),
                  error = function(e) NULL)
ok("the samples are in the rows, one column per taxon", !is.null(shape) && nrow(shape) == 2L && ncol(shape) == 3L)
ok("the sample ids are kept", !is.null(shape) && identical(rownames(shape), c("s1", "s2")))
ok("the taxon names are kept", !is.null(shape) && identical(colnames(shape), c("A", "B", "C")))
ok("the values are numeric, so the app can shift them",
   !is.null(shape) && is.numeric(as.matrix(shape + 0.0001)))

cat("\n== input that is already comma separated is left alone\n")
original <- c("Sample,A,B", "s1,5,3")
staged <- run_entrypoint("already-csv", original)
ok("a CSV dataset is handed over as the original file, not a converted copy",
   identical(basename(staged), "abundance"))
ok("a CSV dataset is not rewritten",
   identical(readLines(staged), original))
ok("a CSV dataset still reads as a matrix", !is.null(as_app_reads(staged)))

cat("\n== a file the app could not use is handed over rather than mangled\n")
ragged <- c("Sample\tA\tB", "s1\t1", "s2\t7\t2\t9")
staged <- run_entrypoint("ragged", ragged)
ok("a ragged table is handed over as the original file",
   identical(basename(staged), "abundance"))
ok("a ragged table is passed through byte for byte",
   identical(readLines(staged), ragged))

single <- c("only", "1", "2")
staged <- run_entrypoint("single-column", single)
ok("a single column file is passed through byte for byte",
   identical(readLines(staged), single))

cat("\n== the weighted network is normalised the same way\n")
staged <- run_entrypoint("network", c("A\tB\tC", "x\t1\t2"), input = "weighted_network")
ok("a tab separated weighted network is converted",
   !is.null(as_app_reads(staged)))

cat(sprintf("\n%d failed check(s)\n", failures))
quit(status = if (failures > 0L) 1L else 0L)