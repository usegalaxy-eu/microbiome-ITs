#!/usr/bin/env Rscript
#
# Focused test for the phyloseq (OTU table + taxonomy table + metadata) input
# path. Deliberately does not source the app or start Shiny: it only exercises
# data_input_RA(), so a failure here points at the parser rather than at the UI.
#
# Usage: Rscript phyloseq_test.R [data_dir]

suppressPackageStartupMessages({
    library(tidyr)
    library(dplyr)
})

data_dir <- if (length(commandArgs(trailingOnly = TRUE)) >= 1L) {
    commandArgs(trailingOnly = TRUE)[[1]]
} else {
    file.path("tests", "data")
}

otu      <- file.path(data_dir, "otu_table.tsv")
taxonomy <- file.path(data_dir, "taxonomy_table.tsv")
metadata <- file.path(data_dir, "metadata_table.tsv")

for (f in c(otu, taxonomy, metadata)) {
    if (!file.exists(f)) stop("missing fixture: ", f)
}

source(file.path("app", "scripts", "data_input.R"))

failures <- 0L
check <- function(label, condition) {
    if (isTRUE(condition)) {
        cat("ok    ", label, "\n", sep = "")
    } else {
        cat("FAIL  ", label, "\n", sep = "")
        failures <<- failures + 1L
    }
}

run <- function(type = 4L) {
    data_input_RA(
        file_type = "phyloseq",
        Input = otu,
        Taxonomy = taxonomy,
        Index = metadata,
        type = type,
        show_head = FALSE
    )
}

res <- run()

check("returns a 11-field list", length(res) == 11L)
check("6 samples found", res$Number_of_samples == 6L)
check("OTU matrix has 6 sample columns", ncol(res$Data_OTU) == 6L)
check("sample names are the OTU columns", identical(colnames(res$Data_OTU), rownames(res$Data_Index1)))
check("taxonomy table is rendered", nrow(res$Tax_data) > 0L)
check("metadata keeps all annotation columns", ncol(res$Data_Index2) == 3L)
check("per-sample totals sum back to the input", {
    totals <- setNames(res$total_counts$Total_counts, res$total_counts$Samples)
    as.numeric(totals["S1"]) == 120 + 60 + 300 + 45 + 0 + 210 + 75 + 155 + 22
})
check("features absent from the taxonomy table are kept but unclassified", {
    # OTU9 has no taxonomy row at all. It must survive the collapse under an
    # explicit label rather than as a blank name, which would be invisible in
    # the taxonomy table and in plot labels.
    names(res$Data_OTU)[res$Data_OTU["Unclassified", ] > 0] %in% "Unclassified"
    sum(res$Data_OTU["Unclassified", ]) == 22 + 18 + 2 + 1 + 25 + 20
})
check("no blank taxon names reach the output", {
    all(nzchar(rownames(res$Data_OTU)))
})

# Collapsing to Phylum must merge the two Proteobacteria features and the three
# Firmicutes ones, so fewer rows than features remain.
phylum <- run(type = 2L)
check("phylum level aggregates features", nrow(phylum$Data_OTU) < nrow(res$Data_OTU))
check("phylum labels are unprefixed", all(!grepl("^p__", rownames(phylum$Data_OTU))))
check("phylum count is preserved", sum(phylum$Data_OTU) == sum(res$Data_OTU))

species <- run(type = 7L)
# OTU7 has an empty Species cell, so it has to fall back to its genus name
# ("Lactobacillus") rather than dropping out of the table entirely.
check("missing species falls back to the genus", "Lactobacillus" %in% rownames(species$Data_OTU))

check("separator is detected, not required", {
    comma_dir <- file.path(tempdir(), "comma")
    dir.create(comma_dir, showWarnings = FALSE)
    for (pair in list(
        c(otu, "otu.csv"), c(taxonomy, "taxonomy.csv"), c(metadata, "metadata.csv")
    )) {
        writeLines(
            gsub("\t", ",", readLines(pair[[1]], warn = FALSE)),
            file.path(comma_dir, pair[[2]])
        )
    }
    res_csv <- data_input_RA(
        file_type = "phyloseq",
        Input = file.path(comma_dir, "otu.csv"),
        Taxonomy = file.path(comma_dir, "taxonomy.csv"),
        Index = file.path(comma_dir, "metadata.csv"),
        type = 4L,
        show_head = FALSE
    )
    identical(dim(res_csv$Data_OTU), dim(res$Data_OTU))
})

check("mismatched sample names are reported", {
    bad <- file.path(tempdir(), "bad_metadata.tsv")
    writeLines(
        c("SampleID\tCondition", "X1\tHealthy", "X2\tDisease"),
        bad
    )
    msg <- tryCatch(
        {
            data_input_RA(
                file_type = "phyloseq",
                Input = otu,
                Taxonomy = taxonomy,
                Index = bad,
                type = 4L,
                show_head = FALSE
            )
            ""
        },
        error = function(e) conditionMessage(e)
    )
    grepl("OTU table but not in the metadata", msg, fixed = TRUE)
})

check("a missing taxonomy table is reported", {
    msg <- tryCatch(
        {
            data_input_RA(
                file_type = "phyloseq",
                Input = otu,
                Index = metadata,
                type = 4L,
                show_head = FALSE
            )
            ""
        },
        error = function(e) conditionMessage(e)
    )
    grepl("needs an OTU table, a taxonomy table and a metadata table", msg, fixed = TRUE)
})

cat("\n")
if (failures) {
    cat(failures, " check(s) failed\n", sep = "")
    quit(status = 1L)
}
cat("all phyloseq parser checks passed\n")