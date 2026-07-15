# Contributing to Hangar

Thank you for your interest in contributing! This document explains the
workflow, quality expectations, and ground rules.

## Getting Started

1. Fork the repository and create a feature branch from `main`.
2. Make your changes on the feature branch.
3. Open a pull request against `main`.

## Development Setup

```bash
# Clone your fork
git clone https://github.com/<you>/hangar.git
cd hangar

# Copy the example environment file
cp .env.workers.example .env.workers
# Edit .env.workers with your credentials (never commit this file)
```

## Quality Gates

Before opening a PR, ensure the following pass locally:

```bash
# Run the full test/validation suite
bash tests/final-gate.sh

# Lint shell scripts (requires shellcheck)
shellcheck -x *.sh worker/*.sh tests/*.sh
```

Pull requests that fail CI checks will not be merged.

## Pull Request Process

1. Keep PRs focused — one logical change per PR.
2. Fill out the PR template checklist (privacy, tests, gate).
3. Ensure your branch is up to date with `main`.
4. A maintainer will review and may request changes.
5. Once approved, a maintainer will merge.

## Code Style

- **Shell scripts:** Follow [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
  conventions. All scripts must pass ShellCheck without errors.
- **Dockerfiles:** Pin tool/runtime versions where practical, minimize layers, and use
  `--no-install-recommends`. Digest-pinned base-image improvements are welcome.
- **Markdown:** One sentence per line (for clean diffs). Use reference links
  for long URLs.

## What to Contribute

- Bug fixes with regression tests.
- Documentation improvements.
- Test coverage for untested paths.
- Security hardening.
- CI/tooling improvements.

## What Not to Include

- **Secrets, credentials, or private keys** — even as examples. Use
  placeholder values like `github_pat_...` or `ssh-ed25519 AAAA...`.
- **Private repository names, hostnames, IPs, or file paths** from your
  environment.
- **Real GitHub App IDs or installation IDs.**
- **Historical commit SHAs** from private repositories.
- **Fixtures containing real repository content** — use synthetic test data.

If you accidentally commit a secret, notify a maintainer immediately so it can
be rotated and scrubbed from history.

## Security

If you discover a security vulnerability, **do not open a public issue.**
See [SECURITY.md](SECURITY.md) for private reporting instructions.

When contributing code that touches credential handling, container isolation,
or network exposure, please include a brief security rationale in your PR
description.

## Documentation

- Update the README if your change affects user-facing behavior.
- Add or update inline comments for non-obvious logic.
- If adding a new script, include a usage comment block at the top.

## Licensing

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE). A Developer Certificate of Origin (DCO) sign-off is
not currently required but may be adopted in the future.

## Repository Settings Recommendations

The following settings cannot be enforced via committed files and should be
configured by repository administrators:

- **Branch protection on `main`:** Require PR reviews, require status checks
  to pass, require linear history, do not allow force pushes.
- **Enable GitHub Private Vulnerability Reporting** under
  Settings → Security → Private vulnerability reporting.
- **Enable Dependabot** alerts and security updates.
- **Restrict who can push** to `main` (maintainers only).
- **Disable merge commits** — prefer squash or rebase merges for clean
  history.
