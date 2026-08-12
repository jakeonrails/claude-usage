# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities using GitHub's private vulnerability
reporting, not a public issue: open the **Security** tab on
[jakeonrails/claude-usage](https://github.com/jakeonrails/claude-usage) and
click **Report a vulnerability**. That opens a private advisory visible only
to the maintainer until it's resolved.

## Supported versions

Only the latest GitHub release is supported. There are no prebuilt binaries
for older versions — every install is a local, signed build (see
[Build](README.md#build) and [Code signing](CLAUDE.md#code-signing--load-bearing-for-keychain-acls)
in CLAUDE.md), so "supported" means the current `main`/latest tag; there's
no backport policy for older releases.

## Security posture

For how this app talks to Anthropic, what it stores locally, and how to
disconnect it, see [Security & privacy](README.md#security--privacy) in the
README.
