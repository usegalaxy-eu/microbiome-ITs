#!/usr/bin/env Rscript
#
# Installs every R package MetaDAVis needs, then verifies that each one can
# actually be loaded. This runs once at docker build time: at runtime the app
# must not try to install anything, because Galaxy job containers have no
# network and a half-installed package would only surface as a broken analysis
# panel hours into an interactive session.

# rocker/shiny-verse pins CRAN to a Posit Package Manager snapshot taken for
# this image's R/Bioconductor release, and ships Linux *binaries* from it. Use
# exactly the same repository here instead of cloud.r-project.org.
#
# This is not just about speed. The live CRAN serves packages built for a much
# newer R: installing from it upgrades ggplot2 from the image's 3.5.2 to 4.x,
# and ggtree 3.14 (Bioconductor 3.20) calls the internal ggplot2 helper
# check_linewidth(), which ggplot2 4.0 renamed. The result is a ggtree that
# cannot be byte-compiled, which in turn takes mia, lefser and everything that
# depends on them down with it. Staying on the snapshot keeps the yulab stack
# (ggfun, yulab.utils, tidytree, treeio, ggtree) mutually consistent.
#
# The User-Agent is what makes Posit Package Manager serve binaries instead of
# source; rocker sets it in Rprofile.site, which --vanilla skips, so set it here.
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

# Mirrors the lists in the upstream README, minus what rocker/shiny-verse:4.4.3
# already ships (shiny, ggplot2, tidyr, dplyr, tibble, scales, zip, devtools).
cran_packages <- c(
    "DT", "shinythemes", "shinyFiles", "shinyjs", "shinydashboard",
    "ggpubr", "vegan", "ggfortify", "ggplotify", "reshape2", "dunn.test",
    "patchwork", "GGally", "plotly", "filelock", "shinycssloaders",
    "RColorBrewer", "circlize"
)

bioc_packages <- c(
    "phyloseq", "microbiome", "ComplexHeatmap", "qvalue", "scater",
    "DESeq2", "limma", "edgeR", "metagenomeSeq", "bluster", "mia", "lefser"
)

github_packages <- c(
    microbiomeutilities = "microsud/microbiomeutilities",
    maaslin3 = "biobakery/maaslin3"
)

# plotly::save_image() needs a headless Chrome; the R side is optional because
# only the 3D plotly plots of the bulk export fall back to it.
optional_cran_packages <- c("kaleido")

required_packages <- c(
    "shiny", "ggplot2", "tidyr", "dplyr", "tibble", "scales", "zip", "devtools",
    cran_packages, bioc_packages, names(github_packages)
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

# Bioconductor first: phyloseq, microbiome and friends pull in most of the
# heavy compiled dependencies (SummarizedExperiment, scater, treeio, ...), and
# resolving them through BiocManager keeps the Bioc release consistent.

install_missing(bioc_packages, "Bioconductor", function(pkgs) {
    rounds <- 0L
    while (length(pkgs)) {
        rounds <- rounds + 1L
        if (rounds > 5L) {
            stop("could not install the following Bioconductor packages: ", paste(pkgs, collapse = ", "))
        }
        cat(sprintf("-- Bioconductor round %d: %d package(s) left\n", rounds, length(pkgs)))
        BiocManager::install(pkgs, update = FALSE, ask = FALSE, Ncpus = options()$Ncpus)
        pkgs <- missing_packages(pkgs)
    }
})

# ggpubr's dependency chain (rstatix -> doBy -> Deriv) fails to resolve on a
# single install.packages() pass, so missing dependencies are chased in rounds
# until nothing new turns up.
install_missing(cran_packages, "CRAN", function(pkgs) {
    rounds <- 0L
    while (length(pkgs)) {
        rounds <- rounds + 1L
        if (rounds > 10L) {
            stop("could not install the following CRAN packages: ", paste(pkgs, collapse = ", "))
        }
        cat(sprintf("-- CRAN round %d: %d package(s) left\n", rounds, length(pkgs)))
        install.packages(pkgs, Ncpus = options()$Ncpus)
        pkgs <- missing_packages(pkgs)
    }
})

install_missing(names(github_packages), "GitHub", function(pkgs) {
    for (pkg in pkgs) {
        devtools::install_github(github_packages[[pkg]], upgrade = "never")
    }
})

install_missing(optional_cran_packages, "CRAN optional", function(pkgs) {
    install.packages(pkgs, Ncpus = options()$Ncpus)
})

# ---------------------------------------------------------------------------
# Verification: requireNamespace() only proves the package is on disk, so load
# each namespace for real - a dependency that failed to build shows up here
# instead of in the middle of a user's Shiny session.
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

# Guard against the ggplot2 4.x failure mode described at the top: ggtree 3.14
# calls ggplot2:::check_linewidth(), removed in ggplot2 4.0, so an upgrade makes
# ggtree (and mia, lefser, ...) unloadable. Fail loudly here rather than letting
# it surface as a broken panel in someone's interactive session.
ggplot2_version <- utils::packageVersion("ggplot2")
cat(sprintf("   %-20s %s\n", "ggplot2", ggplot2_version))
if (ggplot2_version >= "4.0.0") {
    stop(sprintf(
        paste0("ggplot2 %s was installed, but Bioconductor 3.20 needs ggplot2 < 4.0 ",
               "(ggtree 3.14 uses ggplot2:::check_linewidth()). Use the CRAN snapshot ",
               "pinned at the top of this script instead of live CRAN."),
        ggplot2_version
    ))
}

for (pkg in optional_cran_packages) {
    state <- if (requireNamespace(pkg, quietly = TRUE)) as.character(utils::packageVersion(pkg)) else "not installed"
    cat(sprintf("   %-20s %s (optional)\n", pkg, state))
}

cat("\n== all required R packages load cleanly\n")