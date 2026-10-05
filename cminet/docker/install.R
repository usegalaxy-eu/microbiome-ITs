#!/usr/bin/env Rscript
#
# Installs every R package the CMiNet Shiny app needs, then verifies that each
# one can actually be loaded. This runs once at docker build time: at runtime
# the app must not try to install anything, because Galaxy job containers have
# no network and a half-installed package would only surface as a broken panel
# hours into an interactive session.
#
# rocker/shiny-verse pins CRAN to a Posit Package Manager snapshot taken for this
# image's R/Bioconductor release and ships Linux binaries from it. Stay on that
# snapshot rather than cloud.r-project.org for the same reason MetaDAVis does:
# live CRAN serves packages built against a much newer R, which upgrades ggplot2
# past the boundary Bioconductor 3.20 packages were written against.
#
# The User-Agent is what makes Posit Package Manager serve binaries instead of
# source; rocker sets it in Rprofile.site, which --vanilla skips.
options(
    repos = c(CRAN = "https://p3m.dev/cran/__linux__/noble/2025-04-10"),
    HTTPUserAgent = sprintf(
        "R/%s R (%s)",
        getRversion(),
        paste(getRversion(), R.version["platform"], R.version["arch"], R.version["os"])
    ),
    Ncpus = max(1L, parallel::detectCores()),
    timeout = 3600
)
Sys.setenv(`_R_CHECK_FORCE_SUGGESTS_` = "false")

# CRAN packages the app loads directly or that its dependency chain needs.
# rocker/shiny-verse:4.4.3 already ships shiny and ggplot2. `zip` is listed
# explicitly rather than assumed: the app's folder downloads call zip::zip(), so
# it must be present even if a future base image drops it.
cran_packages <- c(
    "shinyWidgets", "shinyBS", "visNetwork", "igraph", "readr",
    "ggplot2", "gtools", "huge", "zip",
    # SPRING's own Imports: latentcor (which replaced mixedCCA upstream in 2026),
    # plus pulsar/rootSolve/mvtnorm.
    "latentcor", "pulsar", "rootSolve", "mvtnorm"
)

# Bioconductor. WGCNA supplies bicor(), which CMiNet imports directly;
# AnnotationDbi/GO.db/preprocessCore/impute are the Bioconductor packages that
# SpiecEasi and SPRING expect to be present (the upstream READMEs list them).
#
# SpiecEasi is NOT here even though upstream SPRING moved to the Bioconductor
# build: SpiecEasi only entered Bioconductor after this image's Bioconductor
# release (3.20, paired with R 4.4), and BiocManager reports "package 'SpiecEasi'
# is not available for Bioconductor version '3.20'". It is therefore installed
# from GitHub below, which satisfies both SPRING and CMiNet.
bioc_packages <- c(
    "WGCNA", "AnnotationDbi", "GO.db", "preprocessCore", "impute"
)

# GitHub-only packages, in the order they must be installed. SPRING depends on
# SpiecEasi, and CMiNet imports both, so a single install pass would race. Each
# is installed with upgrade = "never" so a package already provided by the
# snapshot is not silently replaced by a newer, incompatible build.
#
# SPRING is pinned to a commit rather than to main: main declares
# `Depends: R (>= 4.6.0)` as of 2026-05-15 and will not install on this image's
# R 4.4.3. 95925f8 is the newest commit that still allows R >= 4.4.0.
github_packages <- c(
    SpiecEasi = "zdk123/SpiecEasi@v1.1.1",
    SPRING     = "GraceYoon/SPRING@95925f86ad2b9c2379fdb234895c93df994f78c2",
    CMiNet     = "solislemuslab/CMiNet@404527d971e893a43196f73ea7d11d866ee50554"
)

required_packages <- c(
    "shiny", "shinyWidgets", "shinyBS", "visNetwork", "igraph", "readr",
    "ggplot2", "gtools", "huge", "zip", "CMiNet", "SpiecEasi", names(github_packages),
    "WGCNA"
)

missing_packages <- function(pkgs) {
    pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
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

install_missing(c("BiocManager", "remotes", "devtools"), "bootstrap", function(pkgs) {
    install.packages(pkgs, Ncpus = options()$Ncpus)
})

cat(sprintf("== R %s / Bioconductor %s\n",
            paste(R.version$major, R.version$minor, sep = "."),
            as.character(BiocManager::version())))

# Bioconductor before CRAN/GitHub so the compiled dependencies (fastcluster,
# matrixStats, ...) are present when SpiecEasi/SPRING/CMiNet resolve theirs.
install_missing(bioc_packages, "Bioconductor", function(pkgs) {
    rounds <- 0L
    while (length(pkgs)) {
        rounds <- rounds + 1L
        if (rounds > 5L) {
            stop(sprintf("could not install the following Bioconductor packages: %s",
                         paste(pkgs, collapse = ", ")))
        }
        cat(sprintf("-- Bioconductor round %d: %d package(s) left\n", rounds, length(pkgs)))
        BiocManager::install(pkgs, update = FALSE, ask = FALSE, Ncpus = options()$Ncpus)
        pkgs <- missing_packages(pkgs)
    }
})

# A single install.packages() pass resolves one level of dependencies, so chase
# whatever is still missing in rounds rather than failing on the first miss.
install_missing(cran_packages, "CRAN", function(pkgs) {
    rounds <- 0L
    while (length(pkgs)) {
        rounds <- rounds + 1L
        if (rounds > 10L) {
            stop(sprintf("could not install the following CRAN packages: %s",
                         paste(pkgs, collapse = ", ")))
        }
        cat(sprintf("-- CRAN round %d: %d package(s) left\n", rounds, length(pkgs)))
        install.packages(pkgs, Ncpus = options()$Ncpus)
        pkgs <- missing_packages(pkgs)
    }
})

# Installed strictly in dependency order: SpiecEasi, then SPRING (which imports
# SpiecEasi), then CMiNet (which imports both). dependencies = TRUE installs each
# package's Depends/Imports/LinkingTo; upgrade = "never" leaves anything already
# present alone so a package is not silently replaced by a second incompatible
# build.
install_missing(names(github_packages), "GitHub", function(pkgs) {
    for (pkg in pkgs) {
        cat(sprintf("-- installing %s from %s\n", pkg, github_packages[[pkg]]))
        remotes::install_github(github_packages[[pkg]],
                                upgrade = "never",
                                dependencies = TRUE,
                                Ncpus = options()$Ncpus)
    }
})

# ---------------------------------------------------------------------------
# Verification: requireNamespace() only proves a package is on disk, so load each
# namespace for real. A dependency that failed to build shows up here instead of
# in the middle of a user's interactive session.
# ---------------------------------------------------------------------------
cat("\n== verifying installed packages\n")
broken <- character(0)
for (pkg in unique(required_packages)) {
    version <- tryCatch(
        {
            loadNamespace(pkg)
            as.character(utils::packageVersion(pkg))
        },
        error = function(e) {
            cat(sprintf("   %-20s BROKEN: %s\n", pkg, conditionMessage(e)))
            NA_character_
        }
    )
    if (is.na(version)) {
        broken <- c(broken, pkg)
    } else {
        cat(sprintf("   %-20s %s\n", pkg, version))
    }
}

if (length(broken)) {
    stop(sprintf("%d required package(s) could not be loaded: %s",
                 length(broken), paste(broken, collapse = ", ")))
}

# Guard against the ggplot2 4.x failure mode: Bioconductor 3.20 packages such as
# WGCNA were built against the ggplot2 3.x internals, so a live-CRAN upgrade can
# leave them installed but unloadable. Fail loudly here instead of letting it
# surface as a broken panel later.
ggplot2_version <- utils::packageVersion("ggplot2")
cat(sprintf("   %-20s %s\n", "ggplot2", ggplot2_version))
if (ggplot2_version >= "4.0.0") {
    stop(sprintf(
        paste0("ggplot2 %s was installed, but this image targets the CRAN snapshot ",
               "for R 4.4.3 / Bioconductor 3.20. Use the pinned snapshot at the top ",
               "of this script instead of live CRAN."),
        ggplot2_version
    ))
}

cat("\n== all required R packages load cleanly\n")