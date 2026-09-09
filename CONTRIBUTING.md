# Contributing to source-truth

Bug reports, documentation fixes, and focused pull requests are welcome in English or Chinese.
Read the [README](README.md) for the current scope and [AGENTS.md](AGENTS.md) for repository conventions.

## Bugs and feature proposals

Use [GitHub Issues](https://github.com/ddpie/source-truth/issues). Search existing issues first and include:

- The commit SHA or release you are using, operating system, and relevant component.
- Steps to reproduce, expected behavior, and actual behavior.
- The selected SDK, model, and region when relevant, plus a small redacted log excerpt.

Do not attach credentials, `.local/` contents, private source code, or personal chat data.
Report vulnerabilities through [SECURITY.md](SECURITY.md), not a public issue.
Discuss substantial changes first, especially proposals outside the read-only MVP boundary.

## Development setup

Use **Python 3.11**, **Node.js 24**, Git, Bash, and ripgrep. The runtime is ARM64-only, but most offline
tests also run on x86. From the repository root:

```bash
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install --no-deps -r agent-container/requirements.lock
sed -n '/^openpyxl==/p' index-service/requirements.txt > .venv/index-test-requirements.txt
python -m pip install -r .venv/index-test-requirements.txt pytest ruff==0.15.15
python -m pip check
npm ci --prefix bot-gateway
./scripts/test.sh
```

The shared test environment uses the agent's locked dependencies and the index service's Excel dependency.
Do not install all three service dependency sets into one environment: the agent, index bridge, and offline
glossary worker deliberately have separate dependency versions. The [CI workflow](.github/workflows/ci.yml)
shows the additional isolated environments it validates.

`./scripts/test.sh` runs lint, unit tests, and type checks without AWS credentials. Read its `SKIPPED:`
summary. Missing Python or Node dependencies must be fixed. The two CodeGraph bridge integration suites
require a compatible `codegraph-server` binary on `PATH`; CI explicitly permits their absence on its x86
runner. See [index-service setup](index-service/README.md) to run them on a supported host.

`./scripts/test.sh --full` also invokes an existing AWS deployment. It can incur charges and skips the live
probe when no deployment is configured; the separate smoke stage remains a placeholder. Report exactly
what ran rather than treating skipped checks as verification.

## Pull requests

1. Fork the repository and create a focused branch such as `fix/followup-extraction` or `docs/quick-start`.
2. Make the change with relevant regression coverage. For documentation, check commands, links, and facts against the implementation.
3. Run `./scripts/test.sh` and `git diff --check`. Explain any skipped checks or unavailable live validation.
4. Describe the problem, resulting behavior, and validation in the pull request. Include deployment impact when applicable.

Use Conventional Commits (`fix:`, `feat:`, `docs:`, etc.). Do not edit generated artifacts directly;
regenerate them from their sources. Do not include AI attribution trailers.

The root `README.md` contains Chinese first and English second; update both sections together.
Paired `docs/*_en.md` and `docs/*_zh.md` files must stay in sync. Structural changes also update the
[directory maps](docs/structure_en.md). Deployment-specific records belong under the ignored `.local/`
directory. There are no repository-installed Git hooks; CI runs the checks independently.

## Community and licensing

Follow the [Code of Conduct](CODE_OF_CONDUCT.md). Contributions are provided under the project's
[MIT license](LICENSE); retain applicable third-party notices.
