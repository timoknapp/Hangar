# Third-Party Notices

Hangar integrates with and depends on third-party software. This file documents
the key dependencies, their licenses, and redistribution status.

## Hangar Source License

Hangar's own source code is licensed under the [MIT License](LICENSE).

Copyright (c) 2026 Hangar contributors.

---

## Components Installed by User-Built Images

### GitHub Copilot CLI (`@github/copilot`)

Hangar's Dockerfiles install GitHub Copilot CLI from npm at image build time.
**Hangar does not relicense GitHub Copilot CLI.** The CLI is governed by its
own license terms, reproduced in full at:

> [`licenses/GITHUB-COPILOT-CLI-LICENSE.md`](licenses/GITHUB-COPILOT-CLI-LICENSE.md)

- **Upstream project:** <https://github.com/github/copilot-cli>
- **npm package:** `@github/copilot`
- **License:** GitHub Copilot CLI License (separate source-available redistribution terms)
- **Official terms:** <https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features#github-copilot>

**Redistribution status:** Hangar v0.1 is published as **source-only**. No
prebuilt Docker images containing the Copilot CLI binary are distributed at
this time. If prebuilt images are published in the future, packaging compliance
with GitHub's redistribution terms will be required and documented here.

### Squad CLI (`@bradygaster/squad-cli`)

Hangar's full-team implementer uses the Squad custom agent and CLI. The package is
installed from npm at image build time.

- **Upstream:** <https://github.com/bradygaster/squad>
- **npm package:** `@bradygaster/squad-cli`
- **License:** MIT; reproduced at [`licenses/SQUAD-LICENSE.md`](licenses/SQUAD-LICENSE.md)

Squad relies on GitHub Copilot services for model inference; those services remain
subject to GitHub's applicable terms.

---

## Runtime Dependencies (installed at build time)

The following are installed inside Docker images at build time. They are **not
redistributed** in Hangar's source repository. Users building images are
responsible for compliance with each dependency's license.

| Component | License | Source |
| --- | --- | --- |
| Debian 12 (bookworm-slim) | Various (DFSG) | <https://www.debian.org/> |
| Node.js | MIT | <https://nodejs.org/> |
| GitHub CLI (`gh`) | MIT | <https://github.com/cli/cli> |
| tmux | ISC | <https://github.com/tmux/tmux> |
| ttyd | MIT | <https://github.com/tsl0922/ttyd> |
| nginx | BSD-2-Clause | <https://nginx.org/> |
| jq | MIT (CC-BY-3.0 docs) | <https://jqlang.github.io/jq/> |
| curl | MIT/X derivative | <https://curl.se/> |
| OpenSSH | BSD | <https://www.openssh.com/> |
| Git | GPL-2.0 | <https://git-scm.com/> |
| ShellCheck (development/CI only) | GPL-3.0 | <https://www.shellcheck.net/> |

### GPL Note

Git is included in the runtime images; ShellCheck is used by development/CI. They
are invoked as separate processes and are not linked into Hangar's MIT-licensed
code. If you distribute Docker images, ensure source-availability and notice
obligations for included components.

---

## AI Service Dependencies

Hangar sends source code, prompts, and context to **GitHub Copilot** for AI
inference. This is a cloud service dependency, not a software dependency.
Review GitHub's data handling policies:

- <https://resources.github.com/copilot-trust-center/>
- <https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement>

Hangar does not claim to be a fully self-hosted AI solution.

---

## How to Verify

To inspect the exact versions and licenses of packages installed in a built
image, run:

```bash
docker run --rm <image> dpkg-query -W -f '${Package} ${Version}\n'
docker run --rm <image> npm ls --all --json 2>/dev/null | jq '.dependencies'
```
