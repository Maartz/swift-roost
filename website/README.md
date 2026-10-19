# Roost website

The public site at **https://roost-framework.github.io/swift-roost/**. Plain HTML, CSS,
and JavaScript; no build step, package install, analytics, or external font service.

## Preview

From the repository root:

```sh
python3 -m http.server 4077 --bind 127.0.0.1 --directory website
```

Open http://127.0.0.1:4077. The interactive reading-list preview runs entirely in
the browser and resets on reload. It does not connect to the Swift app or store
visitor input. The framework copy and code remain readable without JavaScript.

Open `/playground.html` for the browser playground. Counter, Greeting, and Toggle
are guided Swift examples with a JavaScript preview. Only the named numeric,
Boolean, and text values are editable; arbitrary Swift and templates are not
executed. Drafts live in the current tab and disappear on reload. Nothing is
uploaded, and no compiler service or third-party editor is required.

Visitors can jump to supported values, run with Command/Ctrl+Enter, reset, copy,
and download the Swift file. Unsupported edits retain the last working preview.
The download targets the separate local `RoostPlayground` companion project,
whose unpublished status and setup requirements are explained on the page.

## Check

```sh
node --check website/script.js
node --check website/playground/app.mjs
node --check website/playground/examples.mjs
node --test website/playground/examples.test.mjs
python3 website/check.py
git diff --check
```

Before publishing visual changes, review desktop, 390px and 320px layouts in a
browser. Exercise code tabs with arrow keys, copy buttons, save-link validation,
reading filters, mark-as-finished, reset, and the project-status disclosures.
Check reduced motion, keyboard focus, and the dialog's Escape/close behavior.
For the playground, exercise all three lessons, supported edits, invalid edits
with preview retention, draft switching, jump shortcuts, copy/download, and
Command/Ctrl+Enter. Confirm the editor scrolls independently on narrow screens.

## Publish

`.github/workflows/pages.yml` checks website pull requests and publishes changes
to `website/` on `main` using GitHub Actions. In repository settings, Pages uses
**GitHub Actions** as its source. Only the public HTML/CSS/JS, assets, sitemap,
robots file, and `.nojekyll` marker go into the deployment artifact.

The workflow follows GitHub's [custom Pages workflow](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).
For a custom domain, update the canonical URL, social metadata, sitemap,
`robots.txt`, the 404 home link, and the Pages domain setting together.

## Content and identity

- Preserve the original falcon artwork; the wordmark is `roost.` with an orange dot.
- `index.html` contains the overview, code samples, preview, and project status.
- `style.css` defines the pale blue, ink, blue, and orange palette and responsive layouts.
- `script.js` adds code copying, accessible code tabs, and the disposable preview.
- `playground.html` and `playground.css` contain the browser playground.
- `playground/examples.mjs` defines the Swift samples and validates supported edits;
  `playground/app.mjs` manages the editor and safe DOM previews. The focused Node
  tests cover the boundary between editable values and fixed program structure.
- Keep the status copy aligned with releases. The site describes Roost 2.3.0,
  Spectro 2.x (from 2.3.1), Nexus 2.x (from 2.1.0), and ESW 1.7.0. The separate local Playground
  has its own setup and release status.
- Manrope and IBM Plex Mono are self-hosted from the [Google Fonts source repository](https://github.com/google/fonts).
  Their SIL Open Font License files are included in `assets/fonts/`.

The website was developed in a separate Git worktree to preserve the in-progress
framework rename and DX work. Deploying this site does not publish those changes.
