# Galaxy Interactive Tool images

Docker packaging of Shiny applications as
[Galaxy Interactive Tools](https://docs.galaxyproject.org/en/latest/dev/interactive_tools.html).

Each tool gets its own self-contained subdirectory with everything needed to
build, run and register it:

| Directory | Upstream | Container image |
| --- | --- | --- |
| [`metadavis/`](metadavis/) | [GudaLab/MetaDAVis](https://github.com/GudaLab/MetaDAVis) | `paulzierep/metadavis-gxit` |
| [`microbiomeprofiler/`](microbiomeprofiler/) | [yulab-smu/microbiomeprofiler](https://github.com/yulab-smu/microbiomeprofiler) | `paulzierep/microbiomeprofiler-gxit` |

## Quick start

```bash
cd metadavis           # or: cd microbiomeprofiler
make deps              # shallow-clone the upstream repository
make docker            # build + tag the image
```

The upstream repositories are **not vendored**. Each `Makefile` clones its
upstream into its own subdirectory on demand, and the subdirectory is listed in
`.gitignore`:

```bash
make refresh_deps      # re-clone, to pick up an upstream update
make clean_deps        # remove the checkout
```

## What is in a tool directory

```
<tool>/
├── Dockerfile                     # the image
├── Makefile                       # deps / build / run / push helpers
├── .dockerignore
├── .gitignore
├── README.md                      # build, register, test, results
├── docker/
│   └── install.R                  # dependency install + verification
└── gxit/
    └── interactivetool_*.xml      # the Galaxy tool wrapper
```

## Adding another tool

1. `mkdir <tool> && cd <tool>`, then copy the layout above.
2. Point `UPSTREAM_URL` / `UPSTREAM_REF` / `UPSTREAM_SENTINEL` at the upstream
   repository and pick a sentinel file that always exists in it.
3. Write `docker/install.R` so that it installs the dependencies *and* verifies
   them at the end. `BiocManager::install()` and `install.packages()` both report
   per-package failures while still exiting 0, so an unverified build can easily
   ship a broken image.
4. Write the `<tool>/gxit/*.xml` wrapper. The container port, `ARG PORT` in the
   Dockerfile and `internal_port` in the Makefile all have to agree - Galaxy
   publishes exactly the port declared in `<entry_point>`.
5. Add a `.dockerignore` entry for the upstream checkout directory.

## Testing in Galaxy

`planemo serve` with a fixed port, mirroring the in-image port:

```bash
planemo serve --host 0.0.0.0 --port 8080 <tool>/gxit/
```

## Registry

Images are pushed to Docker Hub under the `paulzierep` account:

```bash
make push_hub USERNAME=paulzierep DOCKERHUB_PASSWORD=...
```

The password can also be read from a `.password` file in the tool directory
(gitignored). Never commit credentials.

## Notes

- Both tools are export-oriented: results are downloaded from the browser, so the
  tool XMLs declare no `<data>` outputs.
- MicrobiomeProfiler needs outbound internet access at runtime (KEGG REST,
  eggNOG, SMPDB, Disbiome, HMDB). MetaDAVis is fully self-contained.
