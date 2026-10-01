# Galaxy Interactive Tool images

Docker packaging of Shiny applications as
[Galaxy Interactive Tools](https://docs.galaxyproject.org/en/latest/dev/interactive_tools.html).

Each tool gets its own self-contained subdirectory with everything needed to
build, run and register it:

| Directory | Upstream | Container image |
| --- | --- | --- |
| [`metadavis/`](metadavis/) | [paulzierep/MetaDAVis](https://github.com/paulzierep/MetaDAVis/tree/galaxy-input) | `quay.io/paulzierep/metadavis-gxit` |
| [`microbiomeprofiler/`](microbiomeprofiler/) | [yulab-smu/microbiomeprofiler](https://github.com/yulab-smu/microbiomeprofiler) | `quay.io/paulzierep/microbiomeprofiler-gxit` |

## Quick start

```bash
cd metadavis           # or: cd microbiomeprofiler
make docker            # build + tag the image
```

The upstream repositories are **not vendored**. Each Dockerfile shallow-clones
its application source while the image is built. For local inspection, the
Makefiles can also create ignored checkouts:

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

Release images are pushed by GitHub Actions to Quay.io under the `paulzierep`
organization. The release workflow authenticates with the repository's
`QUAY_OAUTH_TOKEN` secret.

Changes under one tool directory build only that image. Connected app
repositories can request a release build with a `repository_dispatch` event:

```json
{"event_type":"image-release","client_payload":{"image":"metadavis","tag":"1.0.0"}}
```

Use `microbiomeprofiler` as `image` for that container. Sending this event from
another repository requires a token with permission to dispatch workflows in
this repository. The workflow can also be started manually with the same image
and tag inputs.

Docker Hub helpers remain available for manual publishing:

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
