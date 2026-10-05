#!/usr/bin/env Rscript
#
# Headless checks for the CMiNet container: the R stack the app needs, the
# example data it ships with, and the shape of the inputs the tool stages.
#
# This deliberately does not start Shiny. `make check` covers that, and doing it
# here would make every quick feedback loop take a minute.
#
#   docker run --rm -v "$PWD/tests:/tests:ro" --entrypoint Rscript \
#       cminet-gxit:latest --vanilla /tests/smoke_test.R /opt/CMiNetShinyAPP

args <- commandArgs(trailingOnly = TRUE)
app_dir <- if (length(args) >= 1) args[[1]] else "/opt/CMiNetShinyAPP"

failures <- 0L
ok <- function(label, condition) {
    if (isTRUE(condition)) {
        cat(sprintf("PASS - %s\n", label))
    } else {
        cat(sprintf("FAIL - %s\n", label))
        failures <<- failures + 1L
    }
}

cat(sprintf("== R stack (app source: %s)\n", app_dir))
cat(sprintf("   R %s.%s\n", R.version$major, R.version$minor))

# Everything app.R loads with library(), plus what CMiNet itself imports. A
# missing or unloadable package here is what turns into a blank panel panel in an
# interactive session, so it is worth failing the build for.
app_libraries <- c("shiny", "SpiecEasi", "shinyWidgets", "shinyBS",
                   "SPRING", "CMiNet", "igraph", "visNetwork")
for (pkg in app_libraries) {
    version <- tryCatch({
        loadNamespace(pkg)
        as.character(utils::packageVersion(pkg))
    }, error = function(e) {
        cat(sprintf("   %-14s BROKEN: %s\n", pkg, conditionMessage(e)))
        NA_character_
    })
    ok(sprintf("%s loads", pkg), !is.na(version))
    if (!is.na(version)) {
        cat(sprintf("   %-14s %s\n", pkg, version))
    }
}

# CMiNet's own Imports, which the app relies on indirectly through it.
for (pkg in c("WGCNA", "huge", "gtools", "readr", "zip", "ggplot2")) {
    ok(sprintf("%s loads", pkg), requireNamespace(pkg, quietly = TRUE))
}

# The ggplot2 4.x guard from docker/install.R: Bioconductor 3.20's WGCNA is built
# against the ggplot2 3.x internals, so an upgraded ggplot2 leaves it installed
# but unloadable.
ok("ggplot2 stays on the 3.x line",
   utils::packageVersion("ggplot2") < "4.0.0")

cat("\n== bundled example data\n")
sample_dir <- file.path(app_dir, "sample")
ok("the sample directory exists", dir.exists(sample_dir))

sample_data <- file.path(sample_dir, "sample_data.csv")
if (file.exists(sample_data)) {
    df <- tryCatch(
        read.csv(sample_data, row.names = 1, check.names = FALSE),
        error = function(e) e
    )
    ok("sample_data.csv parses", !inherits(df, "error"))
    if (!inherits(df, "error")) {
        # CMiNet expects samples in the rows and taxa in the columns.
        ok("sample_data.csv has samples in the rows", nrow(df) > 1)
        ok("sample_data.csv has taxa in the columns", ncol(df) > 1)
        ok("sample_data.csv has no empty cells", !anyNA(df))
        ok("sample_data.csv is non-negative", all(as.matrix(df) >= 0, na.rm = TRUE))
        cat(sprintf("   %d samples x %d taxa\n", nrow(df), ncol(df)))
    }
} else {
    ok("sample_data.csv exists", FALSE)
}

sample_net <- file.path(sample_dir, "weighted_network.csv")
if (file.exists(sample_net)) {
    net <- tryCatch(
        as.matrix(read.csv(sample_net, row.names = 1, check.names = FALSE)),
        error = function(e) e
    )
    ok("sample weighted_network.csv parses", !inherits(net, "error"))
    if (!inherits(net, "error")) {
        ok("the sample network is square", nrow(net) == ncol(net))
    }
} else {
    ok("sample weighted_network.csv exists", FALSE)
}

cat("\n== Galaxy helper files\n")
ok("galaxy_ie.R is in the app checkout", file.exists(file.path(app_dir, "galaxy_ie.R")))
ok("galaxy_helpers.R is in the app checkout", file.exists(file.path(app_dir, "galaxy_helpers.R")))

# galaxy_ie_helpers has to be importable and on PATH for the Send to Galaxy
# buttons and the history picker to work at all.
for (command in c("get", "put", "get_user_history")) {
    ok(sprintf("%s is on PATH", command), nzchar(Sys.which(command)))
}

cat(sprintf("\n%d failed check(s)\n", failures))
quit(status = if (failures > 0L) 1L else 0L)