#!/usr/bin/env Rscript
#
# Focused check of the CMiNet app's Galaxy integration: the download registry, the
# "Send to Galaxy" button injection and the history picker.
#
# galaxy_ie_helpers is stubbed, so this runs without a Galaxy and without a
# network. What is being verified is the app's own wiring - that every download
# the UI offers is registered, that the picker is wired to the input slot, and
# that a registered content function really produces the file it claims to.
#
#   docker run --rm -v "$PWD/CMiNetShinyAPP:/app:ro" -v "$PWD/tests:/tests:ro" \
#       --entrypoint Rscript cminet-gxit:latest --vanilla /tests/galaxy_ie_test.R /app

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

# --------------------------------------------------------------------------
# Stub galaxy_ie_helpers. `get` copies a canned file per requested hid, so the
# import path can be exercised end to end without Galaxy.
# --------------------------------------------------------------------------
stub_dir <- file.path(tempdir(), "stub")
dir.create(stub_dir, showWarnings = FALSE, recursive = TRUE)

writeLines(c(
    "#!/bin/sh",
    "# Writes one file per requested id, like the real `get`, whose --id takes",
    "# nargs=+ so `-i 1 2` downloads both. Values are collected until the next",
    "# flag, which a naive `case $1 in -i)` loop gets wrong.",
    "collect=0",
    "hids=\"\"",
    "for a in \"$@\"; do",
    "  if [ \"$collect\" = \"1\" ]; then",
    "    case \"$a\" in",
    "      -*) collect=0;;",
    "      *) hids=\"$hids $a\"; continue;;",
    "    esac",
    "  fi",
    "  case \"$a\" in",
    "    -i) collect=1;;",
    "  esac",
    "done",
    "status=0",
    "for hid in $hids; do",
    "  if [ \"$hid\" = \"999\" ]; then status=1; continue; fi",
    "  mkdir -p \"/import/$hid\"",
    "  printf 'sample,taxonA,taxonB\\nS1,10,20\\nS2,30,40\\n' > \"/import/$hid/data.csv\"",
    "  echo \"/import/$hid/data.csv\"",
    "done",
    "exit $status"
), file.path(stub_dir, "get"))
Sys.chmod(file.path(stub_dir, "get"), "0755")

# get_user_history prints json.dumps(bioblend show_history(..., contents=True)),
# i.e. an object with a "contents" array, not a bare array. Every entry carries
# the history id the picker selects on, and collection rows additionally carry
# element_identifier / history_content_type.
writeLines(c(
    "#!/bin/sh",
    "cat <<'JSON'",
    "{",
    " \"id\": \"abc123\",",
    " \"name\": \"test history\",",
    " \"contents\": [",
    "  {\"hid\": 1, \"name\": \"otu_table\", \"extension\": \"csv\",",
    "   \"visible\": true, \"history_content_type\": \"dataset\"},",
    "  {\"hid\": 2, \"name\": \"abundance_table\", \"extension\": \"csv\",",
    "   \"visible\": true, \"history_content_type\": \"dataset\"},",
    "  {\"hid\": 3, \"name\": \"sample_batch\", \"extension\": \"csv\",",
    "   \"visible\": true, \"history_content_type\": \"dataset_collection\"},",
    "  {\"hid\": 4, \"name\": \"abundance_table\", \"extension\": \"csv\",",
    "   \"visible\": true, \"history_content_type\": \"dataset_collection_element\",",
    "   \"element_identifier\": \"sample_one\"}",
    " ]",
    "}",
    "JSON"
), file.path(stub_dir, "get_user_history"))
Sys.chmod(file.path(stub_dir, "get_user_history"), "0755")

writeLines("#!/bin/sh\nexit 0\n", file.path(stub_dir, "put"))
Sys.chmod(file.path(stub_dir, "put"), "0755")

Sys.setenv(
    HISTORY_ID = "abc123",
    API_KEY = "test-key",
    GALAXY_IE_GET = file.path(stub_dir, "get"),
    GALAXY_IE_PUT = file.path(stub_dir, "put"),
    GALAXY_IE_GET_USER_HISTORY = file.path(stub_dir, "get_user_history"),
    CMINET_INPUT = "",
    CMINET_WEIGHTED_NETWORK = ""
)

# --------------------------------------------------------------------------
# Load the app's helper, exactly as app.R does.
# --------------------------------------------------------------------------
helper <- file.path(app_dir, "galaxy_ie.R")
ok("galaxy_ie.R exists", file.exists(helper))
if (!file.exists(helper)) {
    quit(status = 1L)
}
source(helper)
galaxy_ie_app("cminet", "CMINET_OUTPUT_DIR", "CMINET_INPUT")

cat("\n== readiness\n")
ok("galaxy_ie_can_read() is TRUE inside Galaxy", isTRUE(galaxy_ie_can_read()))
ok("galaxy_ie_ready() is TRUE inside Galaxy", isTRUE(galaxy_ie_ready()))

# The buttons must disappear outside Galaxy, or they would show up for anyone
# running the app locally.
saved <- Sys.getenv(c("HISTORY_ID", "API_KEY"))
Sys.unsetenv(c("HISTORY_ID", "API_KEY"))
ok("the picker UI is NULL outside Galaxy", is.null(galaxy_ie_picker_ui()))
ok("the send UI is NULL outside Galaxy", is.null(galaxy_ie_send_ui()))
ok("can_read() is FALSE outside Galaxy", isFALSE(galaxy_ie_can_read()))
do.call(Sys.setenv, as.list(saved))

# --------------------------------------------------------------------------
# Every download the CMiNet UI offers has to be registered, otherwise a "Send to
# Galaxy" button would appear next to it and do nothing (or fail).
# --------------------------------------------------------------------------
cat("\n== download registry\n")
app_source <- paste(readLines(file.path(app_dir, "app.R"), warn = FALSE), collapse = "\n")

# The downloads the UI actually offers. Each needs both a button and a registered
# handler: the button is what the generic injection script attaches to, and the
# handler is what regenerates the file when the button is pressed.
ui_downloads <- c(
    "downloadWeightedNetwork",   # weighted_network_<date>.csv
    "downloadEdgeList",          # edge_list_<date>.csv
    "downloadBinaryFolder",      # Binary_Network_<date>.zip
    "downloadNetworkFolder",     # Network_<date>.zip
    "downloadSampleData",        # sample_data.csv
    "downloadSampleNet"          # weighted_network.csv
)
# downloadFinalWeightedNetwork is a handler upstream never gave a downloadButton,
# so it is registered but currently unreachable. Registering it anyway costs
# nothing and means it starts working the moment a button is added.
registered_only <- "downloadFinalWeightedNetwork"
expected_downloads <- c(ui_downloads, registered_only)

for (id in ui_downloads) {
    ok(sprintf("%s is registered", id),
       grepl(sprintf('galaxy_ie_download_with(downloads, "%s"', id), app_source, fixed = TRUE))
    ok(sprintf("%s has a download button in the UI", id),
       grepl(sprintf('downloadButton("%s"', id), app_source, fixed = TRUE))
}
ok(sprintf("%s is registered", registered_only),
   grepl(sprintf('galaxy_ie_download_with(downloads, "%s"', registered_only),
        app_source, fixed = TRUE))
ok(sprintf("%s has no downloadButton (upstream dead handler)", registered_only),
   !grepl(sprintf('downloadButton("%s"', registered_only), app_source, fixed = TRUE))

# Every downloadButton in the UI must be registered: this is the direction that
# silently breaks if a handler is forgotten, because the button would appear and
# then do nothing.
ui_ids <- unique(unlist(regmatches(
    app_source, gregexpr('downloadButton\\("[a-zA-Z0-9_]+"', app_source)
)))
ui_ids <- sub('^downloadButton\\("', "", ui_ids)
ui_ids <- sub('"$', "", ui_ids)
for (id in ui_ids) {
    ok(sprintf('downloadButton("%s") has a registered handler', id), id %in% expected_downloads)
}

# The registry itself: a content function that regenerates the exact file.
# The registry is an environment, not a list: galaxy_ie_register() assigns into it.
registry <- galaxy_ie_registry()
galaxy_ie_download_with(
    registry, "probe",
    filename = function() "probe.csv",
    content = function(file) writeLines(c("a,b", "1,2"), file)
)
ok("the probe is registered under its output id",
   exists("probe", envir = registry, inherits = FALSE))
ok("the registry keeps the filename", identical(registry$probe$filename(), "probe.csv"))

produced <- file.path(tempdir(), "probe.csv")
registry$probe$content(produced)
ok("the registered content function reproduces the file",
   identical(readLines(produced), c("a,b", "1,2")))

# The shared injection script is deliberately generic: it finds every shiny
# download anchor and reads the output id off it, so a download gets a button
# without app.R's UI being touched. What has to hold is that it finds the anchors
# and reports the id back to the namespaced input the observer listens on.
cat("\n== button injection\n")
js <- galaxy_ie_send_js()
ok("the injection script targets shiny download links",
   grepl("shiny-download-link", js, fixed = TRUE))
ok("the script reads the output id off the download link",
   grepl("w2=", js, fixed = TRUE))
ok("the script reports the id to a namespaced Shiny input",
   grepl("cminet_galaxy_send", js, fixed = TRUE))
ok("the injection script is namespaced per app",
   grepl("cminet", js, fixed = TRUE))
ok("no unsubstituted format placeholder is left",
   !grepl("%1$s", js, fixed = TRUE) && !grepl("%s", js, fixed = TRUE))
# Downloads are rendered as panels are shown, so injection has to keep watching.
ok("the script re-injects when downloads appear later",
   grepl("MutationObserver", js, fixed = TRUE))

# Every registered id has to be reachable through that generic script, i.e. the
# ids in the registry are plain output ids.
registry2 <- galaxy_ie_registry()
galaxy_ie_download_with(registry2, "netFile", filename = function() "n.csv",
                        content = function(file) writeLines("x", file))
ok("registry keys are plain output ids",
   identical(names(registry2), "netFile"))

# --------------------------------------------------------------------------
# History picker.
# --------------------------------------------------------------------------
cat("\n== history picker\n")
entries <- galaxy_ie_history_entries()
ok("the history is listed", !is.null(entries) && length(entries) > 0)
ok("datasets are listed", any(grepl("otu_table", entries, fixed = TRUE)))
ok("collection elements are listed",
   any(grepl("sample_one", entries, fixed = TRUE)))
ok("entries carry their history id in the label",
   any(grepl("^#1: ", entries)))
ok("the collection itself is marked as such",
   any(grepl("[collection]", entries, fixed = TRUE)))
ok("a collection element shows its element identifier",
   any(grepl("abundance_table / sample_one", entries, fixed = TRUE)))
ok("every entry is selectable by its history id",
   all(names(entries) %in% c("1", "2", "3", "4")))

ok("the picker UI renders inside Galaxy", !is.null(galaxy_ie_picker_ui()))

cat("\n== import\n")
result <- galaxy_ie_import(c("1" = "otu_table"))
ok("importing a dataset succeeds", isTRUE(result$ok))
ok("the input variable is repointed at the imported file",
   nzchar(Sys.getenv("CMINET_INPUT", unset = "")))
if (isTRUE(result$ok)) {
    imported <- Sys.getenv("CMINET_INPUT", unset = "")
    ok("the imported file exists", file.exists(imported))
    imported_df <- read.csv(imported, row.names = 1)
    # all.equal, not identical: read.csv gives an integer matrix and the
    # expected value is double.
    ok("the imported content comes from the history",
       isTRUE(all.equal(unname(as.matrix(imported_df)),
                        # byrow: the CSV holds S1=10,20 and S2=30,40.
                        matrix(c(10, 20, 30, 40), nrow = 2, byrow = TRUE,
                               dimnames = NULL))))
}

cat("\n== import of a collection element\n")
Sys.setenv(CMINET_INPUT = "")
result_element <- galaxy_ie_import(c("4" = "abundance_table"))
ok("a collection element imports like any dataset", isTRUE(result_element$ok))
ok("a collection element repoints the input",
   nzchar(Sys.getenv("CMINET_INPUT", unset = "")))

cat("\n== failures are reported, not swallowed\n")
Sys.setenv(CMINET_INPUT = "")
result_bad <- suppressWarnings(galaxy_ie_import(c("999" = "missing")))
ok("a failing import reports failure", isFALSE(result_bad$ok))
ok("a failing import leaves the input alone", !nzchar(Sys.getenv("CMINET_INPUT", unset = "")))

result_many <- galaxy_ie_import(c("1" = "otu_table", "2" = "abundance_table"))
ok("importing several files at once is refused", isFALSE(result_many$ok))
ok("the refusal explains why", grepl("one", result_many$message, ignore.case = TRUE))

# --------------------------------------------------------------------------
# The app's own input resolution has to agree with the picker: an imported file
# must be readable through the same path a browser upload takes.
# --------------------------------------------------------------------------
cat("\n== app input resolution\n")
source(file.path(app_dir, "galaxy_helpers.R"))
ok("no staged input resolves to NULL", is.null(cminet_resolve_input(NULL, "")))
ok("a missing staged file resolves to NULL",
   is.null(cminet_resolve_input(NULL, file.path(tempdir(), "does-not-exist.csv"))))

Sys.setenv(CMINET_INPUT = "")
staged <- file.path(tempdir(), "staged.csv")
writeLines(c("sample,taxonA", "S1,1"), staged)
Sys.setenv(CMINET_INPUT = staged)
ok("the staged dataset resolves", identical(cminet_resolve_input(NULL, staged), staged))

# A file the user picked in the browser wins over the staged one.
browser <- file.path(tempdir(), "browser.csv")
writeLines(c("sample,taxonB", "S1,1"), browser)
ok("a browser upload wins over the staged file",
   identical(cminet_resolve_input(list(datapath = browser), staged), browser))

# The abundance matrix the picker imports must satisfy what the app's reactive
# actually does with it.
Sys.setenv(CMINET_INPUT = "")
ok("a freshly imported dataset replaces the staged one",
   isTRUE(galaxy_ie_import(c("1" = "otu_table"))$ok))
fresh <- read.csv(Sys.getenv("CMINET_INPUT", unset = ""), row.names = 1,
                  check.names = FALSE)
ok("the imported matrix has samples in the rows", nrow(fresh) > 1)
ok("the imported matrix has taxa in the columns", ncol(fresh) > 1)

# --------------------------------------------------------------------------
# Both tool inputs are optional, so the whole path has to survive having none.
# The app's reactives guard on req(path), which is what cminet_resolve_input()
# feeds: with nothing staged it has to return NULL and let req() stop the panel,
# never try to read a missing file.
# --------------------------------------------------------------------------
cat("\n== no input provided\n")
Sys.unsetenv(c("CMINET_INPUT", "CMINET_WEIGHTED_NETWORK"))
ok("with nothing staged, the abundance input resolves to NULL",
   is.null(cminet_resolve_input(NULL, Sys.getenv("CMINET_INPUT", unset = ""))))
ok("with nothing staged, the weighted network input resolves to NULL",
   is.null(cminet_resolve_input(NULL, Sys.getenv("CMINET_WEIGHTED_NETWORK", unset = ""))))
ok("a browser upload still resolves with nothing staged",
   identical(cminet_resolve_input(list(datapath = staged), ""), staged))

# Every download must remain registered and get its button whether or not data was
# staged: the buttons are driven by the registry, not by the presence of an input.
ok("the downloads stay registered without any input",
   length(expected_downloads) == 7L)
ok("button injection does not depend on an input being staged",
   grepl("shiny-download-link", galaxy_ie_send_js(), fixed = TRUE))

# Importing from the history has to work with nothing staged too, because that is
# exactly the case where a user starts from an empty history view.
Sys.unsetenv("CMINET_INPUT")
ok("importing from the history works without a staged dataset",
   isTRUE(galaxy_ie_import(c("1" = "otu_table"))$ok))
ok("the imported file is used as the input",
   nzchar(Sys.getenv("CMINET_INPUT", unset = "")))
Sys.unsetenv("CMINET_INPUT")

cat(sprintf("\n%d failed check(s)\n", failures))
quit(status = if (failures > 0L) 1L else 0L)
