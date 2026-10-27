#!/usr/bin/env Rscript
#
# Headless checks for the miaDash container: the R stack the app needs, the app
# object itself, the Galaxy wiring from the fork's galaxy-it-adaptations
# branch, and the staged-input import the tool XML drives.
#
# This deliberately does not start Shiny. `make check` covers that, and doing it
# here would make every quick feedback loop take a minute.
#
#   docker run --rm -v "$PWD/tests:/tests:ro" --entrypoint Rscript \
#       miadash-gxit:latest --vanilla /tests/smoke_test.R

failures <- 0L
ok <- function(label, condition) {
    if (isTRUE(condition)) {
        cat(sprintf("PASS - %s\n", label))
    } else {
        cat(sprintf("FAIL - %s\n", label))
        failures <<- failures + 1L
    }
}

fixtures <- "/tests/fixtures"

cat("== R stack\n")
cat(sprintf("   R %s.%s\n", R.version$major, R.version$minor))

# The Bioconductor and CRAN dependencies of miaDash (DESCRIPTION Depends +
# Imports), plus the package itself. A missing or unloadable package here is
# what turns into a blank panel in an interactive session, so it is worth
# failing the build for.
app_libraries <- c(
    "iSEE", "iSEEtree", "mia", "bluster", "scater", "scuttle", "S4Vectors",
    "SingleCellExperiment", "SummarizedExperiment", "TreeSummarizedExperiment",
    # not a Depends/Imports of miaDash, but the app's transform dropdown
    # offers it unconditionally (see docker/install.R)
    "philr",
    "ape", "rbiom", "rintrojs", "shinyAce", "shinydashboard", "shinyjs",
    "shinyWidgets", "vegan", "shiny", "htmltools",
    "miaDash"
)
for (pkg in app_libraries) {
    version <- tryCatch({
        loadNamespace(pkg)
        as.character(utils::packageVersion(pkg))
    }, error = function(e) {
        cat(sprintf("   %-26s BROKEN: %s\n", pkg, conditionMessage(e)))
        NA_character_
    })
    ok(sprintf("%s loads", pkg), !is.na(version))
    if (!is.na(version)) {
        cat(sprintf("   %-26s %s\n", pkg, version))
    }
}

# The floor that the Bioconductor 3.23 base image exists for: miaDash's
# DESCRIPTION requires iSEE >= 2.19.4, and an older iSEE would surface only as
# a broken export modal in a user's session.
if ("iSEE" %in% app_libraries && requireNamespace("iSEE", quietly = TRUE)) {
    ok("iSEE >= 2.19.4",
       utils::packageVersion("iSEE") >= "2.19.4")
}

cat("\n== app object\n")
# Attached first, like upstream's documented usage: miaDash() calls shiny's
# addResourcePath() unqualified and the NAMESPACE only imports stopApp, so the
# call only works with the package (and shiny, a Depends) attached.
suppressPackageStartupMessages(library(miaDash))
app <- tryCatch(suppressMessages(miaDash::miaDash()), error = function(e) e)
ok("miaDash::miaDash() runs", !inherits(app, "error"))
if (inherits(app, "error")) {
    cat(sprintf("   %s\n", conditionMessage(app)))
} else {
    ok("it returns a shiny app", inherits(app, "shiny.appobj"))
    ok("it has a request handler", length(app$httpHandler) > 0)
}
ok("the packaged logo is installed",
   file.exists(file.path(find.package("miaDash"), "assets", "mia_logo.png")))

cat("\n== Galaxy integration (the fork's galaxy-it-adaptations branch)\n")
ns <- asNamespace("miaDash")
for (helper in c("galaxy_ie_app", "galaxy_ie_send_ui", "galaxy_ie_send_js",
                 "galaxy_ie_send_server", "galaxy_ie_download_with",
                 "galaxy_ie_isee_export_id", "galaxy_ie_session_handler",
                 "galaxy_ie_log_dir", "galaxy_ie_expand_archive",
                 "galaxy_staged_paths",
                 "galaxy_staged_active", ".galaxy_staged_import")) {
    ok(sprintf("%s is part of the package", helper),
       exists(helper, envir = ns, inherits = FALSE))
}

send_js <- get("galaxy_ie_send_js", envir = ns)
ok("the injection script targets shiny download links",
   grepl("shiny-download-link", send_js(), fixed = TRUE))
ok("the injection script is namespaced for this app",
   grepl("miadash_galaxy_send", send_js(), fixed = TRUE))
ok("the injection script keeps watching for new links",
   grepl("MutationObserver", send_js(), fixed = TRUE))
ok("the sprintf placeholders were substituted",
   !grepl("%1$s", send_js(), fixed = TRUE) && !grepl("%2$s", send_js(), fixed = TRUE))

# An allow-list means iSEE's own internal download links (memory export and
# friends) never get a button - there is nothing to upload for those.
ok("an explicit allow-list is rendered into the script",
   grepl('["download"]', send_js(ids = "download"), fixed = TRUE))
ok("no allow-list means every link (JS null)",
   grepl("var allowed = null;", send_js(), fixed = TRUE))

send_ui <- get("galaxy_ie_send_ui", envir = ns)
vars <- c("HISTORY_ID", "API_KEY", "GALAXY_IE_PUT")
on.exit(Sys.unsetenv(vars), add = TRUE)
Sys.unsetenv(vars)
ok("no send button is offered outside Galaxy", is.null(send_ui(ids = "download")))
Sys.setenv(HISTORY_ID = "hist0000", API_KEY = "key00000")
ok("with a history the button script is offered",
   inherits(send_ui(ids = "download"), "shiny.tag"))
ok("nothing registered means no button", is.null(send_ui(ids = character(0))))

# The export modal of the launched iSEE app is iSEE's own UI, so its download
# button is not one of the app's registered downloads: the id comes from iSEE's
# namespace constant and the file comes from shiny's session download registry.
isee_export_id <- get("galaxy_ie_isee_export_id", envir = ns)
ok("the iSEE export download id is resolved from iSEE",
   identical(isee_export_id(), "iSEE_INTERNAL_export_content_download"))
ok("the iSEE export is on the allow-list as well",
   grepl('"iSEE_INTERNAL_export_content_download"',
       send_js(ids = c("download", isee_export_id())), fixed = TRUE))
session_handler <- get("galaxy_ie_session_handler", envir = ns)
ok("a download iSEE never rendered has nothing to send",
   is.null(session_handler(list(), isee_export_id())))

# The upload log is a diagnostic: it must not land in the output directory,
# which Galaxy turns into a dataset of the results collection.
log_dir <- get("galaxy_ie_log_dir", envir = ns)
log_vars <- c("MIADASH_OUTPUT_DIR", "MIADASH_LOG_DIR")
Sys.setenv(MIADASH_OUTPUT_DIR = "/tmp/miadash-outputs",
    MIADASH_LOG_DIR = "/tmp/miadash-logs")
ok("the upload log is kept out of the output directory",
   identical(log_dir(), "/tmp/miadash-logs"))
Sys.unsetenv(log_vars)
ok("without a log directory it stays with the outputs (standalone)",
   identical(log_dir(), ""))

cat("\n== archive exports\n")
# iSEE's export panel produces one zip of every selected panel, but a zip is not a
# result a history can use: no viewer opens it and no tool takes a figure out of it.
# The members have to be unpacked and sent as their own datasets.
expand_archive <- get("galaxy_ie_expand_archive", envir = ns)
archive_dir <- tempfile("archive-")
dir.create(archive_dir, recursive = TRUE)
on.exit(unlink(archive_dir, recursive = TRUE, force = TRUE), add = TRUE)
writeLines(c("taxon,phylum", "t1,Firmicutes"), file.path(archive_dir, "RowDataTable1.csv"))
writeLines("%PDF-1.4", file.path(archive_dir, "AbundancePlot1.pdf"))
archive <- file.path(archive_dir, "iSEE_exports.zip")
old_wd <- setwd(archive_dir)
utils::zip(archive, files = c("RowDataTable1.csv", "AbundancePlot1.pdf"), flags = "-j")
setwd(old_wd)
ok("the export archive was built", file.exists(archive) && file.info(archive)$size > 0)
unpacked <- expand_archive(archive)
ok("the archive is unpacked into its members", length(unpacked) == 2L)
ok("the members keep their names",
   setequal(basename(unpacked), c("RowDataTable1.csv", "AbundancePlot1.pdf")))
ok("the members are written next to the archive", all(dirname(unpacked) == archive_dir))
ok("the members carry the content",
   all(file.info(unpacked)$size > 0))
ok("the archive itself is not kept", !file.exists(archive))
plain <- file.path(archive_dir, "treese-2026-10-26.rds")
writeLines("rds", plain)
ok("a plain file is sent as it is",
   length(expand_archive(plain)) == 0L && file.exists(plain))

cat("\n== Galaxy helper files\n")
ok("put is on PATH", nzchar(Sys.which("put")))
ok("zip is available for the archive exports", nzchar(Sys.which("zip")))

cat("\n== staged input import\n")
input_vars <- c("MIADASH_ASSAY", "MIADASH_COLDATA", "MIADASH_ROWDATA",
                "MIADASH_ROWTREE", "MIADASH_TAXA_FROM_ROWNAMES")
on.exit(Sys.unsetenv(input_vars), add = TRUE)
Sys.unsetenv(input_vars)

staged_import <- get(".galaxy_staged_import", envir = ns)

# Nothing staged: a plain docker run must stay a no-op.
rObjects <- new.env()
pObjects <- new.env()
ok("with nothing staged the import is a no-op",
   !isTRUE(staged_import(rObjects, pObjects)))
ok("and leaves no TreeSE behind", is.null(rObjects$tse))

# The full set of tables the tool XML can stage.
Sys.setenv(
    MIADASH_ASSAY = file.path(fixtures, "assay.tsv"),
    MIADASH_COLDATA = file.path(fixtures, "coldata.tsv"),
    MIADASH_ROWDATA = file.path(fixtures, "rowdata.tsv"),
    MIADASH_ROWTREE = file.path(fixtures, "row.tree")
)
pObjects <- new.env()
res <- staged_import(rObjects, pObjects)
ok("the staged tables are imported", isTRUE(res))
if (isTRUE(res)) {
    tse <- rObjects$tse
    ok("it is a TreeSummarizedExperiment",
       inherits(tse, "TreeSummarizedExperiment"))
    ok("the assay dimensions are as staged", identical(dim(tse), c(3L, 3L)))
    ok("the sample ids come from the assay header",
       identical(colnames(tse), c("s1", "s2", "s3")))
    ok("the colData variables are present",
       "Group" %in% names(SummarizedExperiment::colData(tse)))
    ok("the rowData variables are present",
       "Phylum" %in% names(SummarizedExperiment::rowData(tse)))
    tree <- TreeSummarizedExperiment::rowTree(tse)
    ok("the tree was attached with the staged tip labels",
       !is.null(tree) && setequal(tree$tip.label, c("t1", "t2", "t3")))
    ok("the tracked code records the staged paths",
       any(grepl("assay.tsv", pObjects$commands, fixed = TRUE)) &&
           any(grepl("staged by the Galaxy tool", pObjects$commands, fixed = TRUE)))
}

# An unreadable table has to fail loudly but harmlessly: the notification goes
# out, and rObjects keeps whatever it held before.
before <- rObjects$tse
Sys.setenv(MIADASH_COLDATA = file.path(fixtures, "coldata_bad.tsv"))
res <- suppressWarnings(suppressMessages(staged_import(rObjects, pObjects)))
ok("a mismatched colData is refused, not swallowed", !isTRUE(res))
ok("and the previous TreeSE is untouched",
   identical(rObjects$tse, before))
Sys.unsetenv(input_vars)

cat(sprintf("\n%d failed check(s)\n", failures))
quit(status = if (failures > 0L) 1L else 0L)
