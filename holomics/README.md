# Holomics Galaxy Interactive Tool

Packages the original [Holomics](https://github.com/MolinLab/Holomics)
application, retaining its authorship, GPL (>= 3) license, interface and
PCA/PLS-DA/sPLS/DIABLO analysis workflows. The application fork's
`galaxy-it-adaptations` branch adds Galaxy input loading and hooks to export
existing downloads. The enhanced OmicsHarbor app is separate on `omicsharbor-development`.

## Build and launch

`make docker` builds the version-pinned `quay.io/galaxy/holomics-gxit:1.0.0`
image locally. `make serve` starts Planemo; choose a free port if another Galaxy
is running. No publication or deployment is implied by a local build.

Select named numeric tables and matching sample labels from your Galaxy history
on the launch form. They load automatically into the original application, with
sample-ID alignment and validation. Mark prepared blocks for direct multi-omics
analysis; otherwise use the original single-omics reduction workflow. The
original browser upload controls remain available. No checkpoint restoration is added.

Each result has separate Download (browser only) and Send to Galaxy buttons.
Only Send to Galaxy stages a copy in `holomics_outputs/` and starts live upload
using `galaxy-ie-helpers==0.3.0`. The results collection is collected when the
interactive job ends, providing a fallback if live upload fails. The Galaxy
tool Help contains a step-by-step two-omics example from launch to DIABLO export.

## Validation

- `make test`: app construction, export staging, exact file contents, unique
  export names and absence of enhanced modules/import functionality.
- Real-browser acceptance must cover original file upload, a rendered plot,
  a downloaded result and successful delivery to the Galaxy history.
- Planemo lint must pass at its normal warning-level threshold.
- Older tests and status files in this local packaging directory describe the
  superseded enhanced app and are not acceptance evidence for this version.

Container publication uses the per-image **Container images** workflow dispatch
with `image=holomics`. Galaxy EU registration is a separate deployment step.
