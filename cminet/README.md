# CMiNet as a Galaxy Interactive Tool

Packages the [CMiNet Shiny app](https://github.com/solislemuslab/CMiNetShinyAPP) as
a Galaxy Interactive Tool (GxIT) image, in the same shape as the `metadavis` and
`microbiomeprofiler` wrappers in this repository.

The app itself is **not vendored**. It is cloned during the image build from the
fork's `galaxy-it-adaptations` branch, which carries the Galaxy integration:

* a **Send to Galaxy** button next to every download, backed by a download
  registry rather than a silent background upload
* an **import-from-history** picker that downloads a dataset or collection element
  from the current history into the app's abundance-matrix input
* the `CMINET_INPUT` / `CMINET_WEIGHTED_NETWORK` / `CMINET_OUTPUT_DIR` environment
  contract used by the tool wrapper

## Layout

```
cminet/
├── Dockerfile                        image: R 4.4.3 + CMiNet stack + galaxy_ie_helpers
├── Makefile                          build, test and push targets
├── docker/
│   ├── install.R                     pinned R dependencies, with verification
│   └── entrypoint.sh                 serves the app in the Galaxy job directory
├── gxit/
│   └── interactivetool_cminet.xml    the Galaxy tool wrapper
└── tests/
    ├── smoke_test.R                  R stack, example data, helper files
    └── galaxy_ie_test.R              registry, button injection, history picker
```

## Why the dependency install verifies what it installed

`docker/install.R` does not stop at "the package is on disk". It calls
`loadNamespace()` for every required package, because a package can install
cleanly and still be unloadable.

That is not hypothetical: the binary `igraph` served by the pinned Posit snapshot
links against `libglpk.so.40`, which `rocker/shiny-verse` does not ship. Without
`libglpk40` in the image, `install.packages()` reports `DONE` and only a later
`requireNamespace()` fails with `unable to load shared object ... libglpk.so.40`.
Because CMiNet imports `igraph` through `huge`, that breaks the whole app.

## Usage

Build and test:

```bash
make deps          # clone the app fork (build input only)
make docker        # build the image locally
make test-fast     # smoke test + Galaxy integration test, no Galaxy needed
make check         # start the app and poll the port it answers on
```

Run it standalone, without Galaxy:

```bash
make d
# then open http://127.0.0.1:8080
```

To stage a dataset by hand (which is what the Galaxy wrapper does):

```bash
docker run --rm -p 127.0.0.1:8080:8080 \
    -e CMINET_JOB_DIR=/tmp/cminet \
    -v "$PWD/my_table.csv:/tmp/cminet/cminet_inputs/abundance:ro" \
    cminet-gxit:latest
```

Outside Galaxy there is no history, so the picker is not rendered and no
*Send to Galaxy* button appears. That is deliberate: neither works without an
API key, so offering them outside Galaxy would only produce errors.

## Galaxy tool

`gxit/interactivetool_cminet.xml` declares:

| | |
|---|---|
| Container | `quay.io/galaxy/cminet-gxit:latest` |
| Port | 8080 |
| Input | abundance matrix (required), weighted network (optional) |
| Outputs | `cminet_startup.txt` plus a *CMiNet results* collection |

The results collection is populated from `cminet_outputs/`, which only fills up as
you press *Send to Galaxy* on results during the session. The collection is
therefore empty unless you send something, and the job produces no results of its
own — CMiNet is interactive by nature, so what you send is what you get. The same
is true of the other wrappers in this repository.

## Image contents

* Base: `rocker/shiny-verse:4.4.3` (R 4.4.3, Bioconductor 3.20, shiny 1.10.0,
  ggplot2 3.5.2)
* CRAN from the Posit snapshot `2025-04-10`, not live CRAN, because Bioconductor
  3.20's WGCNA is built against the ggplot2 3.x internals
* `SpiecEasi` → `SPRING` → `CMiNet` from GitHub, in that order, because SPRING
  imports SpiecEasi and CMiNet imports both
* `galaxy-ie-helpers` in `/opt/galaxy_ie_helpers`, providing the `get`, `put` and
  `get_user_history` commands the app shells out to