# crates.io

Providers: GitHub Actions; GitLab.com in public beta (self-hosted GitLab unsupported). Temp token: 30 minutes, revoked automatically when the job ends.

## Trust entry

- **First-ever publish is manual**: create a token at `https://crates.io/settings/tokens` (scope: publish-new), `cargo login`, `cargo publish`, then revoke the token — the trust entry attaches to an existing crate.
- **Existing crate** — `https://crates.io/crates/<crate>/settings/new-trusted-publisher`.

Field values: Repository owner `<owner>` · Repository name `<repo>` · Workflow filename `publish-crates.yml` · Environment `crates-io`.

Hardening: after the first green trusted publish, the crate's Settings offer **enforce Trusted Publishing** — it disables token publishing for the crate entirely. Recommend it to the user.

## Workflow template — `.github/workflows/publish-crates.yml`

```yaml
name: publish-crates
on:
  release:
    types: [published]

jobs:
  publish:
    runs-on: ubuntu-latest
    environment: crates-io
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: rust-lang/crates-io-auth-action@v1   # OIDC → 30-min token; revoked at job end
        id: auth
      - run: cargo publish
        env:
          CARGO_REGISTRY_TOKEN: ${{ steps.auth.outputs.token }}
```

A workspace with several publishable members: `cargo publish -p <member>` per member, dependency order, each configured as its own crate on crates.io.

## Verify

The crates.io API rejects requests without a User-Agent:

```bash
curl -s -A trusted-publish-skill https://crates.io/api/v1/crates/<crate> | grep -o '"num":"<version>"'
```

Crate URL: `https://crates.io/crates/<crate>/<version>`
