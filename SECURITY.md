# Security Policy

## Supported versions

Security fixes are applied to the latest release. Please make sure you're on the most recent
version before reporting.

| Version                 | Supported |
| ----------------------- | --------- |
| Latest release (`main`) | ✅        |
| Older releases          | ❌        |

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Instead, report it privately through GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability):
go to the repository's **Security** tab → **Report a vulnerability**.

Please include:

- a description of the issue and its impact,
- steps to reproduce (a proof of concept if possible), and
- the app version and your macOS version.

You can expect an initial response within a few days. Once a fix is available it will be released,
and your report credited unless you prefer to remain anonymous.

## Scope

Ghostty Config Editor is a local macOS app. It reads and writes your Ghostty configuration files and
invokes your locally installed `ghostty` binary — it has no server component and makes no network
requests. The most relevant concerns are therefore the safe handling of local configuration files
and the `ghostty` subprocess the app launches.
