# Security Policy

## Supported versions

Guaranate is pre-1.0 and ships from `main`. Security fixes land on `main` and in
the next tagged release. Only the latest release is supported.

| Version | Supported |
| --- | --- |
| latest release / `main` | :white_check_mark: |
| older releases | :x: |

## Reporting a vulnerability

**Please do not open a public issue for security reports.**

Report privately via GitHub's
[private vulnerability reporting](https://github.com/ryok90/guaranate/security/advisories/new).
Include:

- a description of the issue and its impact,
- steps to reproduce (a minimal command line is ideal),
- the Guaranate version (`guaranate --version`) and your macOS version.

You can expect an initial acknowledgement within a few days. Once a fix is
ready, it will be released and the advisory published with credit to the
reporter (unless you prefer to remain anonymous).

## Scope

Guaranate creates IOKit power assertions on the local machine and does not open
network connections or handle untrusted remote input. Relevant reports include
anything that could leave a **stale power assertion** behind, escalate
privileges, or cause the tool to change system sleep policy without release.
