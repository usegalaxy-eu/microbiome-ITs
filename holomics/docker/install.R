options(
    repos = c(CRAN = "https://p3m.dev/cran/__linux__/noble/2025-04-10"),
    Ncpus = 4L, timeout = 1200,
    HTTPUserAgent = sprintf("R/%s R (%s)", getRversion(), R.version$platform)
)
cran <- c("BiocManager", "bs4Dash", "config", "dplyr", "DT", "ggplot2",
          "golem", "igraph", "openxlsx", "readxl", "shiny", "shinyalert",
          "shinybusy", "shinyjs", "shinyvalidate", "shinyWidgets", "stringr",
          "tippy", "visNetwork", "markdown", "jsonlite")
verify <- function(pkgs) {
    for (pkg in pkgs) {
        loadNamespace(pkg)
        cat(pkg, as.character(packageVersion(pkg)), "\n")
    }
}
if (Sys.getenv("APP_STAGE") == "deps") {
    missing <- cran[!vapply(cran, requireNamespace, logical(1), quietly = TRUE)]
    if (length(missing)) install.packages(missing)
    verify(cran)
    BiocManager::install(version = "3.20", ask = FALSE, update = FALSE)
    BiocManager::install(c("mixOmics", "BiocParallel"), ask = FALSE, update = FALSE)
    verify(c("mixOmics", "BiocParallel"))
} else {
    install.packages("/opt/Holomics", repos = NULL, type = "source")
    verify(c(cran, "mixOmics", "BiocParallel", "Holomics"))
    stopifnot(inherits(Holomics::run_app(), "shiny.appobj"))
    writeLines(capture.output(sessionInfo()), "/opt/holomics-session-info.txt")
}
