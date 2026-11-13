# mujina-ui

A single-binary, web-based UI for [mujina-miner](https://github.com/256foundation/mujina).

Runs alongside `mujina-minerd` on the miner, polls its REST API, tails its
log file, and serves a dashboard to your browser. No frontend build step
— a single static HTML file embedded in the binary.

```
                      ┌──────────────────────────────────────────┐
                      │  mujina-ui  (single static binary)        │
                      │                                           │
   Browser  ─────────►│──► :7782    GET /                         │
   (HTTP)             │             GET /api/state    ───────┐    │
                      │             GET /api/logs (SSE) ──┐  │    │
                      │             POST /api/control/*   │  │    │   ┌─────────────────┐
                      │                                   │  └────┼──►│ mujina-minerd   │
                      │             ┌─────────────────────┘       │   │ REST /api/v0    │
                      │             │                             │◄──│   :7785         │
                      │             ▼                             │   └─────────────────┘
                      │   tail -f /var/log/mujina-minerd.log       │
                      └────────────────────────────────────────────┘
```

## What you see

- **State** — paused / heating / ready, derived from `paused` + `hashrate`.
- **Aggregate metrics** — hashrate (auto-scaled H/s → TH/s), uptime, shares
  submitted, best difficulty.
- **Boards** — every connected board, broken into threads (hashrate +
  active flag), temperatures, fans (rpm / duty / target), powers (V / A / W).
- **Sources** — pool URL + current share difficulty per job source.
- **Raw JSON** — collapsible "show raw `/api/v0/miner`" panel for debugging.
- **Logs** — live tail of mujina's log file via Server-Sent Events. The
  last ~32 kB of context is replayed on connect; new lines stream in real
  time. Filter box + auto-follow toggle. ANSI color codes are stripped;
  severity (INFO/WARN/ERROR/DEBUG/TRACE) is detected and colorized.
- **Controls** — pause / resume (`heat_off` / `heat_on`) maps to
  `PATCH /api/v0/miner` `{"paused":bool}`.

## Configuration

All via environment variables.

| Var | Default | Notes |
|---|---|---|
| `MUJINA_UI_LISTEN` | `0.0.0.0:7782` | HTTP bind |
| `MUJINA_API_URL` | `http://127.0.0.1:7785` | mujina REST base |
| `MUJINA_UI_LOG_PATH` | `/var/log/mujina-minerd.log` | file the log viewer tails |
| `RUST_LOG` | `info` | tracing-subscriber env-filter |

## Build

Native:

```sh
cargo build --release
```

Cross-build for Antminer S19 (and similar aarch64/musl boards):

```sh
rustup target add aarch64-unknown-linux-musl
brew install messense/macos-cross-toolchains/aarch64-unknown-linux-musl

CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-unknown-linux-musl-gcc \
CC_aarch64_unknown_linux_musl=aarch64-unknown-linux-musl-gcc \
  cargo build --release --target aarch64-unknown-linux-musl
```

Result is a statically-linked binary with no runtime dependencies.

## Install on a miner (LuxOS / OpenWrt or PetaLinux)

```sh
scripts/install.sh root@<miner-ip>
```

Same shape as the bridge installers: probes the remote, picks procd or
sysvinit, drops a binary into `/usr/bin/`, defaults into
`/etc/default/mujina-ui`, init script into `/etc/init.d/mujina-ui`,
enables on boot, and starts. Idempotent for upgrades; operator overrides
in the defaults file survive.

After install:

```sh
ssh root@<miner-ip> 'logread -f | grep mujina-ui'        # tail UI's own logs
ssh root@<miner-ip> 'vi /etc/default/mujina-ui'           # config
ssh root@<miner-ip> '/etc/init.d/mujina-ui restart'

scripts/uninstall.sh root@<miner-ip>          # keep config
scripts/uninstall.sh root@<miner-ip> --purge  # remove everything
```

Open <http://&lt;miner-ip&gt;:7782> in a browser.

## Architecture

- **One binary, no external dependencies.** HTML/CSS/JS lives in
  `assets/index.html` and is `include_str!`-ed into the binary, served at
  `/`. No npm, no webpack, no dist directory.
- **Schema-tolerant.** The state proxy uses `serde_json::Value` rather
  than typed structs, so the UI renders whatever fields mujina happens to
  expose. New fields appear in the "raw JSON" panel automatically; the
  curated cards display what the frontend knows how to format.
- **SSE for logs.** A long-running `EventSource` connection per browser;
  reconnect is handled by the browser. Backend opens the log file, seeks
  to `tail-32 KB`, then polls every 250 ms for newly appended bytes. ANSI
  escape sequences are stripped server-side so the frontend just renders
  text.
- **Pause/resume goes through mujina, not the UI.** `POST
  /api/control/pause` invokes `PATCH /api/v0/miner` `{"paused":true}` on
  mujina. The UI never holds state — every refresh re-asks mujina.

## License

GPL-3.0-or-later, matching mujina.

## Versions and releases

Versioned `vMAJOR.MINOR.PATCH`, released only from a clean `main` with
`scripts/release.sh vX.Y.Z` (tags, tests, builds aarch64-musl, publishes
`mujina-ui-aarch64` + `SHA256SUMS` on
[the releases page](https://github.com/RY3T/mujina-ui/releases)). The binary
embeds `git describe --tags --match 'v*' --dirty`: it is logged at startup and
returned as `version` by `GET /api/info`. Deploy only release binaries; a
`-dirty` or `-N-gHASH` version is not one.

