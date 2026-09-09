# Security reporting

Please do not publish suspected vulnerabilities, exploit details, credentials, private code, or chat data
in GitHub issues or pull requests.

## Reporting a vulnerability

Reports are handled by the **source-truth repository maintainers**.

- If **Report a vulnerability** is available in this repository's **Security** tab, use that private reporting flow.
- If it is unavailable, open an issue titled **Private security contact requested**, without technical details,
  and ask a maintainer to arrange a private channel before sharing the report.

After a private channel is established, include the affected commit, a minimal reproduction, impact,
relevant SDK/model/region, and redacted logs. Do not test against deployments or repositories you do not own
or have permission to assess.

## Versions and scope

Development targets `main`. Include the exact affected commit and, when possible, check whether the issue
also reproduces on current `main`; this project does not maintain a separate LTS release line.

Read-only tools, repository/path checks, IAM permissions, and output redaction are documented in
[the security invariants](docs/agent/invariants.md). Model output still needs review; prompt instructions
alone do not establish a security boundary. For non-sensitive functional bugs, use the normal issue template.
