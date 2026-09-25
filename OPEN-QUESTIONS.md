# Publication and release follow-ups

The owner selected a **public** repository under `zenit2893-cmyk` and the `Copyright (c) 2026, Project 1944 contributors` line for the project's BSD-3-Clause license. Xenia's earlier notice is preserved separately.

- The first downloadable release date is not set. Do not present the source repository as a downloadable game package.
- No in-game screenshots or publisher artwork are included. Launcher artwork is the project's own. Any future game screenshots need a separate owner decision.
- `docs/reports/` is deliberately trimmed to Markdown engineering notes. Local receipts, raw logs, diagnostic JSON, and build artifacts remain outside Git.
- The pinned XenosRecomp submodule has local shader-tool changes in the development workspace. They are recorded as a patch under `integration/xenos-gradients-v2/`; review and apply that patch when reproducing the corresponding experimental tooling work.
- Full-campaign completion, compatibility with other game revisions, and other-PC performance remain unverified. Future release notes must state the actual test scope.
