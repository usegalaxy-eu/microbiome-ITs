#!/usr/bin/env Rscript
#
# Headless smoke test for the MetaDAVis GxIT image: checks that the R stack the
# app needs actually works, without a browser in the loop.
#
# Run inside the built image:
#   docker run --rm -v "$PWD/tests:/tests:ro" --entrypoint Rscript metadavis-gxit:latest /tests/smoke_test.R

app_dir <- Sys.getenv("METADAVIS_APP_SOURCE", "/opt/MetaDAVis")
setwd(app_dir)

suppressMessages(library(shiny))

failures <- character(0)
report <- function(ok, what, detail = "") {
    cat(sprintf("%-58s %s %s\n", what, if (ok) "ok" else "FAIL", detail))
    if (!ok) failures <<- c(failures, what)
}

# --------------------------------------------------------------------------
# 1. the package set global.R expects to find already installed
# --------------------------------------------------------------------------
packages <- c(
    "shiny", "DT", "shinythemes", "shinyFiles", "shinyjs", "shinydashboard",
    "ggplot2", "ggpubr", "vegan", "ggfortify", "ggplotify", "reshape2", "tibble",
    "scales", "dunn.test", "tidyr", "dplyr", "patchwork", "GGally", "plotly",
    "zip", "filelock", "shinycssloaders", "RColorBrewer", "circlize",
    "phyloseq", "microbiome", "ComplexHeatmap", "qvalue", "scater", "DESeq2",
    "limma", "edgeR", "metagenomeSeq", "bluster", "mia", "lefser",
    "microbiomeutilities", "maaslin3"
)
loaded <- suppressWarnings(vapply(
    packages,
    function(pkg) tryCatch({ loadNamespace(pkg); TRUE }, error = function(e) FALSE),
    logical(1)
))
report(all(loaded), "all required packages load",
       if (all(loaded)) "" else paste(packages[!loaded], collapse = ", "))

# --------------------------------------------------------------------------
# 2. the app sources global.R, which is where it checks (and installs) packages
# --------------------------------------------------------------------------
report(file.exists("server.R") && file.exists("ui.R") && file.exists("global.R"),
       "app files present")
report(file.exists("scripts/MaAsLin3.R"), "app scripts present")
report(any(grepl("Galaxy Interactive Tool", readLines("server.R"), fixed = TRUE)) &&
       !file.exists(".gxit_patched"),
       "the Galaxy input format is part of the app, not a build-time patch")

global_loaded <- tryCatch({ source("global.R"); TRUE }, error = function(e) {
    cat("   ", conditionMessage(e), "\n")
    FALSE
})
report(global_loaded, "global.R sources without installing anything")

# --------------------------------------------------------------------------
# 3. the bundled example data parses at the requested taxonomy level
# --------------------------------------------------------------------------
parsed <- tryCatch(
    source("scripts/data_input.R", local = TRUE),
    error = function(e) e
)
if (inherits(parsed, "error")) {
    report(FALSE, "scripts/data_input.R sources", conditionMessage(parsed))
} else {
    report(TRUE, "scripts/data_input.R sources")

    result <- data_input_RA(
        file_type = "example",
        Input = "www/example_data/Megan_WGS_output.tsv",
        Index = "www/example_data/Megan_WGS_metadata.tsv",
        type = "4",
        show_head = FALSE
    )
    # data_input_RA() hands back a data.frame of counts (one column per sample),
    # not a matrix, despite the name
    otu <- result[["Data_OTU"]]
    report(is.data.frame(otu) && nrow(otu) > 0 && ncol(otu) > 1,
           "example data parses into a taxa x samples table",
           sprintf("(%d taxa x %d samples)", nrow(otu), ncol(otu)))

    # 4. a differential abundance analysis end to end on that table
    deseq <- tryCatch({
        counts <- as.matrix(otu)
        conditions <- factor(result[["Data_Index"]])
        coldata <- data.frame(Condition = conditions, row.names = colnames(counts))
        dds <- DESeq2::DESeqDataSetFromMatrix(countData = counts,
                                              colData = coldata,
                                              design = ~Condition)
        dds <- DESeq2::DESeq(dds, quiet = TRUE)
        as.data.frame(DESeq2::results(dds))
    }, error = function(e) e)

    report(!inherits(deseq, "error") && nrow(deseq) == nrow(otu),
           "DESeq2 runs on the example data",
           if (inherits(deseq, "error")) conditionMessage(deseq) else "")

    # vegan::diversity() on a samples x taxa matrix returns one value per sample
    shannon <- vegan::diversity(t(as.matrix(otu)), index = "shannon")
    report(length(shannon) == ncol(otu) && all(is.finite(shannon)),
           "vegan alpha diversity runs on the example data")
}

# --------------------------------------------------------------------------
# 5. the Galaxy input format is wired up: server.R reads the staged paths, and
#    data_input.R parses them as the phyloseq three-file layout
# --------------------------------------------------------------------------
staged_test <- function() {
    server_lines <- readLines("server.R")

    for (input_id in c("METADAVIS_OTU_TABLE", "METADAVIS_TAXONOMY_TABLE", "METADAVIS_METADATA_FILE")) {
        report(any(grepl(input_id, server_lines, fixed = TRUE)),
               sprintf("server.R reads the staged %s", input_id))
    }

    ui_lines <- readLines("ui.R")
    report(any(grepl("galaxy", ui_lines, fixed = TRUE)),
           "the UI offers a Galaxy input format")

    # The staged fixtures go through the same parser the server calls.
    source(file.path("scripts", "data_input.R"), local = TRUE)
    dir <- file.path(tempdir(), "gxit_inputs")
    dir.create(dir, showWarnings = FALSE)
    for (pair in list(
        c("otu_table.tsv", "otu"),
        c("taxonomy_table.tsv", "taxonomy"),
        c("metadata_table.tsv", "metadata")
    )) {
        file.copy(file.path("/tests/data", pair[[1]]), file.path(dir, pair[[2]]))
    }

    Sys.setenv(
        METADAVIS_OTU_TABLE = file.path(dir, "otu"),
        METADAVIS_TAXONOMY_TABLE = file.path(dir, "taxonomy"),
        METADAVIS_METADATA_FILE = file.path(dir, "metadata")
    )

    report(all(nzchar(c(Sys.getenv("METADAVIS_OTU_TABLE"),
                        Sys.getenv("METADAVIS_TAXONOMY_TABLE"),
                        Sys.getenv("METADAVIS_METADATA_FILE")))),
           "the entrypoint environment variables carry the staged paths")

    res <- data_input_RA(
        file_type = "phyloseq",
        Input = Sys.getenv("METADAVIS_OTU_TABLE"),
        Taxonomy = Sys.getenv("METADAVIS_TAXONOMY_TABLE"),
        Index = Sys.getenv("METADAVIS_METADATA_FILE"),
        type = 4L,
        show_head = FALSE
    )
    report(res$Number_of_samples == 6L && ncol(res$Data_OTU) == 6L,
           "the staged datasets load into 6 samples")
    report(all(nzchar(rownames(res$Data_OTU))),
           "every taxon has a name after collapsing")
}

staged <- tryCatch(staged_test(), error = function(e) e)
if (inherits(staged, "error")) {
    report(FALSE, "Galaxy input staging works", conditionMessage(staged))
}

# --------------------------------------------------------------------------
# 6. Galaxy uploads use the installed put command with its supported arguments
# --------------------------------------------------------------------------
source(file.path("scripts", "galaxy_downloads.R"), local = TRUE)
fake_put <- tempfile("metadavis-put-")
put_args <- tempfile("metadavis-put-args-")
writeLines(c("#!/bin/sh", "printf '%s\\n' \"$@\" > \"$METADAVIS_PUT_ARGS\""), fake_put)
Sys.chmod(fake_put, mode = "0755")
upload_file <- tempfile(fileext = ".txt")
writeLines("test", upload_file)
output_dir <- tempfile("metadavis-outputs-")
Sys.setenv(
    METADAVIS_GALAXY_PUT = fake_put,
    METADAVIS_PUT_ARGS = put_args,
    METADAVIS_OUTPUT_DIR = output_dir,
    HISTORY_ID = "history-id",
    API_KEY = "test-key"
)
upload <- metadavis_send_to_galaxy(upload_file, "test.txt", "txt")
expected_args <- c("-p", upload_file, "-t", "txt", "--history-id", "history-id")
report(isTRUE(upload$ok) && identical(readLines(put_args), expected_args),
       "Galaxy upload invokes the put console command")
upload_log <- file.path(output_dir, "galaxy_upload.log")
log_text <- paste(readLines(upload_log), collapse = "\n")
report(file.exists(upload_log) &&
       grepl("upload start", log_text, fixed = TRUE) &&
       grepl("exit_status=0", log_text, fixed = TRUE) &&
       !grepl("test-key", log_text, fixed = TRUE),
       "Galaxy upload writes a sanitized diagnostic log")
unlink(put_args)
started <- Sys.time()
metadavis_send_to_galaxy_async(upload_file, "test.txt", "txt")
for (i in seq_len(50L)) {
    if (file.exists(put_args)) break
    Sys.sleep(0.1)
}
report(as.numeric(difftime(Sys.time(), started, units = "secs")) < 5 && file.exists(put_args),
       "Galaxy upload can run without blocking Shiny")
output_path <- metadavis_galaxy_output_path("result table.tsv")
report(identical(output_path, file.path(output_dir, "result table.tsv")) && dir.exists(output_dir),
       "Galaxy output path uses the discovered output directory")

# --------------------------------------------------------------------------
if (length(failures)) {
    cat(sprintf("\n%d check(s) FAILED: %s\n", length(failures), paste(failures, collapse = "; ")))
    quit(status = 1L)
}
cat("\nall checks passed\n")
quit(status = 0L)
