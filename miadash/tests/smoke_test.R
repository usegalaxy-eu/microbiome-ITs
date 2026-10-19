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
                 "galaxy_staged_paths", "galaxy_staged_active",
                 ".galaxy_staged_import")) {
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
