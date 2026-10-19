# Roost documentation

Roost uses Swift DocC, like ESW: authored guides sit beside API pages generated
from the public Swift declarations and their documentation comments. The
combined **Roost Libraries** navigator includes both libraries.

- [Roost](../Sources/Roost/Roost.docc/Roost.md): getting started, routes,
  middleware, typed views, forms, authentication, data, migrations, generators,
  configuration, deployment, and current implementation boundaries.
- [RoostTest](../Sources/RoostTest/RoostTest.docc/RoostTest.md): HTTP assertions,
  browser sessions, CSRF-protected workflows, and database test isolation.

These catalogs document Roost 2.3.0, with published ESW 1.7.0,
Spectro 2.x (from 2.3.1), and Nexus 2.x (from 2.1.0) dependencies.

## Build

Use Python 3 and a Swift toolchain containing DocC with `convert` and `merge`
support. The local build has been verified with Xcode 27.2 beta 2 (Swift 6.4).
From the framework root:

```sh
unset ROOST_ECOSYSTEM_PATH ROOST_ESW_PATH
python3 scripts/build_docs.py
```

The script builds the libraries and test modules, extracts their public symbol
graphs (including Roost's extensions to Nexus connections), checks both catalogs,
then merges them. **It compiles tests but does not run them or connect to a
database.** DocC conversion uses `--analyze --warnings-as-errors`; a failed build
keeps any previously generated archive intact.

The archive and SwiftPM build cache live outside the checkout by default:

```text
macOS:  ~/Library/Caches/roost-documentation/<checkout-id>/
Linux:  $XDG_CACHE_HOME/roost-documentation/<checkout-id>/
        (or ~/.cache/roost-documentation/<checkout-id>/)
```

The script prints the exact archive path and a local preview command. This
keeps generated files out of source control and avoids signed SwiftPM resource
bundles inside a synced source directory.

SwiftPM's native build backend is selected explicitly because the Xcode 27
Swift Build backend attempts to extract unrelated dependency C headers during
symbol graph generation. The preliminary test build provides the synthetic
test-runner module requested by SwiftPM 6.4. These are toolchain workarounds,
not additional application requirements.

## Browse locally

Run the printed `python3 -m http.server` command, or choose your own archive
location and port:

```sh
python3 scripts/build_docs.py --output /tmp/Roost.doccarchive
python3 -m http.server 61415 --bind 127.0.0.1 --directory /tmp/Roost.doccarchive
```

Open [Roost Libraries](http://127.0.0.1:61415/documentation/) or go directly to
[Getting started](http://127.0.0.1:61415/documentation/roost/gettingstarted/).
Use the sidebar filter to find guides and declarations. API links lead to the
current declaration, parameters, and related symbols.

The `.docc` catalogs are also available to Xcode's **Build Documentation**
command. The script is the reproducible path for the merged, two-library site.

## Publish

Each release carries its own documentation. When a release is published, the
`release-docs` job in `.github/workflows/pages.yml` builds the archive from the
release tag, attaches it to the release as `Roost-<tag>.doccarchive.zip`, and
redeploys the site from `main`. To add documentation to an existing release, run
the workflow manually with its `tag`; that build passes `--allow-warnings`,
because older tags may predate later DocC link fixes.

Every deploy runs `scripts/publish_docs.py`, which downloads each release's
archive and serves it at `/swift-roost/<tag>/documentation/`, applying that
prefix with `docc process-archive transform-for-static-hosting`. The
[documentation index](https://roost-framework.github.io/swift-roost/docs/) lists
the versions, newest first, and `/swift-roost/docs/latest/` redirects to the
newest. Deploys never rebuild old versions, and documentation from `main`
between releases is not published; preview it locally as described above.

## Maintain the guides

Edit articles in `Sources/Roost/Roost.docc/` or
`Sources/RoostTest/RoostTest.docc/`, and API comments beside the Swift declarations.
Add new guides to their module landing page's `Topics` section so they appear
in the navigator. Rebuild after changing symbol links or signatures.

Keep examples aligned with the generators and actual request lifecycle. State
when an example needs PostgreSQL, a generated model, a session store, or a local
dependency override. Use `swift test` and the
[generated-app acceptance check](../README.md#testing) for framework
verification; a successful documentation build validates neither
database workflows nor network transports.
