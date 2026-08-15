# Other registries

Trusted publishing keeps one shape everywhere: a registry-side trust entry binding the four identity fields, `id-token: write` on the publish job, and an exchange step or upload tool that turns the OIDC JWT into a short-lived registry token. For a registry outside this skill's covered set, fetch its trusted-publishing docs *first* — support and field names change fast — then adapt the nearest template while keeping the skill's fixed names (`publish-<registry>.yml`, environment named after the registry) and the verify-by-registry-API criterion.

## RubyGems (`*.gemspec`)

Supported on rubygems.org; the `rubygems/release-gem` action wraps build + push over OIDC. Fetch `https://guides.rubygems.org/trusted-publishing/` for the current trust-entry fields and new-gem support before writing the workflow.

## Everything else (`*.nuspec`, `conda`, …)

Several more registries have announced or shipped OIDC trusted publishing since 2025. Confirm current support in the registry's own docs before promising it to the user; when the registry has none, say so and offer the fallback — a registry token stored as a GitHub Actions secret, scoped as narrowly as the registry allows.
