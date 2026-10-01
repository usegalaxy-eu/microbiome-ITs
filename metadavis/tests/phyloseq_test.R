#!/usr/bin/env Rscript
#
# Focused test for the phyloseq (OTU table + taxonomy table + metadata) input
# path. Deliberately does not source the app or start Shiny: it only exercises
# data_input_RA(), so a failure here points at the parser rather than at the UI.
#
# tests/data/metadata_table.tsv is the table the tool hands over: the sample ids
# and the grouping condition, nothing else (see the section at the end).
#
# Every expectation is derived from the fixtures on disk, so the test also works
# against a real dataset - point it at another directory to check one:
#
#   Rscript phyloseq_test.R [data_dir]
#
# The data-driven dataset shipped as Galaxy test data is the default. See
# tests/data for the small hand-written fixture with known values.

suppressPackageStartupMessages({
    library(tidyr)
    library(dplyr)
})

source(file.path("app", "scripts", "data_input.R"))

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

# --- what the fixtures actually contain, so the expectations follow the data --

otu_raw     <- read.delim(otu, header = TRUE, row.names = 1, check.names = FALSE)
tax_raw     <- read.delim(taxonomy, header = TRUE, row.names = 1, check.names = FALSE)
meta_raw    <- read.delim(metadata, header = TRUE, check.names = FALSE)
n_samples   <- ncol(otu_raw)
n_features  <- nrow(otu_raw)
sample_ids  <- colnames(otu_raw)
n_annotated <- length(intersect(rownames(otu_raw), rownames(tax_raw)))
unannotated_ids <- setdiff(rownames(otu_raw), rownames(tax_raw))
grand_total <- sum(as.matrix(otu_raw[, sample_ids]))

cat(sprintf("# %d features, %d samples, %d annotated, %d unannotated\n\n",
            n_features, n_samples, n_annotated, length(unannotated_ids)))

res <- run()

check("returns a 11-field list", length(res) == 11L)
check("sample count matches the OTU table", res$Number_of_samples == n_samples)
check("OTU matrix has one column per sample", ncol(res$Data_OTU) == n_samples)
check("sample names are the OTU columns", identical(colnames(res$Data_OTU), rownames(res$Data_Index1)))
check("sample names are the OTU column names", identical(colnames(res$Data_OTU), sample_ids))
check("taxonomy table is rendered", nrow(res$Tax_data) > 0L)
check("only samples and the condition are kept", {
    identical(colnames(res$Data_Index2), c("Samples", "Condition")) &&
        identical(colnames(res$Data_Index1), "Condition") &&
        nrow(res$Data_Index2) == n_samples
})
check("per-sample totals sum back to the input", {
    totals <- setNames(res$total_counts$Total_counts, res$total_counts$Samples)
    all(as.numeric(totals[sample_ids]) == as.numeric(colSums(otu_raw[, sample_ids])))
})
check("counts are preserved through the collapse", sum(res$Data_OTU) == grand_total)
check("no blank taxon names reach the output", all(nzchar(rownames(res$Data_OTU))))

check("features absent from the taxonomy table are kept but unclassified", {
    # These collapse to an empty name at every rank unless they are labelled:
    # the lineage back-filling only fills blanks from a *named* ancestor, and
    # there is none. An empty label is invisible in the taxonomy table and in
    # plot labels, so the parser labels them explicitly.
    if (!length(unannotated_ids)) {
        TRUE
    } else {
        expect <- sum(as.matrix(otu_raw[unannotated_ids, sample_ids]))
        "Unclassified" %in% rownames(res$Data_OTU) &&
            sum(res$Data_OTU["Unclassified", ]) == expect
    }
})

# Collapsing merges features that share a taxon, so the row count can only drop
# or stay equal, and no count may be lost on the way.
phylum <- run(type = 2L)
check("phylum level aggregates features", nrow(phylum$Data_OTU) <= nrow(res$Data_OTU))
check("phylum labels are unprefixed", all(!grepl("^[[:alpha:]]__", rownames(phylum$Data_OTU))))
check("phylum count is preserved", sum(phylum$Data_OTU) == grand_total)

for (level in c("1", "2", "3", "4", "5", "6", "7")) {
    r <- tryCatch(run(type = as.integer(level)), error = function(e) e)
    check(sprintf("level %s loads and preserves counts", level),
          !inherits(r, "error") && sum(r$Data_OTU) == grand_total)
}

# Features whose taxonomy is blank at a rank below the top have to fall back to
# their nearest named ancestor rather than disappear.
if (any(vapply(seq_len(nrow(tax_raw)), function(i) {
    all(nzchar(gsub("^[[:alpha:]]__", "", as.character(tax_raw[i, ])))) == FALSE
}, logical(1)))) {
    species <- run(type = 7L)
    check("partially annotated features survive at species level",
          all(nzchar(rownames(species$Data_OTU))))
}

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
    header <- paste(c("SampleID", "Condition", paste0("X", seq_len(n_samples))), collapse = "\t")
    body <- paste0("X", seq_len(n_samples), "\tGroup")
    writeLines(c(header, body), bad)
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

check("metadata without an annotation column is reported", {
    bad <- file.path(tempdir(), "one_column_metadata.tsv")
    writeLines(c("SampleID", sample_ids), bad)
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
    grepl("sample column plus at least one annotation column", msg, fixed = TRUE)
})

# --- the metadata table the tool hands over ---------------------------------
# Which of the annotation columns is the grouping condition is decided by the
# tool form (a data_column param), and the tool's <command> reduces the staged
# table to the sample ids plus that column before the container is started. The
# parser therefore only ever sees two columns - and that is not an accident.
# Handed a wider table it does not fail, it quietly keeps the sample ids and the
# second column and throws the rest away, which is exactly the surprise the
# reduction in the tool exists to prevent.

trimmer <- Sys.getenv("METADAVIS_TRIMMER", "/docker/trim_metadata.py")
have_trimmer <- nzchar(trimmer) && file.exists(trimmer)

wide <- file.path(tempdir(), "wide_metadata.tsv")
write.table(
    cbind(
        meta_raw[, 1:2, drop = FALSE],
        as.data.frame(list(
            Site = rep(c("Colonoscopy", "Clinic"), length.out = n_samples),
            stringsAsFactors = FALSE
        ))
    ),
    wide, sep = "\t", row.names = FALSE, quote = FALSE
)

if (!have_trimmer) {
    cat(sprintf("skip  the trimming integration checks (%s is not mounted)\n", trimmer))
} else {
    trimmed <- file.path(tempdir(), "trimmed_metadata.tsv")
    status <- system2(
        "python3",
        c(shQuote(trimmer), shQuote(wide), shQuote("Site"), shQuote(trimmed)),
        stdout = FALSE, stderr = FALSE
    )

    check("the tool reduces the wide table", status == 0L && file.exists(trimmed))
    check("what the parser receives has two columns", {
        reduced <- read.delim(trimmed, header = TRUE, check.names = FALSE)
        identical(colnames(reduced), c("SampleID", "Site"))
    })

    out <- data_input_RA(
        file_type = "phyloseq",
        Input = otu,
        Taxonomy = taxonomy,
        Index = trimmed,
        type = 4L,
        show_head = FALSE
    )

    check("the trimmed table is what the analysis runs on", {
        identical(colnames(out$Data_Index2), c("Samples", "Condition")) &&
            identical(colnames(out$Data_Index1), "Condition") &&
            out$Number_of_samples == n_samples &&
            setequal(out$Data_Index3[[1]], c("Colonoscopy", "Clinic"))
    })
    check("the sample ids are untouched by the reduction", {
        identical(sort(rownames(out$Data_Index1)), sort(sample_ids))
    })
    check("and the reduction is what makes the chosen column the condition", {
        # Same table, same parser: read as it was staged the parser would have
        # used the second column, which is what the check above shows.
        reduced <- read.delim(trimmed, header = TRUE, check.names = FALSE)
        setequal(reduced[[2]], rep(c("Colonoscopy", "Clinic"), length.out = n_samples))
    })
}

check("a wider metadata table would be read as its second column only", {
    # What the tool's reduction is up against: handed a wide table the parser
    # keeps the sample ids and the second column, names the leftover column NA
    # and never looks at the condition the user picked in the tool form.
    out <- data_input_RA(
        file_type = "phyloseq",
        Input = otu,
        Taxonomy = taxonomy,
        Index = wide,
        type = 4L,
        show_head = FALSE
    )
    setequal(out$Data_Index3[[1]], unique(meta_raw[[2]])) &&
        out$Number_of_samples == n_samples
})


cat("\n")
if (failures) {
    cat(failures, " check(s) failed\n", sep = "")
    quit(status = 1L)
}
cat("all phyloseq parser checks passed\n")