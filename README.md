# Galaxy Interactive Tool images

Docker packaging of Shiny applications as
[Galaxy Interactive Tools](https://docs.galaxyproject.org/en/latest/dev/interactive_tools.html).

Each tool gets its own self-contained subdirectory with everything needed to
build, run and register it:

| Directory | App (upstream) | Fork @ `galaxy-it-adaptations` | Container image |
| --- | --- | --- | --- |
| [`metadavis/`](metadavis/) | [GudaLab/MetaDAVis](https://github.com/GudaLab/MetaDAVis) | [paulzierep/MetaDAVis](https://github.com/paulzierep/MetaDAVis/tree/galaxy-it-adaptations) | `quay.io/galaxy/metadavis-gxit` |
| [`microbiomeprofiler/`](microbiomeprofiler/) | [YuLab-SMU/MicrobiomeProfiler](https://github.com/YuLab-SMU/MicrobiomeProfiler) | [paulzierep/MicrobiomeProfiler](https://github.com/paulzierep/MicrobiomeProfiler/tree/galaxy-it-adaptations) | `quay.io/galaxy/microbiomeprofiler-gxit` |
| [`cminet/`](cminet/) | [solislemuslab/CMiNetShinyAPP](https://github.com/solislemuslab/CMiNetShinyAPP) | [paulzierep/CMiNetShinyAPP](https://github.com/paulzierep/CMiNetShinyAPP/tree/galaxy-it-adaptations) | `quay.io/galaxy/cminet-gxit` |

## Application forks

This repository packages the images; it does **not** carry any application
source. Every Dockerfile clones its app from GitHub while the image is built, so
this repository stays a small set of Dockerfiles, R dependency scripts and Galaxy
tool wrappers.

The Galaxy-specific behaviour cannot live entirely in a tool XML: a Shiny app has
to read staged datasets from the job directory, and push results back into the
user's history. That is application code, so each tool has a **fork** of its
upstream app, and all Galaxy adaptations live on a single branch in each fork:

| Fork | Branch | What the branch adds |
| --- | --- | --- |
| [paulzierep/MetaDAVis](https://github.com/paulzierep/MetaDAVis/tree/galaxy-it-adaptations) | [`galaxy-it-adaptations`](https://github.com/paulzierep/MetaDAVis/tree/galaxy-it-adaptations) | A **"Galaxy input"** file format (OTU table + taxonomy + metadata staged by the tool) alongside the app's own input, and the **send-to-Galaxy** download handler. |
| [paulzierep/MicrobiomeProfiler](https://github.com/paulzierep/MicrobiomeProfiler/tree/galaxy-it-adaptations) | [`galaxy-it-adaptations`](https://github.com/paulzierep/MicrobiomeProfiler/tree/galaxy-it-adaptations) | The **send-to-Galaxy** button for the app's download outputs. Needed in particular because the app is installed as an R package, where the async upload cannot re-source a helper file at runtime. |
| [paulzierep/CMiNetShinyAPP](https://github.com/paulzierep/CMiNetShinyAPP/tree/galaxy-it-adaptations) | [`galaxy-it-adaptations`](https://github.com/paulzierep/CMiNetShinyAPP/tree/galaxy-it-adaptations) | The **"Send to Galaxy"** buttons, the **import-from-history** picker, and the **Galaxy input** format for the abundance matrix and the weighted network. |

All three branches are cut from the corresponding fork branch that preceded them
(`galaxy-input`, `galaxy-output`, `galaxy-integration`); those earlier branches
are kept as-is. `galaxy-it-adaptations` is the one branch the Dockerfiles build
from, so a single place controls what Galaxy runs for every tool.

The build never reads a local checkout: each Dockerfile clones the fork at build
time, so a forked app's change shows up in the image without anything being
committed here.

## Quick start

```bash
cd metadavis           # or: cd microbiomeprofiler, or: cd cminet
make docker            # build + tag the image
```

The application repositories are **not vendored**, and nothing app-related is
written into this build tree: each Dockerfile shallow-clones its app while the
image is built. The Makefiles can additionally clone a copy *outside* the
repository, for the tests to read:

```bash
make refresh_deps      # re-clone to /tmp/microbiome-ITs/<tool>/, to pick up an app update
make clean_deps        # remove that copy
```

`DEPS_ROOT` chooses where it goes (`make refresh_deps DEPS_ROOT=/some/path`).

## What is in a tool directory

```
<tool>/
├── Dockerfile                     # the image
├── Makefile                       # deps / build / run / push helpers
├── .dockerignore
├── .gitignore
├── README.md                      # build, register, test, results
├── docker/
│   ├── install.R                  # dependency install + verification
│   └── entrypoint.sh              # starts the app on the declared port
└── gxit/
    └── interactivetool_*.xml      # the Galaxy tool wrapper

tests/                             # optional; run with `make test-fast`
```

## Adding another tool

1. `mkdir <tool> && cd <tool>`, then copy the layout above.
2. Fork the application, put the Galaxy adaptations on a branch (here all three
   use `galaxy-it-adaptations`), and point `UPSTREAM_URL` / `UPSTREAM_REF` /
   `UPSTREAM_SENTINEL` at that fork and branch. Pick a sentinel file that only
   exists on the Galaxy branch, so `make deps` can tell an adapted checkout from
   a plain upstream one.
3. Write `docker/install.R` so that it installs the dependencies *and* verifies
   them at the end. `BiocManager::install()` and `install.packages()` both report
   per-package failures while still exiting 0, so an unverified build can easily
   ship a broken image.
4. Write the `<tool>/gxit/*.xml` wrapper. The container port, `ARG PORT` in the
   Dockerfile and `internal_port` in the Makefile all have to agree - Galaxy
   publishes exactly the port declared in `<entry_point>`.
5. Add a `.dockerignore` entry for the deps directory and for `local_*/`.
6. Add a build job and a release job to `.github/workflows/ci.yml`, and the tool
   directory to the path filters.

## Testing in Galaxy

`planemo serve` with a fixed port, mirroring the in-image port:

```bash
planemo serve --host 0.0.0.0 --port 8080 <tool>/gxit/
```

## Registry and publishing

Release images are pushed by GitHub Actions to **`quay.io/galaxy`**, configured by
the single `IMAGE_REPOSITORY` value in the workflows. Each published image gets
both the requested tag and `:latest`, because that is what the tool XMLs ask for:

```xml
<container type="docker">quay.io/galaxy/metadavis-gxit:latest</container>
```

The release workflow authenticates with the repository's `QUAY_OAUTH_TOKEN`
secret, under the GitHub Environment `quay.io`.

### Building and pushing one image by hand

Use **Actions → Container images → Run workflow**, pick the `image`, and set the
`tag`. That builds the image and pushes it to `quay.io/galaxy`, which is the
normal way to publish a new image:

| image | pushes |
| --- | --- |
| `metadavis` | `quay.io/galaxy/metadavis-gxit:<tag>` and `:latest` |
| `microbiomeprofiler` | `quay.io/galaxy/microbiomeprofiler-gxit:<tag>` and `:latest` |
| `cminet` | `quay.io/galaxy/cminet-gxit:<tag>` and `:latest` |

The same happens automatically when a GitHub **release** is published.

### Automatic builds

Pull requests and pushes to `main` build the images of the tool directories
that changed, but **do not push** - those jobs only prove the Dockerfile still
builds.

An application repository can request a release build with a `repository_dispatch`
event, which is the way to publish after changing a fork:

```json
{"event_type":"image-release","client_payload":{"image":"metadavis","tag":"1.0.0"}}
```

Use `microbiomeprofiler` or `cminet` for those images. Sending this event from
another repository requires a token with permission to dispatch workflows in this
repository.

Docker Hub helpers remain available in each tool Makefile for manual publishing:

```bash
make push_hub USERNAME=... DOCKERHUB_PASSWORD=...
```

The password can also be read from a `.password` file in the tool directory
(gitignored). Never commit credentials.

## Notes

- Results are sent back into the user's Galaxy history rather than downloaded by
  hand: the images ship `galaxy-ie-helpers`, and each tool XML declares a
  collection over its outputs directory. See the per-tool READMEs for the details.
- MicrobiomeProfiler needs outbound internet access at runtime (KEGG REST,
  eggNOG, SMPDB, Disbiome, HMDB). MetaDAVis is self-contained; CMiNet needs
  internet only for its optional lookups.
