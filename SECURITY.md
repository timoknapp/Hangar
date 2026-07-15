# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| main    | :white_check_mark: |

Hangar follows a rolling-release model. Only the latest commit on `main` is
supported. Pin to a specific commit SHA if you need stability.

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Use the repository's **Security → Report a vulnerability** flow to submit a confidential report.
You will receive an initial acknowledgment
within 72 hours. We aim to provide a substantive response (fix, mitigation, or
timeline) within 14 days.

If your report involves a vulnerability in an upstream dependency (GitHub
Copilot CLI, GitHub CLI, Docker, Node.js, etc.), please also report it to the
upstream project.

## Threat Model

Hangar runs GitHub Copilot CLI agents inside Docker containers on a
**single-tenant host you control**. The following assumptions and boundaries
apply:

### Trust Boundaries

| Boundary | Trust Level | Notes |
| --- | --- | --- |
| Docker host | **Trusted** | The operator controls the host OS, Docker daemon, and network. |
| Interactive container | **Trusted** | Operator-controlled development environment with a persistent shell. |
| Worker containers | **Semi-trusted** | Run autonomous agents against assigned repos. Agents execute arbitrary shell commands inside the container. |
| Target repositories | **Must be operator-trusted** | Repository code, instructions, hooks, and MCP definitions can cause arbitrary code execution and outbound data transfer inside the worker container. |
| GitHub Copilot API | **External** | Source code, prompts, and context are sent to GitHub's Copilot service. Hangar does not claim to be a fully self-hosted AI solution. |
| External network | **Untrusted** | Containers may fetch dependencies, clone repos, and communicate with web services. Data may traverse external networks. |

### Key Security Properties

1. **Docker is not a VM boundary.** Container isolation provides defense in
   depth but is not equivalent to hardware virtualization. A container escape
   grants host access. Run Hangar on a dedicated host or VM if your threat
   model requires stronger isolation.

2. **Credential isolation (publisher vs. implementation).** The GitHub App PEM
   and short-lived installation token are protected by OS ownership and the
   publisher's non-traversable home directory. The separate Copilot PAT has only
   the account-level Copilot Requests permission. It is delivered through an
   anonymous pipe to a native launcher; token-bearing processes are marked
   non-dumpable before and after exec, and named auth variables are stripped from
   shell/MCP child environments. These credential domains must not be merged.

3. **Token-free Git remotes.** Worker containers clone repositories using
   GitHub App installation tokens obtained at runtime. Tokens are never
   persisted in Git remote URLs. The `tests/` suite includes guards that
   verify no tokenized remotes exist.

4. **Human merge gate.** Workers create pull requests but never merge them
   directly. A human reviewer must approve and merge all changes. Configure
   branch protection/rulesets on target repositories if this must be enforced
   independently of Hangar's worker code.

5. **Localhost network defaults.** ttyd and SSH listeners bind to `127.0.0.1`
   by default. Exposing these services to a network requires explicit port
   mapping in your Docker Compose configuration.

6. **No secrets in source.** Environment files (`.env`, `.env.workers`,
   `repos.json`) are gitignored. The `.env.workers.example` file contains
   only placeholder values.

7. **Implementation capability is intentionally broad.** Full Squad sessions can
   execute arbitrary local shell commands, fetch external URLs, install packages,
   and start MCP servers configured by the target repository. Hangar protects
   publication credentials; it does not prevent source-code exfiltration over
   allowed egress. Treat target repositories and their MCP configuration as trusted.

### Known Risks & Mitigations

| Risk | Severity | Mitigation |
| --- | --- | --- |
| Malicious MCP server in target repo executes arbitrary code or exfiltrates source | High | Trust target repos; use dedicated host/VM; restrict egress externally if required; publisher/model credential isolation limits credential impact. |
| Copilot API receives source code | Medium | Inherent to Copilot usage. Review [GitHub's Copilot Trust Center](https://resources.github.com/copilot-trust-center/). |
| Container escape via kernel exploit | High | Run on dedicated host/VM; keep Docker and kernel updated; consider gVisor/Kata for hardened runtimes. |
| Worker pushes unwanted changes | Medium | Human merge gate; branch protection; PR review required. |
| Leaked PEM/PAT in logs or environment | High | OS file permissions; anonymous-pipe model token; non-dumpable process tree; `.env` files gitignored; log scrubbing recommended. |
| Supply-chain attack on base image or dependencies | Medium | CLI versions are pinned; use Dependabot; review Dockerfile and base-image updates. Base-image digest pinning remains future hardening. |

### What Hangar Is Not

- **Not a sandbox.** Hangar does not sandbox LLM-generated code beyond
  standard Docker container isolation.
- **Not fully self-hosted AI.** All AI inference is performed by GitHub
  Copilot's cloud service. Hangar orchestrates the agent runtime, not the
  model.
- **Not multi-tenant.** Hangar is designed for a single operator. There is no
  user authentication, RBAC, or tenant isolation.

## Incident Response

If a security incident is confirmed:

1. Rotate all affected credentials (GitHub App PEM, Copilot PAT, SSH keys).
2. Stop and remove compromised containers.
3. Audit Git history of target repositories for unauthorized commits.
4. Review Docker host logs for signs of container escape.
5. Report findings through the repository's private vulnerability reporting flow.

## Security-Related Configuration

See the [README](README.md) for credential setup instructions and the
`.env.workers.example` file for reference configuration.
