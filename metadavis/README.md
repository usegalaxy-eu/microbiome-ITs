# MetaDAVis as a Galaxy Interactive Tool

Docker packaging of [MetaDAVis](https://github.com/GudaLab/MetaDAVis) (Jagadesan
& Guda, PLOS ONE 2025), an R Shiny application for 16S and whole-metagenome data
analysis, built so it can be used from Galaxy through the
[Interactive Tools](https://training.galaxyproject.org/training-material/topics/dev/tutorials/interactive-tools/tutorial.html)
framework.

```
.
├── Dockerfile                        # image definition
├── Makefile                          # build / run helpers
├── docker/
│   ├── install.R                     # R package installation + verification
│   ├── entrypoint.sh                 # container entrypoint
│   └── trim_metadata.py              # metadata reduction, run by the tool
├── gxit/
│   └── interactivetool_metadavis.xml # Galaxy interactive tool
└── tests/
    ├── smoke_test.R                  # headless check of the built image
    ├── phyloseq_test.R               # parser test for the Galaxy input format
    ├── trim_metadata_test.sh          # the metadata reduction
    └── data/                         # fixtures for the parser test
```

MetaDAVis itself is **not vendored**. The Dockerfile shallow-clones the
`galaxy-input` branch of the application fork while building the image.

```bash
make docker               # fetch the app and build the image
make re                   # clean local containers, then rebuild
```

Pin a different app state with Docker build arguments:

```bash
docker build --build-arg APP_REF=v1.2.0 -t metadavis-gxit:latest .
```

## Build

```bash
make docker
```

The image is built on `rocker/shiny-verse:4.4.3`, which is R 4.4.3 /
Bioconductor 3.20 / shiny 1.10.0 / ggplot2 3.5.2 - the versions the upstream
README recommends and the app was written against. The Bioconductor stack
(phyloseq, microbiome, ComplexHeatmap, scater, DESeq2, mia, ...) plus the two
GitHub packages (microbiomeutilities, maaslin3) are compiled from source, so
expect roughly **30-60 minutes** on a first build; afterwards Docker caches the
layer and only the app clone layer is rebuilt.

`docker/install.R` verifies at the end of the build that every package can be
*loaded*, not just installed, and fails the build if one is broken.

Override the base image or the port if needed:

```bash
docker build --build-arg BASE_IMAGE=rocker/shiny-verse:4.5.3 --build-arg PORT=9000 -t metadavis-gxit:latest .
```

## Run it standalone

```bash
make d        # detached, http://127.0.0.1:8080
make log      # follow the Shiny startup log
make stop
```

`METADAVIS_JOB_DIR` (set by the Makefile to `/tmp/metadavis`) is where the app
copy and any results are written; it defaults to the current directory.

## Check the image

```bash
make smoke    # packages load, example data parses, DESeq2 runs, staging shim works
make check    # start a container and GET / on the published port
```

`make smoke` is the one to run after an upstream update: it exercises the
compiled R stack and the Galaxy input staging on the example data shipped with
MetaDAVis, without needing a browser.

## Publish

GitHub Actions publishes release images as
`quay.io/paulzierep/metadavis-gxit:<tag>` and `:latest`. It uses the
`QUAY_OAUTH_TOKEN` repository secret and Quay's `$oauthtoken` username.

## Register it in Galaxy

1. Build the image locally, then tag it with the name the tool XML asks for
   (`quay.io/paulzierep/metadavis-gxit:latest`). `make docker` does both.
2. Copy `gxit/interactivetool_metadavis.xml` into Galaxy's `tools/interactive/`
   directory.
3. Make sure interactive tools are enabled, e.g. in `config/galaxy.yml`:

   ```yaml
   interactivetools_enable: true
   ```

4. The Docker runner has to publish container ports, which is the default:

   ```yaml
   docker:
     runner: docker
     local_container_config:
       volatile: {image: null}
   ```

   and interactive tools additionally need a reachable proxy
   (`galaxy.yml`: `interactivetools_prefix`, `gxit_proxy_port`) when you serve
   Galaxy on a public host.

The port in `<entry_point>` (8080) has to match `ARG PORT` in the Dockerfile -
Galaxy publishes exactly that container port. `Makefile` keeps the three in
sync.

## Test it locally with planemo

```bash
planemo serve --host 0.0.0.0 --port 8080 gxit/
```

and add to your `config/galaxy.yml` (`$__galaxy_url__` is only used by Galaxy
internals, the container itself does not call back into Galaxy):

```yaml
docker:
  runner: docker
  local_container_config:
    docker_run_extra_arguments: "--add-host localhost:host-gateway"
```

## How the inputs are wired up

The tool takes three tables and offers them to the application as the **Galaxy
input** format, which sits in the *Upload files* tab next to the browser upload
and the built-in example data:

| Tool input  | Select Input format | Staged file                     | Environment variable        |
| ----------- | ------------------- | ------------------------------- | --------------------------- |
| OTU table   | `Galaxy input`      | `metadavis_inputs/otu`          | `METADAVIS_OTU_TABLE`       |
| taxonomy    | `Galaxy input`      | `metadavis_inputs/taxonomy`     | `METADAVIS_TAXONOMY_TABLE`  |
| metadata    | `Galaxy input`      | `metadavis_inputs/metadata`     | `METADAVIS_METADATA_FILE`   |

The three tables use the phyloseq layout, which MetaDAVis upstream does not
support: an **OTU/feature table** with features in the rows and samples in the
columns, a **taxonomy table** with the same feature ids in the rows and one
column per rank, and a **sample metadata** table with the sample ids in the first
column and the condition/group in the second. Select *Galaxy input* and press
*Submit* to load them.

The application can only work with two metadata columns - the sample ids and the
grouping condition - because that is what every plot reads: the second column of
the metadata table. A wider metadata table is therefore reduced to those two
columns, using the one picked in *Grouping condition column*, before the
container is started:

- `docker/trim_metadata.py` (installed as `metadavis-trim-metadata`) is called
  by the tool's `<command>`. It writes `metadavis_inputs/metadata_trimmed`
  (sample ids plus the selected column) and the `<command>` points
  `metadavis_inputs/metadata` at it, so the file the application reads already
  is the layout it expects. It parses the table with the `csv` module, so quoted
  fields - a sample called `Clinic, Main`, or a whole quoted CSV - survive the
  reduction. A column that cannot be resolved (a name that is not in the table, a
  number out of range, the sample id column) is not fatal: the staged table is
  used as it was, and the application reports the problem in its own words. Both
  outcomes are reported in `metadavis_startup.txt`.

The application itself is left as close to upstream as possible: the only change
is the *Galaxy input* format, which reads the three staged tables. Which column
is the condition is decided by the tool form, not by the application.

This is implemented in the app itself (`scripts/data_input.R`, `server.R`,
`ui.R`) rather than by patching the image build, so the format is part of the
fork and nothing has to be spliced into `server.R` at image build time.

Two details worth knowing:

- **No separator parameters.** Galaxy datasets have no meaningful extension, so
  the field separator is detected from each file header (`detect_sep()`), which
  makes the extra form fields and the `METADAVIS_*_SEPARATOR` variables
  unnecessary. Tab and comma both work.
- **No taxonomy level parameter.** The application already has its own
  *Choose the level to display* control, so the tool does not force one.

Features present in the OTU table but absent from the taxonomy table are
reported as `Unclassified` rather than as an empty name, because an empty taxon
label is invisible in the taxonomy table and in plot labels.

## Results

Every table and plot has a download button, and the *Run* tab bundles all
completed analyses into one ZIP. Inside Galaxy each of those buttons has a
*Send to Galaxy* companion that puts the same file into the history of the
running session, so a result can be handed to the next tool without leaving the
browser.

The upload is `galaxy_ie_helpers` (`put()`), which the tool XML feeds with
`HISTORY_ID`, `GALAXY_URL`, `GALAXY_WEB_PORT` and an `API_KEY` injected from the
user's session. The helper runs in its own virtualenv (`/opt/galaxy_ie_helpers`)
because Ubuntu marks the system python as externally managed, and `net-tools` is
installed because the helper finds the docker bridge address with `netstat`.

The application side is one small file, `scripts/galaxy_downloads.R`: every
`downloadHandler` is wrapped so the file name and content function are
registered, and one piece of javascript adds the button next to each download
link shiny renders. Nothing about a download changes - the button produces the
very same file the download button would.

The one result that lands on disk is the MaAsLin3 output directory
(`app/www/hmp2_output` plus `app/www/hmp2_output.zip`), because the app writes it
relative to its own directory - which is why the entrypoint copies the app into
the job directory instead of serving `/opt/MetaDAVis` directly. Declare it in
`<outputs>` if you want it in the history, for example:

```xml
<collection name="maaslin3_output" label="MaAsLin3 output files">
    <discover_datasets pattern="*" directory="app/www/hmp2_output" format="txt"/>
</collection>
```

The only output declared out of the box is `metadavis_startup.txt`, which the
entrypoint always writes (resolved format, staged files, R session info), so
the job ends cleanly whether or not the user ran an analysis.

## Upgrading MetaDAVis

```bash
make refresh_deps docker
```

or, to build a different upstream state:

```bash
make docker UPSTREAM_REF=<tag-or-sha>
```

The Galaxy input format is part of the cloned app, so the fork has to be
cloned rather than plain upstream. `UPSTREAM_URL` / `UPSTREAM_REF` point at the
fork and its `galaxy-input` branch by default; switch them back to upstream to
build a version without the Galaxy input format.
