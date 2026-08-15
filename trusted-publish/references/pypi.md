# PyPI

Providers: GitHub Actions, GitLab CI/CD, Google Cloud, ActiveState. Temp token: 15 minutes, project-scoped. PEP 740 attestations are generated automatically when publishing through the official action.

## Trust entry

- **First-ever publish** — add a **pending publisher** at `https://pypi.org/manage/account/publishing/`. It pre-registers the project name, so the first trusted publish creates the project; no token ever exists.
- **Existing project** — `https://pypi.org/manage/project/<name>/settings/publishing/`.

Field values: Owner `<owner>` · Repository `<repo>` · Workflow `publish-pypi.yml` · Environment `pypi`.

The `pypi` environment needs no manual creation — GitHub creates it the first time the workflow references it.

## Workflow template — `.github/workflows/publish-pypi.yml`

Build and publish stay in separate jobs so `id-token: write` never runs beside arbitrary build scripts.

```yaml
name: publish-pypi
on:
  release:
    types: [published]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: pipx run build            # PEP 517 — works for any backend; `uv build` if the repo uses uv
      - uses: actions/upload-artifact@v4
        with: { name: dist, path: dist/ }

  publish:
    needs: build
    runs-on: ubuntu-latest
    environment: pypi
    permissions:
      id-token: write
    steps:
      - uses: actions/download-artifact@v4
        with: { name: dist, path: dist/ }
      - uses: pypa/gh-action-pypi-publish@release/v1   # detects OIDC; no password input
```

## Verify

```bash
curl -s -o /dev/null -w "%{http_code}" https://pypi.org/pypi/<name>/<version>/json   # 200 = live
```

Package URL: `https://pypi.org/project/<name>/<version>/`
