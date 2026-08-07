# Contributing to Agentic Notifs

Contributions are welcome through GitHub issues and pull requests.

## Development Setup

You need macOS 13 or newer, Swift 6 or newer, and Node.js 18 or newer. The project has no external package dependencies.

Run the complete local check before opening a pull request:

```sh
./Scripts/test.sh
```

Keep changes focused, update the README when behavior changes, and add deterministic coverage to the existing self-tests or adapter tests when fixing a bug.

## Pull Requests

- Explain the user-visible problem and the chosen solution.
- Note any macOS, terminal, or coding-agent versions used for manual testing.
- Do not commit local configuration, event tokens, credentials, build output, or signing assets.
- Confirm that `./Scripts/test.sh` passes.

By contributing, you agree that your contribution is licensed under the repository's MIT License.
