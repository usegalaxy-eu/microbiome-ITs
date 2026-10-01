# MicrobiomeProfiler as a Galaxy Interactive Tool

Docker packaging of [MicrobiomeProfiler](https://github.com/yulab-smu/microbiomeprofiler)
(YuLab-SMU), an R package + Shiny application for functional enrichment analysis
of microbiome data, built for the Galaxy
[Interactive Tools](https://training.galaxyproject.org/training-material/topics/dev/tutorials/interactive-tools/tutorial.html)
framework.

This mirrors the MetaDAVis image next door in this repository, but the two
upstream projects are packaged differently:

| | MetaDAVis | MicrobiomeProfiler |
| --- | --- | --- |
| upstream layout | bare Shiny app directory | R package with the app inside |
| how it is run | `shiny::runApp()` | `MicrobiomeProfiler::run_MicrobiomeProfiler()` |
| inputs | two uploaded tables (count + metadata) | an annotation table with a gene (KO) column |
| build-time patch | shim spliced into `server.R` | none needed |
| network at runtime | not needed | **yes** - KEGG REST, eggNOG, SMPDB, Disbiome, HMDB |

## Network requirement

MicrobiomeProfiler enriches against live services (`rest.kegg.jp`,
`eggnogdb.org`, `smpdb.ca`, `disbiome.ugent.be`, the NCBI PubChem FTP mirror and
the project's own GitHub Pages dataset mirror). The container therefore needs
outbound internet access at runtime to do anything useful, which is fine on a
normal Galaxy Docker runner but not in an air-gapped deployment. MetaDAVis, by
contrast, is fully self-contained.

Resources that ship inside the package (the registry in
`inst/extdata/external_data_registry.json` and the built-in KO/PubChem pathway
tables) work offline; only the enrichment lookups need the network.

## Layout

```
.
├── Dockerfile
├── Makefile                          # build / run helpers
├── docker/
│   └── install.R                     # dependency install + app verification
└── gxit/
    └── interactivetool_microbiomeprofiler.xml
```

The upstream repository is **not vendored**. The Dockerfile shallow-clones its
`devel` branch while building the image.

## Build

```bash
make docker
```

Base image is `rocker/shiny-verse:4.4.3` (R 4.4.3, Bioconductor 3.20, shiny
1.10.0, ggplot2 3.5.2), which satisfies MicrobiomeProfiler's `R (>= 4.2.0)`
requirement and matches the clusterProfiler versions the package was developed
against. Most dependencies are CRAN, so the build is considerably faster than
the MetaDAVis one - expect roughly 15-30 minutes on a first build.

The cloned package is installed from source, and `install.R` then
verifies that `MicrobiomeProfiler::run_MicrobiomeProfiler()` returns a working
Shiny app object and that the packaged data files are in place. A build that
produces an unloadable app fails instead of shipping.

## Run it standalone

```bash
make d        # detached, http://127.0.0.1:8080
make log      # follow the startup log
make stop
```

## Register it in Galaxy

1. `make docker` (builds and tags `quay.io/paulzierep/microbiomeprofiler-gxit:latest`).
2. Copy `gxit/interactivetool_microbiomeprofiler.xml` into Galaxy's
   `tools/interactive/` directory.
3. Enable interactive tools in `config/galaxy.yml`:

   ```yaml
   interactivetools_enable: true
   ```

The port in `<entry_point>` (8080) matches `ARG PORT` in the Dockerfile; the
Makefile keeps all three in sync.

## Test it locally with planemo

```bash
planemo serve --host 0.0.0.0 --port 8080 microbiomeprofiler/gxit/
```

## Results

Like MetaDAVis, this is an export-oriented app: results are downloaded from the
browser (per-module tables and plots, plus the session's own downloads) rather
than written into the Galaxy history. No `<data>` outputs are declared, so the
job ends cleanly whether or not the user ran an enrichment.

## Citation

> Yu G (2024). MicrobiomeProfiler: An R package for microbiome functional
> enrichment analysis. *Journal of Open Source Software*.
