# npm

Providers: GitHub Actions (GitHub-hosted runners only), GitLab.com, CircleCI. Requires npm CLI ≥ 11.5.1 and Node ≥ 22.14.0 *inside the workflow* — Node images ship older npm, so the template upgrades it explicitly. Provenance attestations publish by default from GitHub Actions; the `--provenance` flag is obsolete here.

## Trust entry

- **First-ever publish is manual**: `npm login && npm publish --access public` once from the local machine — the trust entry attaches to an existing package.
- **Existing package** — npmjs.com → the package → **Settings** → **Trusted publisher**.

Field values: Organization or user `<owner>` · Repository `<repo>` · Workflow filename `publish-npm.yml` · Environment `npm`. Configs created after 2026-05-20 must also tick at least one allowed action — select **Publish**.

## Workflow template — `.github/workflows/publish-npm.yml`

```yaml
name: publish-npm
on:
  release:
    types: [published]

jobs:
  publish:
    runs-on: ubuntu-latest            # must be GitHub-hosted
    environment: npm
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 24
          registry-url: "https://registry.npmjs.org"
      - run: npm install -g npm@latest && npm --version   # OIDC needs npm ≥ 11.5.1
      - run: npm ci
      - run: npm publish                # no NODE_AUTH_TOKEN — OIDC is detected
```

## Verify

```bash
curl -s https://registry.npmjs.org/<name>/<version> | head -c 200   # JSON doc = live; "version not found" = not yet
```

Package URL: `https://www.npmjs.com/package/<name>/v/<version>`
