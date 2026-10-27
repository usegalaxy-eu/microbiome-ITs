# LibreQDA

[`LibreQDA`](https://gitlab.com/bin-cirst/libreqda/libre-qda) is a free and
open-source qualitative data analysis (QDA) tool — import documents (PDF,
DOCX, ODT, TXT, HTML, EPUB, MOBI, RTF), highlight and tag excerpts with a
hierarchical code system, retrieve and export coded material. It is developed
by the Plateforme en humanités numériques (PHuN) at Université de Sherbrooke
and is a fork of [Taguette](https://taguette.org/) with research-driven
additions (document collections, code hierarchies, overlaid coding stripes,
drag-and-drop coding, integrated search).

License: **BSD-3-Clause** (upstream `LICENSE.txt`).

## Used as-is: no fork, no app changes

Unlike the other tools in this repository, LibreQDA needs **no
`galaxy-it-adaptations` fork**: upstream publishes its own container image,
built by its own GitLab CI, and the application already binds `0.0.0.0` and
serves everything from the browser. The image is:

```
phunudes/libreqda:1.2.1     # Docker Hub, pushed by the upstream CI
```

The `Dockerfile` here is two effective lines: it takes that image and resets
the `ENTRYPOINT` to keep only `tini`. Galaxy starts an interactive-tool job
by appending a job script to the container command; upstream's entrypoint
(`tini -- libreqda --no-browser --bind=0.0.0.0`) would pass that script to
`libreqda` as extra CLI arguments and fail. With the reset entrypoint, the
tool XML's `<command>` runs the application itself.

There is therefore no `docker/install.R`-equivalent, no entrypoint script and
no `tests/` directory: nothing Galaxy-specific exists inside the image.

## No access token

Upstream's single-user mode protects the app with a random access token that
is printed once to the container's stdout and must be appended as
`?token=<hex>` to open the session — a poor fit for an interactive tool,
where the session URL is already the access boundary and the job log is the
only place the token appears.

The tool therefore starts LibreQDA in upstream's `server` mode with a
generated config file that sets `UNIX_SOCKET`. Upstream treats that setting
as "running behind a pre-authenticating reverse proxy" and skips the token
entirely. This does **not** switch the listener to a unix socket (that only
happens when the `unix_socket` CLI option is passed): the app still listens
on TCP `0.0.0.0:7465`, it just assumes every request is already
authenticated. Opening the session link from Galaxy goes straight into the
application.

## Running inside Galaxy (cross-origin iframe)

Galaxy embeds the entry point in an iframe served from
`<entry-point>-<token>.ep.interactivetool.<host>`, a **different origin** from
Galaxy itself. Two upstream defaults break in that context; the generated
config adapts both, still only when `UNIX_SOCKET` is set:

- **Session cookies.** Upstream sets them without `SameSite`, which browsers
  treat as `Lax`. Lax cookies are not sent on cross-site iframe navigations, so
  LibreQDA's "no session → log in as admin → redirect to `/`" branch loops
  forever (`ERR_TOO_MANY_REDIRECTS`). Cookies are now emitted with
  `SameSite=None; Secure` (Chrome accepts `Secure` over plain HTTP on
  `*.localhost`), and `get_current_user` returns the implicit `admin` user
  directly, so the first request is a 200 even in browsers that block
  third-party cookies.
- **Framing headers.** Upstream sends `X-Frame-Options: DENY` and
  `Content-Security-Policy: frame-ancestors 'none'`, which makes the browser
  refuse to render the frame at all. The shim drops the first and relaxes the
  second to allow the embed; the unguessable interactive-tool host remains the
  access boundary.

Verify the embedded result with the repository skill's click-through probe
(headless Chrome + DevTools Protocol, **no extra Docker** — only the IT image
that planemo/Galaxy runs):

```bash
node .opencode/skills/microbiome-its/scripts/galaxy_it_probe.js \
     http://127.0.0.1:8080 "LibreQDA"
```

It opens `/interactivetool_entry_points/list`, clicks LibreQDA like a user, and
prints the title and visible text of the embedded document (`"ok": true` when
it rendered).

## Galaxy integration status

The tool wrapper (`gxit/interactivetool_libreqda.xml`) currently has **no
inputs and no outputs**:

- the session starts with an empty LibreQDA project;
- documents are imported from the browser (the app accepts the uploads);
- the sqlite database lives in the job working directory, so a session is
  self-contained but its data disappears when the session ends — export from
  the application before stopping;
- nothing is sent back to the Galaxy history yet.

Natural next steps (not implemented): stage text datasets from the history as
documents on launch, and collect the application's exports into a history
collection via a send-to-Galaxy handler like the other tools use.

## Build and run

```bash
make docker    # pulls phunudes/libreqda:1.2.1, retags as quay.io/galaxy/libreqda-gxit:{v0.1,latest}
make check     # starts the container and polls http://127.0.0.1:7465/ for HTTP 200
make it        # interactive run on http://127.0.0.1:7465
```

## Local end-to-end test

```bash
planemo serve --galaxy_root ~/git/galaxy --port 8080 --docker --biocontainers \
    libreqda/gxit/
```

Run **LibreQDA** from the tool panel (no form inputs to fill), then open
**Interactive Tools → LibreQDA** — or navigate to
`http://127.0.0.1:8080/interactivetool_entry_points/list` and click the row.
Do not paste the `/display` URL into a new tab: that route is client-side only,
so a direct request returns 404. Always enter through the list.

The entry-point target (`http://<entry>.ep.interactivetool.localhost:<port>/`)
uses a random proxy port per serve, but Galaxy bakes the current one into the
link, so there is nothing to look up. Stock planemo is sufficient: its
`gx-it-proxy` binds IPv4-only and browsers/curl fall back from `::1` to
`127.0.0.1` automatically.
