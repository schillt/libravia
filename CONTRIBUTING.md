# Contributing

Start with [AGENTS.md](AGENTS.md), the [architecture](docs/ARCHITECTURE.md), [roadmap](docs/ROADMAP.md), and [development workflow](docs/DEVELOPMENT.md). Issue branches target `alpha`; owner-authorized promotion follows `alpha` → `beta` → `preview` → `main`. Architecture decisions are recorded in [ADRs](docs/adr/README.md). Merged code and accepted release gates are separate outcomes.

LibraVia is an early native Apple-platform MVP. The project retains all rights under LICENSE; discuss contribution terms with the maintainer before submitting code.

Use the shared LibraVia scheme and the documented OS 27 toolchain. Keep provider-neutral models separate from Jellyfin DTOs. Prefer Apple frameworks and the official Jellyfin SDK; do not add dependencies without discussing first-party provenance and necessity.

Use original/public-domain fixtures and synthetic accounts. Never commit private server URLs, credentials, tokens, device identifiers, provisioning files, personal logs, screenshots of a real library, or local account paths. Report aggregate results, with simulator, Mac, physical device, and live-server checks separated. Do not include full HTTP requests/responses or raw system errors in issues.

Run the relevant core and renderer checks and destination builds in README. Explain the behavior changed and material unverified limits. Uploading a build, distributing it, changing server metadata, and publishing source are separate actions.
