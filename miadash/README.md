# miaDash as a Galaxy Interactive Tool

Docker packaging of [miaDash](https://github.com/microbiome/miaDash)
(microbiome project), the Microbiome Analysis Dashboard - an R package that
contains a Shiny application for importing, manipulating, analysing and
visualising microbiome data as `TreeSummarizedExperiment` objects - built for
the Galaxy
[Interactive Tools](https://training.galaxyproject.org/training-material/topics/dev/tutorials/interactive-tools/tutorial.html)
framework.

This mirrors the MicrobiomeProfiler image next door in this repository: both
upstream projects are R packages with the app inside, so the app is installed
rather than run from a directory:

| | MicrobiomeProfiler | miaDash |
| --- | --- | --- |
| how it is run | `MicrobiomeProfiler::run_MicrobiomeProfiler()` | `miaDash::miaDash()` |
| input | an annotation table with a gene (KO) column | optional abundance / colData / rowData tables and a Newick tree |
| built on | clusterProfiler + Shiny | iSEE + iSEEtree (the miaverse stack) |
| network at runtime | **yes** - KEGG, eggNOG, ... | no - analyses run locally on the staged data |

## Layout

```
.
├── Dockerfile                          # build image: deps layer, clone, install, verify
├── Makefile                            # build / run / test helpers
├── docker/
│   ├── install.R                       # pinned R dependencies + app verification
│   └── entrypoint.sh                   # stages inputs, writes the startup log, runs the app
├── gxit/
│   └── interactivetool_miadash.xml     # the Galaxy tool wrapper
└── tests/
    ├── smoke_test.R                    # R stack, app object, Galaxy wiring, staged import
    └── fixtures/                       # small raw tables the tests stage as inputs
```

The upstream repository is **not vendored**. The Dockerfile shallow-clones the
`galaxy-it-adaptations` branch of the fork
([paulzierep/miaDash](https://github.com/paulzierep/miaDash)) while building the
image; that branch carries the *Send to Galaxy* buttons and the staged-input
import (`R/galaxy_ie.R`, `R/galaxy_input.R`). The clone layer is pinned to the
commit the branch points at (`APP_REVISION`, passed by `make docker`), so a new
app commit actually invalidates the layer instead of being silently cached.

## Build

```bash
make docker
```

Base image is `rocker/shiny-verse:4.6.1` (R 4.6.1, Bioconductor 3.23). It has
to be that pairing: miaDash's `DESCRIPTION` requires `iSEE >= 2.19.4`, and
Bioconductor 3.20 ships 2.18.0. CRAN is pinned to the Posit Package Manager
snapshot `2026-10-01` in `docker/install.R` (the base image's `latest` is not
reproducible); the snapshot serves Linux binaries, so most CRAN packages
install in seconds and the build time is dominated by the Bioconductor chain -
expect 30-60 minutes for a first build.

The build is split in two layers on purpose: `MIADASH_DEPS_ONLY=1` installs the
dependencies (the expensive half, cached on `install.R` alone) *before* the app
is cloned, then `MIADASH_APP_ONLY=1` installs and verifies the app package. A
new app commit therefore costs a minute, not an hour.

`install.R` does not stop at "the package is on disk": it calls
`loadNamespace()` on every required package, enforces the iSEE floor, builds
`miaDash::miaDash()` and checks it returns a working app object, and verifies
the installed package actually contains the Galaxy adaptation files - which is
what catches a clone of plain upstream instead of the fork branch. A build that
produces an unloadable app fails instead of shipping.

## Test it

```bash
make deps          # clone the fork (build/test input only, kept out of the tree)
make docker        # build the image locally
make test-fast     # smoke test + entry point input handling, no Galaxy needed
make check         # start the app and poll the port it answers on
```

The smoke test runs headless inside the container: package loads, the app
object, the *Send to Galaxy* wiring (including that no button is offered
outside Galaxy), and the staged-input import end to end against
`tests/fixtures/`. The startup test runs the real entry point with
`MIADASH_STARTUP_ONLY=1` and asserts the staged files are reported in
`miadash_startup.txt` and that untouched optional inputs are reported as
absent.

## Run it standalone

```bash
make d        # detached, http://127.0.0.1:8080
make log      # follow the startup log
make stop
```

To stage datasets by hand (which is exactly what the Galaxy wrapper does):

```bash
mkdir -p /tmp/miadash-job/miadash_inputs
cp tests/fixtures/assay.tsv   /tmp/miadash-job/miadash_inputs/assay.tsv
cp tests/fixtures/coldata.tsv /tmp/miadash-job/miadash_inputs/coldata.tsv
docker run --rm -p 127.0.0.1:8080:8080 \
    -e MIADASH_JOB_DIR=/tmp/miadash-job \
    miadash-gxit:latest
```

The app opens with those tables already imported. Outside Galaxy there is no
history, so no *Send to Galaxy* button appears - that is deliberate, the upload
cannot work without an API key.

## Register it in Galaxy

1. `make docker` (builds and tags `quay.io/galaxy/miadash-gxit:latest`).
2. Copy `gxit/interactivetool_miadash.xml` into Galaxy's `tools/interactive/`
   directory.
3. Enable interactive tools in `config/galaxy.yml`:

   ```yaml
   interactivetools_enable: true
   ```

The port in `<entry_point>` (8080) matches `ARG PORT` in the Dockerfile and
`internal_port` in the Makefile; all three are kept in sync.

## Galaxy tool

`gxit/interactivetool_miadash.xml` declares:

| | |
|---|---|
| Container | `quay.io/galaxy/miadash-gxit:latest` |
| Port | 8080 |
| Inputs | abundance table, sample data (colData), taxa data (rowData), Newick tree - all optional, plus the "derive taxa from row names" switch |
| Outputs | `miadash_startup.txt` plus a *miaDash results* collection |

All inputs are optional: with none selected the app starts empty and the user
can upload from the browser or use the bundled example data. The tables are
staged as `miadash_inputs/` and handed to the app as environment variables
(`MIADASH_ASSAY`, `MIADASH_COLDATA`, `MIADASH_ROWDATA`, `MIADASH_ROWTREE`);
the entry point only exports the variables whose staged file is non-empty.

**Table layout** (tab-separated, first column is the ids column):

- abundance: taxa in rows, header row with sample ids
- colData: samples in rows, ids matching the abundance header
- rowData: taxa in rows, ids matching the abundance row names
- tree: Newick, tip labels matching the taxon ids

Anything omitted can still be added inside the app through the *Import* panel,
which takes the same layouts from a browser upload.

## Results

Results are sent back into the Galaxy history rather than downloaded by hand:
every download output in the app gets a *Send to Galaxy* button next to it (the
fork's `galaxy-it-adaptations` branch), which re-runs the very content function
the download button uses and uploads the byte-identical file via
`galaxy-ie-helpers`. The tool XML declares a collection over
`miadash_outputs/`, so sent files appear as *miaDash results* - even if the
direct upload fails, the collection is populated when the job ends, so nothing
sent during a session is lost.

The button injection uses an allow-list of registered output ids, so iSEE's own
internal download links (memory export and friends) never get a button.

## Citation

> Benedetti G, Seraidarian E, Pralas T, Jeba A, Borman T, Lahti L (2025).
> iSEEtree: interactive explorer for hierarchical data. *Bioinformatics
> Advances*. doi: [10.1093/bioadv/vbaf107](https://doi.org/10.1093/bioadv/vbaf107)
