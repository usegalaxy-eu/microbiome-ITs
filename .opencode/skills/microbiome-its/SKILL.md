---
name: microbiome-its
description: Develop and locally test Galaxy Interactive Tools in this repository (Shiny apps, Python/Tornado apps, …) — building/tagging the Docker image, running a dev Galaxy with planemo (the required --biocontainers flag), and verifying an interactive-tool job end-to-end inside the real Galaxy UI.
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
# versioned tag (e.g. quay.io/galaxy/<tool>-gxit:1.0.0) is a CI release concern;
# the workflow auto-increments it from the tags published on quay (see next-tag job)
```

**Always pin the version tag in the wrapper, never `:latest`.** Every
`<container type="docker">` in this repository names a published version tag
(`1.0.0`, `v1`, `v0.1`, ...) and `WEB_TAG` in the tool's Makefile has to
produce that same tag, so a running server never silently changes the image under
a user and a rollback is a one-line edit. `:latest` is only published alongside
it for convenience, not referenced by any wrapper.

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
- `planemo format <tool>/gxit/` — **we always run this before pushing a wrapper.** It is
  the canonical IUC formatting: it collapses multi-line `<param>` / `<data>` attribute
  lists onto one long line, so a "format only" diff of a few dozen lines is expected —
  don't hand-wrap it back afterwards. Run it after every XML edit, on every wrapper,
  and commit the formatting either with the change or as its own commit.
- `planemo lint <tool>/gxit/` — must be INFO/CHECK only.
- `make startup-test` (where provided) — `MIADASH_STARTUP_ONLY=1`-style seam in the entrypoint; grep startup log with `grep -E "label: +path"` (whitespace-tolerant).

## Verify in the real Galaxy UI (click-through probe)

`curl` on the entry-point target only proves the app answers. Galaxy embeds the IT in a
**cross-origin iframe**, and that is where browsers break apps: cookie policy and
framing headers only matter in that context. Treat "opens in Galaxy" as its own test.

The display route is **client-side only**: `GET /interactivetool_entry_points/<id>/display`
returns `404 No route for …` — you must enter through
`/interactivetool_entry_points/list` and click, exactly like a user.

This skill ships a dependency-free probe (headless Chrome + DevTools Protocol, Node 22+):

```sh
# planemo serve already running and the IT launched in a history
node .opencode/skills/microbiome-its/scripts/galaxy_it_probe.js \
     http://127.0.0.1:8080 "miaDash"
```

```json
{
  "ok": true,
  "title": "miaDash",
  "href": "http://<id>-<token>.ep.interactivetool.localhost:<port>/",
  "body": "…visible text of the embedded app…"
}
```

`ok: true` means the iframe document actually **rendered** (title + visible text), not
just that the host answered. The probe:

1. launches `google-chrome --headless=new --remote-debugging-port=<port>`;
2. navigates to `/interactivetool_entry_points/list` and clicks the IT row link
   (`a[id^="link-"]` — not the toolbox entry `a.title-link`, not "Open in center panel");
3. waits for the display route and finds the `iframe` CDP target at
   `*.ep.interactivetool.<host>`;
4. evaluates `document.title` / `location.href` / `document.body.innerText` inside it.

**No extra Docker.** The only container is the IT image that `planemo serve --docker`
launches; Chrome and Node run on the host.

Manual equivalent: start Chrome with `--remote-debugging-port`, navigate to `/list`,
click the row link, then `GET http://127.0.0.1:<port>/json/list` and connect to the
`iframe` target's `webSocketDebuggerUrl`. A redirect loop appears as 20+
`URL_REQUEST_START_JOB` events for the same URL in `--log-net-log=…`.

### Relaunching after an XML edit

Galaxy reloads the tool XML on change (`watch_tools`) without restarting serve, but the
**running container keeps the old command** — stop and relaunch the entry point:

```sh
BASE=http://127.0.0.1:8080
# API key: curl -s -c jar $BASE/ ; uid=$(curl -s -b jar $BASE/api/users | jq -r '.[0].id')
#          key=$(curl -s -X POST -b jar $BASE/api/users/$uid/api_key | tr -d '"')
curl -s -X DELETE -H "x-api-key: $KEY" $BASE/api/entry_points/<id>
curl -s -X POST  -H "x-api-key: $KEY" -H 'Content-Type: application/json' \
     -d '{"tool_id":"interactive_tool_<tool>","history_id":"<hid>"}' $BASE/api/tools
curl -s -H "x-api-key: $KEY" "$BASE/api/entry_points?running=true"   # poll until it appears
```

### Cross-origin traps (these bite any non-Galaxy app)

- **`SameSite=Lax` cookies → infinite redirect loop.** Cookies without `SameSite` are
  treated as `Lax`, and Lax cookies are *not sent on cross-site iframe navigations*.
  Apps that do "no session → log in → redirect to `/`" loop forever
  (`ERR_TOO_MANY_REDIRECTS`) inside the iframe while working fine as a top-level page.
  Emit `SameSite=None; Secure` (Chrome requires `Secure` with `None`, and accepts
  `Secure` over plain HTTP on `*.localhost`), and where the app already assumes a
  trusted pre-authenticating proxy, make auth cookie-free.
- **`X-Frame-Options: DENY` / `Content-Security-Policy: frame-ancestors 'none'`** →
  the frame never renders. `SAMEORIGIN` is not enough: the parent is cross-origin.
  Relax or drop both.
- Check the headers before blaming the browser:
  ```sh
  H="<id>-<token>.ep.interactivetool.localhost"; P=<proxy-port>
  curl -sD- -o /dev/null --resolve "$H:$P:127.0.0.1" "http://$H:$P/" \
    | grep -iE 'x-frame|content-security|set-cookie'
  ```
- Keep the image stock and adapt in the generated runtime config from `<configfiles>`
  (Python apps often `exec()` their config, so the config file can carry a small
  monkey-patch). Gate the patch on the app's proxy flag so upstream defaults apply
  elsewhere — see `libreqda/gxit/interactivetool_libreqda.xml`.

## Review checklist (what `usegalaxy-eu/galaxy` reviewers ask for)

Collected from the LibreQDA PR (#416). Expect the same comments on any new IT, so
address them before opening the PR:

- **Readable runtime config, not an inline `python3 -c` blob.** Put adaptation code
  in `<configfiles>`:
  ```xml
  <configfiles>
      <configfile name="my_config" filename="my_config.py"><![CDATA[ … ]]></configfile>
  </configfiles>
  <command>… exec myapp server my_config.py</command>
  ```
  `name=` is only the Cheetah variable (a copy in `_configs/`); **without
  `filename=` the file is never written into the job working directory** and the app
  starts with its defaults.
- **The work a user does in the session must survive it.** If the app keeps its state
  in one file (SQLite), add an optional input of that format *and* an output dataset,
  plus a `<help>` section on how to continue next time ("should we not save the
  sqlite?" is a review comment, not an optional nicety).
- **Every `requires_domain="True"` gets questioned.** Only keep it when the app builds
  root-absolute URLs and cannot be path-mounted, and say so in an XML comment (no `--`
  inside XML comments). See the LibreQDA rationale below.
- **`<icon src="<tool>.png"/>`** — an icon is expected on every new IT. The PNG lives
  next to the XML (`tools/interactive/<tool>.png`), i.e. in the repo's `<tool>/gxit/`;
  the deploy workflow copies it.
- **`planemo format` before pushing** — we keep wrappers format-clean (see *Fast
  validation* above); a hand-wrapped XML will be collapsed by it, so run it yourself.
- **Citations**: prefer `<citation type="doi">…</citation>` when a DOI exists. A
  bibtex-only citation gets flagged even when the software has no paper.
- **Cite once, in `<citations>` only.** A hand-written "**Citation**" block in
  `<help>` is a review comment ("this is also redundant") and the two copies drift
  apart. Galaxy renders `<citations>` itself; keep help for usage.
- **Check that every DOI resolves** before committing:
  `curl -s -o /dev/null -w '%{http_code}\n' https://doi.org/<doi>` → `302`.
  A fabricated/unpublished DOI is worse than none — the MicrobiomeProfiler wrapper
  carried `10.21105/joss.06522` ("JOSS 2024") which doi.org reports as *not found*;
  the real citable identifier is the Bioconductor package DOI
  `10.18129/B9.bioc.MicrobiomeProfiler`. Look DOIs up in Crossref
  (`api.crossref.org/works?query.bibliographic=…`) rather than trusting a bibtex
  field.
- When the software itself has no DOI (LibreQDA), keep a bibtex `<citation>` for the
  software *and* add the DOI of the upstream project it derives from (Taguette,
  `10.5281/zenodo.3964287`).
- DOI per wrapper: cminet `10.1111/2041-210X.70198` (Methods Ecol. Evol. 2025,
  Aghdam & Solís-Lemus), metadavis `10.1371/journal.pone.0319949`, miadash
  `10.1093/bioadv/vbaf107` (the iSEEtree paper is miaDash's citation),
  microbiomeprofiler `10.18129/B9.bioc.MicrobiomeProfiler`, libreqda bibtex +
  Taguette DOI.
- Tool panel registration (`tool_conf.xml.j2` in `infrastructure-playbook`) stays a
  manual follow-up after merge — reviewers do not expect it in the wrapper PR.

## Deploying to usegalaxy.eu

The image and the wrapper ship separately: quay gets the image, and
[`usegalaxy-eu/galaxy`](https://github.com/usegalaxy-eu/galaxy) gets the XML under
`tools/interactive/`. **Actions → Deploy interactive tool to usegalaxy.eu → Run
workflow** prepares the branch in a fork and prints a compare link; opening the
PR stays manual:

1. validates the XML (interactive, expected tool id, one container, one port);
2. looks the container tag up on quay.io and **stops if the image is not
   published** - never deploy a wrapper whose image is missing;
3. extends the fork's `target_branch` with a branch `add-it-<tool>` that adds
   `tools/interactive/interactivetool_<tool>.xml` (based on the fork's own copy of
   the branch, so the push is one commit even if the fork is old);
4. prints the `usegalaxy-eu/galaxy` compare URL and a ready-to-paste PR body.

Needs the `FORK_PUSH_TOKEN` secret (fine-grained PAT, Contents: read and write on
the fork only); `dry_run: true` prints the diff without credentials.

The fork must already have `target_branch`: create it once by re-forking or with
`git fetch upstream <branch> && git push origin FETCH_HEAD:<branch>`. A fork that
is behind still works (the run warns), because the PR diff is computed against the
merge base.

The tool panel entry stays manual: after the PR merges, add
`<tool file="interactive/interactivetool_<tool>.xml" />` to
`templates/galaxy/config/tool_conf.xml.j2` in `usegalaxy-eu/infrastructure-playbook`.

## Lessons learned (LibreQDA port, 2026-10)

- **Pre-built upstream images**: don't fork the app. `FROM <upstream>`, override
  `ENTRYPOINT ["tini","--"]` + `CMD []`, and do everything Galaxy-specific in the IT
  XML `<command>`.
- **Token-free single-user apps**: apps that print a one-time access token can be put
  in "behind a pre-authenticating reverse proxy" mode from a generated config
  (LibreQDA: `UNIX_SOCKET = True`, which also lets the app pre-authenticate requests).
- **Generated config is a patch point**: LibreQDA's `main.py` `exec()`s the config
  file, so the `<configfiles>` entry carries the shim (SameSite cookies, cookie-free
  auth, frame headers). Gate on the proxy flag.
- **XML comments must not contain `--`** (breaks Galaxy tool parsing), and Galaxy joins
  `<command>` CDATA lines with spaces — keep it a single logical line with `;`.
- **Cheetah escaping**: shell variables need `\$VAR`; in `<configfile>` content `#`
  comments and docstrings pass through unchanged but `$` is interpolated, so shell `$`
  needs `\$` there too.
- **`requires_domain="True"` is a real requirement for LibreQDA** (and any Tornado app
  that hardcodes `/`): it answers with root-absolute `/static/…` URLs and
  `Location: /` redirects, and has no `X-Forwarded-Prefix` support, so in path-based
  mode (`requires_domain="False"` → `http://localhost:<proxy>/interactivetool/ep/<id>_<token>/`)
  every navigation escapes the entry-point prefix into the Galaxy root. Say this in an
  XML comment instead of dropping the attribute.
- **Keep `X_HEADERS = False`**: Taguette/LibreQDA treat `X_HEADERS` as a *required*
  config key (`Missing required configuration variable X_HEADERS`); `False` is the
  value, it is not something to delete when cleaning up the config.

## Lessons learned (LibreQDA session database, 2026-10)

- **`from_work_dir` can never work for an interactive tool.** Galaxy implements it as
  a `cp` *appended after* the tool command in the generated job script
  (`job/command_factory.py: __handle_work_dir_outputs`). An IT is stopped by killing
  the container (and `exec app …` already replaced the shell), so the copy never runs:
  the dataset stays **0 bytes** while the real file sits in
  `job_working_directory/<n>/working/…`. Symptom in the logs: no copy line, only
  `setting metadata externally failed … External set_meta() not called`.
- **Write straight into the output dataset path instead.** Declare
  `<data name="database_out" format="sqlite"/>` (no `from_work_dir`) and let the app
  open `$database_out` (`DATABASE = 'sqlite:///' + os.path.abspath('$database_out')`).
  Galaxy collects that file at job finish, and `set_meta` then proves it worked:
  `GET /api/datasets/<id>` reports `file_size` and a `peek` listing the tables.
- **Save and restore in one file**: at start `cp '$database' '$database_out'` when the
  optional input is set, so the app's live database *is* the output dataset. Nothing is
  copied back at the end; stopping the session is enough. Crash safety is SQLite's.
- **Testing an IT from the API** (the state part needs no browser):
  - start: `POST /api/tools` with `{"tool_id":…, "history_id":…, "inputs":{…}}`
  - poll `GET /api/entry_points?job_id=<job_id>` (a JSON list;
    `/interactivetool_entry_points/list` is HTML)
  - stop: `DELETE /api/entry_points/<entry_id>` → job `stop` → `ok`, output collected then
  - upload fixtures with multipart `files_0|file_data=@path` (+ `files_0|NAME`,
    `files_0|type`); `files_0|file` is silently ignored ("No data was entered in the
    upload form")
  - the file-format autodetect is good enough that a `.sqlite` fixture lands as
    `extension: sqlite`; check `state`/`extension`/`file_size` before running the tool.
- **LibreQDA/Taguette schema facts** (useful to assert a round trip): every project,
  document, highlight and tag lives in the single DB, `documents.contents` holds the
  document text (so the DB alone is a complete backup), and `project_members.privileges`
  stores the enum *name* (`ADMIN`, `MANAGE_DOCS`, `TAG`, `READ`) — needed if you ever
  seed a fixture by hand.

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
