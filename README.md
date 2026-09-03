# TiltBar

macOS menu bar status for a running `tilt up`. Shows the same red / yellow / green
counts as the Tilt web UI header, lists resources that need a human (failed updates,
manual-trigger resources with unapplied changes), and lets you trigger them from the
dropdown.

    ✕ 2  ⚙ 1  ✓ 63/66

## Build and run

    make install     # builds dist/TiltBar.app and copies it to /Applications
    open /Applications/TiltBar.app

`make run` opens the freshly built copy from `dist/` instead. `make stop` kills it.
Requires the Xcode command line tools (SwiftPM + AppKit); no Xcode project needed.

## How it talks to Tilt

- Status is polled every 2s from Tilt's apiserver (`uiresources`). Address and
  bearer token are read from `~/.tilt-dev/config`, which `tilt up` rewrites each run.
- Triggers POST to the web server at `localhost:10350/api/trigger`, using the
  session token the web UI receives as the `Tilt-Token` cookie. A stale token is
  refreshed automatically after a Tilt restart.
- "Open in Tilt UI" opens `localhost:10350/r/<resource>/overview`.

The menu bar shows `◦ tilt off` in gray when the apiserver is unreachable.

## Menu

- Summary line and **Open Tilt UI** (⌘O)
- **Needs attention**: resources in error or with pending changes. Each resource is a
  submenu with its status line, a trigger action ("Apply pending changes", "Retry",
  "Run again" for local tasks), "Open in Tilt UI", and any endpoint links.
- **In progress**: resources currently building or waiting on runtime.
- **All resources**: every resource grouped by Tiltfile label, worst status first.
- **Re-run Tiltfile**, notification toggle for newly failing resources, Refresh, Quit.

## Environment overrides

| Variable               | Default                | Purpose                         |
|------------------------|------------------------|---------------------------------|
| `TILT_PORT`            | `10350`                | Tilt web server port            |
| `TILT_CONFIG`          | `~/.tilt-dev/config`   | apiserver kubeconfig            |
| `TILTBAR_POLL_SECONDS` | `2`                    | polling interval                |

## Homebrew

    brew install --cask tjq/tap/tiltbar

Releases are universal, signed, and notarized. Build one with `./release.sh`.
