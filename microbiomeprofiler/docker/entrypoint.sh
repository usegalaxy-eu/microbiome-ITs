#!/bin/bash
#
# Container entrypoint for the MicrobiomeProfiler Galaxy Interactive Tool.
#
# The app is an R package rather than a bare Shiny directory, so there is no
# runApp("<dir>") call: the golem app object is built first and then handed to
# shiny::runApp().
#
# The explicit host = "0.0.0.0" matters. shiny::runApp() binds to 127.0.0.1
# unless told otherwise, which would make the app unreachable from outside the
# container, and Galaxy reaches the job container over a bridge IP rather than
# on its loopback interface. golem's own options (run_MicrobiomeProfiler(port=,
# host=)) only end up in appOptions$golem_options and are not used for binding.
#
# The port comes from $PORT, which the Dockerfile sets from ARG PORT and which
# has to match <port> in the tool XML: Galaxy publishes exactly that container
# port for the interactive tool entry point.

set -euo pipefail

PORT="${PORT:-8080}"

echo "Starting MicrobiomeProfiler on 0.0.0.0:${PORT}"
R --vanilla -q -e "
    suppressMessages(library(MicrobiomeProfiler))
    app <- MicrobiomeProfiler::run_MicrobiomeProfiler()
    shiny::runApp(app, host = '0.0.0.0', port = ${PORT}, launch.browser = FALSE)
"