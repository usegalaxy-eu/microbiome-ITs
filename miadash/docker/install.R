#!/usr/bin/env Rscript
#
# Installs the miaDash R package from the upstream checkout and everything it
# depends on, then verifies that the package loads, that its app can actually
# be built, and that the checkout really carries the Galaxy adaptations.
#
# miaDash is an ordinary R package that contains the Shiny app (miaDash() builds
# the iSEE app object), not a bare app directory, so it has to be installed
# rather than run with runApp(). Installing it also puts inst/assets (the logo
# the landing page renders) into place.
#
# Where the package comes from is a build argument so that the image can be
# rebuilt from a different checkout without editing this script:
#   --build-arg APP_SOURCE=/opt/src/miaDash
#
# This script runs in two passes, because the two halves have very different
# costs and very different reasons to change. Building the Bioconductor chain
# (iSEE, mia, scater, ...) takes tens of minutes and only changes when
# install.R itself changes. Installing the app package takes under a minute and
# changes with every app commit. Doing both in one pass meant every app edit
# invalidated the dependency layer, so the image could not be rebuilt in a usable
# time:
#
#   MIADASH_DEPS_ONLY=1   dependencies only, then exit
#   MIADASH_APP_ONLY=1    skip the dependencies, install + verify the app
#
# The Dockerfile runs the dependency pass before it clones the app, so a new app
# commit only re-runs the cheap second pass.
install_deps_only <- nzchar(Sys.getenv("MIADASH_DEPS_ONLY"))
install_app_only <- nzchar(Sys.getenv("MIADASH_APP_ONLY"))
if (install_deps_only && install_app_only) {
    stop("set at most one of MIADASH_DEPS_ONLY / MIADASH_APP_ONLY")
}

options(
    repos = c(
        # rocker/shiny-verse pins CRAN to "latest", which is not reproducible;
        # this is the Posit Package Manager snapshot the image is built against,
        # matching R 4.6.1 / Bioconductor 3.23, and it serves Linux binaries so
        # most packages install in seconds.
        CRAN = "https://p3m.dev/cran/__linux__/noble/2026-10-01",
        # Fallback for anything published to CRAN after the snapshot was cut.
        # The fallback is listed second on purpose: it is only consulted for
        # packages the snapshot does not carry, so the rest of the stack stays
        # version-consistent with the snapshot.
        CRAN_live = "https://cloud.r-project.org"
    ),
    # Posit Package Manager only serves binaries when it sees an R User-Agent;
    # rocker sets it in Rprofile.site, which --vanilla skips.
    HTTPUserAgent = sprintf(
        "R/%s R (%s)",
        getRversion(),
        paste(getRversion(), R.version["platform"], R.version["arch"], R.version["os"])
    ),
    Ncpus = max(1L, parallel::detectCores()),
    timeout = 3600
)
Sys.setenv(`_R_CHECK_FORCE_SUGGESTS_` = "false")

app_source <- Sys.getenv("MIADASH_SOURCE", "/opt/src/miaDash")

# miaDash's Bioconductor dependencies (Depends + Imports).
bioc_packages <- c(
    "iSEE", "iSEEtree", "mia", "bluster", "scater", "scuttle",
    "S4Vectors", "SingleCellExperiment", "SummarizedExperiment",
    "TreeSummarizedExperiment",
    # Only a Suggests of miaDash, but the transform dropdown offers "philr"
    # unconditionally, so leaving it out ships an option that errors when a
    # user picks it. Its other imports (ggtree via iSEEtree, tidyr via
    # shiny-verse) are already in the image.
    "philr"
)

# The CRAN side of the same DESCRIPTION. shiny and htmltools ship with the
# base image, but listing them costs nothing - install_missing() only installs
# what is absent.
cran_packages <- c(
    "ape", "rbiom", "rintrojs", "shinyAce", "shinydashboard", "shinyjs",
    "shinyWidgets", "vegan", "shiny", "htmltools"
)

build_packages <- c("BiocManager")

required_packages <- c(
    build_packages, cran_packages, bioc_packages, "miaDash"
)

missing_packages <- function(pkgs) {
    pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
}

# requireNamespace() failing is ambiguous: the package may be absent, or present
# but unloadable because something it imports is broken. install.packages() and
# BiocManager::install() both report the latter as success, so the install loop
# would otherwise spin on a package that can never load. Say which it is.
unloadable_packages <- function(pkgs) {
    bad <- character(0)
    for (pkg in pkgs) {
        if (requireNamespace(pkg, quietly = TRUE)) next
        problem <- tryCatch(
            {
                loadNamespace(pkg)
                NA_character_
            },
            error = function(e) conditionMessage(e)
        )
        if (is.na(problem)) next
        cat(sprintf("   %-22s cannot be loaded: %s\n", pkg, problem))
        bad <- c(bad, pkg)
    }
    bad
}

install_missing <- function(pkgs, source_name, installer) {
    todo <- missing_packages(pkgs)
    if (!length(todo)) {
        cat(sprintf("== %-14s nothing to do\n", source_name))
        return(invisible(NULL))
    }
    cat(sprintf("\n== %-14s installing %d package(s)\n", source_name, length(todo)))
    cat("   ", paste(todo, collapse = ", "), "\n", sep = "")
    installer(todo)
}

cat(sprintf("== R %s / Bioconductor %s\n",
            paste(R.version$major, R.version$minor, sep = "."),
            as.character(BiocManager::version())))

# Everything from here to the app install is third-party dependency work, which
# the cached pass owns. In the app pass it is already on disk.
if (!install_app_only) {

# BiocManager comes first: the Bioconductor install below is routed through it.
install_missing(build_packages, "bootstrap", function(pkgs) {
    install.packages(pkgs, Ncpus = options()$Ncpus)
})

# --------------------------------------------------------------------------
# Bioconductor. The rounds loop exists because BiocManager::install() resolves a
# large dependency graph in one go and can leave a package that failed to build
# behind while exiting 0; reinstalling the leftovers is what makes the check at
# the end of this pass meaningful instead of decorative.
install_missing(bioc_packages, "Bioconductor", function(pkgs) {
    rounds <- 0L
    while (length(pkgs)) {
        rounds <- rounds + 1L
        if (rounds > 5L) {
            stop("could not install the following Bioconductor packages: ",
                 paste(pkgs, collapse = ", "))
        }
        cat(sprintf("-- Bioconductor round %d: %d package(s) left\n", rounds, length(pkgs)))
        BiocManager::install(pkgs, update = FALSE, ask = FALSE, Ncpus = options()$Ncpus)
        pkgs <- unloadable_packages(pkgs)
    }
})

# install.packages() resolves a package's dependencies in one pass, but a
# dependency that is itself missing at that point is only reported afterwards,
# so chase the leftovers in rounds rather than failing on the first miss.
install_missing(cran_packages, "CRAN", function(pkgs) {
    rounds <- 0L
    while (length(pkgs)) {
        rounds <- rounds + 1L
        if (rounds > 10L) {
            stop("could not install the following CRAN packages: ", paste(pkgs, collapse = ", "))
        }
        cat(sprintf("-- CRAN round %d: %d package(s) left\n", rounds, length(pkgs)))
        install.packages(pkgs, Ncpus = options()$Ncpus)
        pkgs <- unloadable_packages(pkgs)
    }
})

}

if (install_deps_only) {
    cat("\n== dependencies installed; the app is installed in the next build layer\n")
    quit(save = "no", status = 0L)
}

cat(sprintf("\n== installing miaDash from %s\n", app_source))
if (!file.exists(file.path(app_source, "DESCRIPTION"))) {
    stop(sprintf(
        "no DESCRIPTION in %s - check APP_REPOSITORY and APP_REF",
        app_source
    ))
}

# The hard dependencies of the package itself (Depends, Imports, LinkingTo - not
# Suggests) are installed here, through the repositories configured above, so
# that the resolution order is the snapshot first and live CRAN only as a
# fallback. Read the checkout's DESCRIPTION directly: packageDescription() takes
# an installed package, not a source directory. This is also what guarantees the
# iSEE >= 2.19.4 floor that the Bioconductor 3.23 base image exists for: the
# floor is re-checked explicitly further down.
description <- read.dcf(file.path(app_source, "DESCRIPTION"))
dependency_fields <- intersect(c("Depends", "Imports", "LinkingTo"), colnames(description))
app_deps <- unlist(strsplit(description[1, dependency_fields], ","))
# "R (>= 4.4.0)" in Depends is the R version itself, not an installable package.
# Filter on the raw entry, before the version constraint is stripped off -
# afterwards the bare name "R" no longer looks like a versioned entry.
app_deps <- app_deps[nzchar(app_deps) & !grepl("^R\\s*\\(", app_deps)]
app_deps <- unique(trimws(sub("\\s*\\(.*$", "", app_deps)))
cat(sprintf("   %d declared dependencies\n", length(app_deps)))
install_missing(app_deps, "app deps", function(pkgs) {
    rounds <- 0L
    while (length(pkgs)) {
        rounds <- rounds + 1L
        if (rounds > 10L) {
            stop("could not install the following dependencies of miaDash: ",
                 paste(pkgs, collapse = ", "))
        }
        cat(sprintf("-- app deps round %d: %d package(s) left\n", rounds, length(pkgs)))
        install.packages(pkgs, Ncpus = options()$Ncpus)
        pkgs <- unloadable_packages(pkgs)
    }
})

# Deliberately not remotes::install_local(): it resolves dependencies itself
# against live CRAN and will happily upgrade packages from the snapshot. repos =
# NULL / type = "source" installs the checkout without touching any dependency
# that is already present.
install.packages(app_source, repos = NULL, type = "source")

# ---------------------------------------------------------------------------
# Verification
#
# requireNamespace() only proves a package is on disk, so load each namespace
# for real. A dependency that failed to build shows up here instead of in the
# middle of a user's interactive session.
# ---------------------------------------------------------------------------
cat("\n== verifying installed packages\n")
broken <- character(0)
for (pkg in required_packages) {
    version <- tryCatch(
        {
            loadNamespace(pkg)
            as.character(utils::packageVersion(pkg))
        },
        error = function(e) {
            cat(sprintf("   %-22s BROKEN: %s\n", pkg, conditionMessage(e)))
            NA_character_
        }
    )
    if (is.na(version)) {
        broken <- c(broken, pkg)
    } else {
        cat(sprintf("   %-22s %s\n", pkg, version))
    }
}

if (length(broken)) {
    stop(sprintf("%d required package(s) could not be loaded: %s",
                 length(broken), paste(broken, collapse = ", ")))
}

# miaDash requires iSEE >= 2.19.4 (its DESCRIPTION Depends). The Bioconductor
# 3.23 base image exists for exactly this floor, so state it here rather than
# letting an old iSEE surface as a failed install of the app itself.
isee_version <- utils::packageVersion("iSEE")
cat(sprintf("   %-22s %s (needs >= 2.19.4)\n", "iSEE", isee_version))
if (isee_version < "2.19.4") {
    stop(sprintf("iSEE %s is older than the required 2.19.4", isee_version))
}

# The app is assembled by miaDash(), which builds the iSEE landing page object,
# so calling it exercises the package's UI and server code without a browser.
#
# library(miaDash) first, deliberately: miaDash() calls shiny's
# addResourcePath() unqualified, and the package's NAMESPACE only imports
# stopApp from shiny. That resolves through the attached package (shiny is in
# Depends, so library(miaDash) attaches it) - which is how upstream documents
# and runs the app - but not through a bare miaDash::miaDash() call.
cat("\n== verifying the app object\n")
suppressPackageStartupMessages(library(miaDash))
app <- tryCatch(suppressMessages(miaDash::miaDash()), error = function(e) e)
if (inherits(app, "error")) {
    stop("miaDash::miaDash() failed: ", conditionMessage(app))
}
report <- function(ok, what) {
    cat(sprintf("   %-52s %s\n", what, if (ok) "ok" else "FAIL"))
    if (!ok) stop("check failed: ", what)
}
report(inherits(app, "shiny.appobj"), "miaDash() returns a shiny app")
report(length(app$httpHandler) > 0, "the app has a request handler")

# The landing page renders the packaged logo from inst/assets; missing it would
# only show up as a broken image in a user's session.
report(file.exists(file.path(find.package("miaDash"), "assets", "mia_logo.png")),
       "installed assets file: assets/mia_logo.png")

# The Galaxy adaptations must be in the installed package. This is what catches
# a clone of plain upstream instead of the fork's galaxy-it-adaptations branch:
# the image would otherwise build perfectly and ship an app without any Galaxy
# integration at all.
cat("\n== verifying the Galaxy adaptations\n")
ns <- asNamespace("miaDash")
report(exists("galaxy_ie_send_js", envir = ns, inherits = FALSE),
       "R/galaxy_ie.R is part of the package (Send-to-Galaxy)")
report(exists("galaxy_ie_send_ui", envir = ns, inherits = FALSE),
       "the send-button UI helper is part of the package")
report(exists(".galaxy_staged_import", envir = ns, inherits = FALSE),
       "R/galaxy_input.R is part of the package (staged import)")
# Outside Galaxy (no HISTORY_ID/API_KEY, which is what a build has) the button
# must not be offered at all.
report(is.null(get("galaxy_ie_send_ui", envir = ns)()),
       "no send button is offered outside Galaxy")
js <- get("galaxy_ie_send_js", envir = ns)()
report(grepl("shiny-download-link", js, fixed = TRUE),
       "the injection script targets shiny download links")
report(grepl("miadash_galaxy_send", js, fixed = TRUE),
       "the injection script is namespaced for this app")

# zip is what utils::zip shells out to for the Mothur and QIIME2 exports.
zip_path <- Sys.which("zip")
report(nzchar(zip_path), "zip is available for the archive exports")

cat("\n== miaDash loads, builds its app and carries the Galaxy adaptations\n")
