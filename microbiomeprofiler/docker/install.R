#!/usr/bin/env Rscript
#
# Installs the MicrobiomeProfiler R package from the upstream checkout and
# everything it imports, then verifies that the package loads and that its app
# can actually be built.
#
# MicrobiomeProfiler is an ordinary R package that contains the Shiny app
# (app_ui, app_server, run_MicrobiomeProfiler), not a bare app directory, so it
# has to be installed rather than run with runApp(). Installing it also puts the
# packaged data into place - most importantly inst/extdata/external_data_registry.json,
# which the app reads to find its annotation resources.
#
# Where the package comes from is a build argument so that the image can be
# rebuilt from a different checkout without editing this script:
#   --build-arg APP_SOURCE=/opt/src/MicrobiomeProfiler
#
# This script runs in two passes, because the two halves have very different
# costs and very different reasons to change. Building the dependency chain
# (yulab + Bioconductor + clusterProfiler) takes tens of minutes and only changes
# when install.R itself changes. Installing the app package takes under a minute
# and changes with every app commit. Doing both in one pass meant every app edit
# invalidated the dependency layer, so the image could not be rebuilt in a usable
# time:
#
#   MICROBIOMEPROFILER_DEPS_ONLY=1   dependencies only, then exit
#   MICROBIOMEPROFILER_APP_ONLY=1    skip the dependencies, install + verify the app
#
# The Dockerfile runs the dependency pass before it clones the app, so a new app
# commit only re-runs the cheap second pass.
install_deps_only <- nzchar(Sys.getenv("MICROBIOMEPROFILER_DEPS_ONLY"))
install_app_only <- nzchar(Sys.getenv("MICROBIOMEPROFILER_APP_ONLY"))
if (install_deps_only && install_app_only) {
    stop("set at most one of MICROBIOMEPROFILER_DEPS_ONLY / MICROBIOMEPROFILER_APP_ONLY")
}

options(
    repos = c(
        # rocker/shiny-verse pins CRAN to this Posit Package Manager snapshot,
        # which is the CRAN state matching R 4.4.3 / Bioconductor 3.20, and it
        # serves Linux binaries so most packages install in seconds.
        CRAN = "https://p3m.dev/cran/__linux__/noble/2025-04-10",
        # Fallback for anything published to CRAN after the snapshot was cut.
        # enrichit (>= 0.2.2, required by the current MicrobiomeProfiler) is one
        # of them. The fallback is listed second on purpose: it is only consulted
        # for packages the snapshot does not carry, so the rest of the stack
        # stays version-consistent with Bioconductor 3.20.
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

app_source <- Sys.getenv("MICROBIOMEPROFILER_SOURCE", "/opt/src/MicrobiomeProfiler")

# clusterProfiler and enrichplot are Bioconductor packages, not CRAN ones.
bioc_packages <- c("clusterProfiler", "enrichplot")

# The rest of DESCRIPTION's Imports, which are all on CRAN.
cran_packages <- c(
    "enrichit", "config", "digest", "DT", "golem", "gson", "magrittr",
    "jsonlite", "shiny", "shinyWidgets", "shinycustomloader", "htmltools",
    "ggplot2", "graphics", "stats", "utils", "yulab.utils"
)

# golem apps are loaded with pkgload during development and built with remotes.
build_packages <- c("BiocManager", "pkgload", "remotes")

# Installed from live CRAN, ahead of everything else.
#
# rlang is here because the yulab packages on live CRAN are built against a
# newer rlang than the 1.1.5 in the snapshot (ggrepel requires >= 1.1.6), and a
# package that needs a newer rlang than the one loaded fails with
# "namespace 'rlang' 1.1.5 is already loaded, but >= 1.1.6 is required" the
# moment anything has already loaded rlang - which BiocManager does. Upgrading
# rlang first is what makes the rest load.
#
# enrichit is here because it was published to CRAN after the snapshot was cut
# and the current MicrobiomeProfiler requires >= 0.2.2.
live_cran_packages <- c("rlang", "enrichit")
live_cran_repo <- c(CRAN_live = "https://cloud.r-project.org")

# rlang must be at least this new, or the packages above cannot be loaded.
min_rlang <- "1.1.6"

required_packages <- c(
    build_packages, cran_packages, bioc_packages, "MicrobiomeProfiler"
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

# --------------------------------------------------------------------------
# rlang has to be upgraded FIRST, before anything in this session can load the
# old one.
#
# Once a namespace is loaded, R pins it: installing a newer version on disk does
# not change the version that is already loaded, and loading a package that asks
# for a newer rlang then fails with "namespace 'rlang' 1.1.5 is already loaded,
# but >= 1.1.6 is required" - even though utils::packageVersion() reports the
# new version, because that reads DESCRIPTION from disk rather than the loaded
# namespace. Anything that imports rlang (pkgload and remotes below, BiocManager,
# install.packages' own dependency checks) would trigger exactly that, so this
# has to happen before the first install call of the session.
#
# Not routed through install_missing(): "missing" is the wrong question here.
# rlang is present in the snapshot at 1.1.5, which is precisely the version
# that is too old, so a presence check would skip the upgrade. install.packages()
# is a no-op when the package is already current, so just run it.
cat(sprintf("\n== %-14s ensuring current: %s\n",
            "CRAN live", paste(live_cran_packages, collapse = ", ")))
install.packages(live_cran_packages, repos = live_cran_repo, Ncpus = options()$Ncpus)
rlang_now <- utils::packageVersion("rlang")
if (rlang_now < min_rlang) {
    stop(sprintf("rlang %s could not be upgraded to >= %s from live CRAN",
                 rlang_now, min_rlang))
}
cat(sprintf("   rlang %s (on disk, not loaded yet)\n", rlang_now))

cat(sprintf("== R %s / Bioconductor %s\n",
            paste(R.version$major, R.version$minor, sep = "."),
            as.character(BiocManager::version())))

# From here on namespaces get loaded, so verify the *loaded* rlang, not the one
# on disk. packageVersion() would read DESCRIPTION again, which is exactly the
# value that hid the problem; loading the namespace and asking it for its own
# version is what actually matters.
loaded_rlang <- tryCatch(
    {
        loadNamespace("rlang")
        as.character(getNamespaceVersion("rlang"))
    },
    error = function(e) paste("cannot be loaded:", conditionMessage(e))
)
cat(sprintf("   loaded rlang %s\n", loaded_rlang))
if (loaded_rlang < min_rlang) {
    stop(sprintf("the loaded rlang is %s, but >= %s is required", loaded_rlang, min_rlang))
}

install_missing(build_packages, "bootstrap", function(pkgs) {
    install.packages(pkgs, Ncpus = options()$Ncpus)
})

# --------------------------------------------------------------------------
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

cat(sprintf("\n== installing MicrobiomeProfiler from %s\n", app_source))
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
# an installed package, not a source directory.
description <- read.dcf(file.path(app_source, "DESCRIPTION"))
dependency_fields <- intersect(c("Depends", "Imports", "LinkingTo"), colnames(description))
app_deps <- unlist(strsplit(description[1, dependency_fields], ","))
# "R (>= 4.2.0)" in Depends is the R version itself, not an installable package.
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
            stop("could not install the following dependencies of MicrobiomeProfiler: ",
                 paste(pkgs, collapse = ", "))
        }
        cat(sprintf("-- app deps round %d: %d package(s) left\n", rounds, length(pkgs)))
        install.packages(pkgs, Ncpus = options()$Ncpus)
        pkgs <- unloadable_packages(pkgs)
    }
})

# Deliberately not remotes::install_local(): it resolves dependencies itself
# against live CRAN and will happily upgrade ggplot2 from the snapshot's 3.5.2
# to 4.x, which breaks ggtree 3.14 (see the ggplot2 check in the verification
# below). repos = NULL / type = "source" installs the checkout without touching
# any dependency that is already present.
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

# Guard the rlang floor that the live-CRAN yulab packages rely on, and the
# ggplot2 ceiling that the Bioconductor 3.20 ones impose (ggtree 3.14 calls
# ggplot2:::check_linewidth(), which ggplot2 4.0 renamed). Both failures are
# silent "installed but unloadable" states, so state them here rather than
# letting them surface in a user's interactive session.
rlang_version <- as.character(tryCatch(getNamespaceVersion("rlang"), error = function(e) NA_character_))
cat(sprintf("   %-22s %s (needs >= %s)\n", "rlang", rlang_version, min_rlang))
if (is.na(rlang_version) || rlang_version < min_rlang) {
    stop(sprintf("rlang %s is older than the required %s; the yulab packages on live CRAN will not load",
                 rlang_version, min_rlang))
}

ggplot2_version <- utils::packageVersion("ggplot2")
cat(sprintf("   %-22s %s\n", "ggplot2", ggplot2_version))
if (ggplot2_version >= "4.0.0") {
    stop(sprintf(
        paste0("ggplot2 %s was installed, but Bioconductor 3.20 needs ggplot2 < 4.0 ",
               "(ggtree 3.14 uses ggplot2:::check_linewidth()). Keep ggplot2 on the CRAN ",
               "snapshot rather than letting live CRAN upgrade it."),
        ggplot2_version
    ))
}

# The app is assembled from three objects in the package, so building the Shiny
# app object exercises the ui/server code, the golem options and the data files
# without needing a browser.
cat("\n== verifying the app object\n")
app <- tryCatch(
    suppressMessages(MicrobiomeProfiler::run_MicrobiomeProfiler()),
    error = function(e) e
)
if (inherits(app, "error")) {
    stop("MicrobiomeProfiler::run_MicrobiomeProfiler() failed: ", conditionMessage(app))
}
report <- function(ok, what) {
    cat(sprintf("   %-46s %s\n", what, if (ok) "ok" else "FAIL"))
    if (!ok) stop("check failed: ", what)
}
report(inherits(app, "shiny.appobj"), "run_MicrobiomeProfiler() returns a shiny app")
report(length(app$httpHandler) > 0, "the app has a request handler")

pkg_dir <- find.package("MicrobiomeProfiler")
for (path in c("golem-config.yml",
               "extdata/external_data_registry.json",
               "app/www/custom.css")) {
    report(file.exists(file.path(pkg_dir, path)), paste0("installed data file: ", path))
}

# The registry is what the app reads at startup to decide which annotation
# resources to fetch, so an unparseable one would only fail on the first click.
report(length(jsonlite::fromJSON(file.path(pkg_dir, "extdata/external_data_registry.json"))) > 0,
       "external data registry is valid JSON")

cat("\n== MicrobiomeProfiler loads and builds its app cleanly\n")
