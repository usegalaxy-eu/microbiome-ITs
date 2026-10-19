---
name: microbiome-its
description: Develop and locally test Galaxy Interactive Tools (Shiny apps) in this repository — building/tagging the Docker image, running a dev Galaxy with planemo (the required --biocontainers flag), and validating an interactive-tool job end-to-end.
---

# Working on microbiome-ITs (Galaxy Interactive Tools)

Each tool lives in its own directory (`cminet/`, `microbiomeprofiler/`, `miadash/`, …) with this layout:

```
<tool>/
├── Dockerfile               # builds the Shiny app image; clones the app repo at build time
├── docker/install.R         # installs app + deps AND verifies them (fail the build on bad install)
├── docker/entrypoint.sh     # stages Galaxy inputs, launches Shiny on 0.0.0.0:8080, collects results
├── gxit/interactivetool_<tool>.xml   # Galaxy tool wrapper (defines container tag, inputs, outputs)
├── Makefile                 # build / run / test / smoke targets
├── README.md
├── .dockerignore            # excludes deps checkout and local_*/
└── tests/                   # smoke test + tiny fixtures (never >1 MB)
```

## Port conventions (keep consistent across XML, Dockerfile, Makefile)

- App listens on **8080** (`ARG PORT` in Dockerfile, `GALAXY_WEB_PORT`/listen in entrypoint, `EXPOSE`).
- Results dir: entrypoint exports `MIADASH_*_OUTPUT_DIR` (or equivalent) into the job working dir; the XML declares a `<collection>` output plus a startup-log dataset.

## Local end-to-end test (THIS is the step people get wrong)

Build and tag first (the XML `<container>` references the quay tag, so BOTH tags must exist locally):

```sh
make docker                          # docker build -t <tool>-gxit:latest
docker tag <tool>-gxit:latest quay.io/galaxy/<tool>-gxit:latest
docker tag <tool>-gxit:latest quay.io/galaxy/<tool>-gxit:1.0.0   # keep in sync with Makefile IMAGE_VERSION
```

Serve a dev Galaxy against the local Galaxy checkout:

```sh
planemo serve --galaxy_root ~/git/galaxy --port 8080 --docker --biocontainers <tool>/gxit/
```

**`--docker --biocontainers` is mandatory.** Without it, planemo runs the job
directly on the host (`LocalRunner`), so the entrypoint binary declared by the
tool does not exist and the job dies with `exit code 127 … entrypoint: No such
file or directory`. With the flags, planemo configures Docker container
resolvers and Galaxy runs the job inside our image — `docker run` is used even
for explicitly-declared `<container>` tags.

Then in the browser (http://127.0.0.1:8080):

1. Upload the fixtures from `<tool>/tests/` as the matching datatypes (tabular/csv for abundance + coldata, newick for the tree).
2. Run the interactive tool from the tool panel; a "Start … / Interactive Tool" job appears.
3. Check the startup-log dataset in the history: it must list staged inputs (`label: +path` grep pattern; labels are column-padded) and no errors.
4. Open the IT session (gx-it-proxy, random high port) — link is on the dataset / "Interactive Environments" page.
5. Inside the app, use Send-to-Galaxy; the results collection must appear in the history.

Useful checks while it runs:

```sh
docker ps                                # job container = quay.io/galaxy/<tool>-gxit:latest
docker logs <cid>                        # entrypoint staging + Shiny startup
curl -s localhost:59151                  # gx-it-proxy default base (check serve log for the exact port)
```

Kill stale servers before re-serving (`pkill -f 'planemo[ ]serve'`, kill leftover
gunicorn/celery children of `galaxy/run.sh` by PID — plain `pkill -f galaxy`
matches the calling shell itself).

## Fast validation without a browser

- `make smoke` / `make test` — run the container standalone with test fixtures, assert on startup log + app HTTP 200 (`make check`).
- `planemo lint <tool>/gxit/` — must be INFO/CHECK only.
- `make startup-test` (where provided) — `MIADASH_STARTUP_ONLY=1`-style seam in the entrypoint; grep startup log with `grep -E "label: +path"` (whitespace-tolerant).

## Lessons learned (miaDash port, 2026-10)

- **`library(miaDash)` must precede any `miaDash()` call.** The app calls shiny's
  `addResourcePath()` unqualified while its NAMESPACE only imports `stopApp`;
  `pkg::fun()` alone fails with `could not find function "addResourcePath"`.
  Apply in install.R verification, entrypoint, and smoke test.
- **Runtime system libs**: mirror cminet's (`libglpk40`, `libglib2.0-0`,
  `libgmp10`) and add `libgsl-dev` when any Bioc dep compiles Fortran/GSL code
  (e.g. `DirichletMultinomial`).
- **Pin CRAN** to a PPM snapshot matching the base image's R minor version.
  Base image must satisfy the app's Bioconductor floor (miaDash needs
  `iSEE >= 2.19.4` ⇒ R 4.6 / Bioc 3.23 ⇒ `rocker/shiny-verse:4.6.1`).
- **Install deps before cloning the app**: two-pass `install.R`
  (`APP_STAGE=deps` → `git clone` → `APP_STAGE=app`) so the heavy layer caches.
  Pin the clone with a build arg (`APP_REVISION`); do **not** leave a
  `CACHE_BUSTER` ARG that nothing reads — it defeats caching and breaks under
  `set -u`.
- Install Suggests that the UI offers unconditionally (e.g. `philr`).
- Dockerfile ENTRYPOINT exec form + `set -euo pipefail`; test seams via env var
  (`…_STARTUP_ONLY=1`) keep the entrypoint testable with `docker run`.
