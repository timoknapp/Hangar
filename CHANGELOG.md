# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased] — v0.1.0

Initial extraction baseline. Hangar is published as source-only; no prebuilt
container images are distributed at this time.

### Added

- Interactive Dockerfile — trusted ttyd/SSH-enabled Copilot development environment.
- Worker Dockerfile — autonomous squad worker with credential-guard isolation.
- `deploy.sh` — fleet orchestration via Docker Compose.
- `auth-setup.sh` — interactive GitHub CLI, SSH, and repository bootstrap.
- `repo-add.sh` — clone additional repositories into the trusted interactive workspace.
- `entrypoint.sh` — interactive container init with SSH, nginx, and ttyd.
- `tests/final-gate.sh` — pre-merge validation gate.
- Credential-guard launcher and preload constructor for worker model-token isolation.
- `.env.workers.example` — reference configuration template.

### Changed

- Unified the trusted interactive service and all guarded workers under one `hangar-fleet`
  Compose project while retaining separate service-level trust boundaries and persistent volumes.
- Split interactive SSH, ttyd, and preview bind addresses so operators can expose only the
  service they explicitly need.
- Existing operators who set `INTERACTIVE_BIND_ADDRESS` must replace it with the corresponding
  `INTERACTIVE_SSH_BIND_ADDRESS`, `INTERACTIVE_TTYD_BIND_ADDRESS`, and/or
  `INTERACTIVE_PREVIEW_BIND_ADDRESS` settings.
