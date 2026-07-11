# jptv-docker — Japanese TV (ISDB-T/S) recording & streaming stack

A self-hosted, all-Docker stack for **watching live and recorded Japanese television in your
browser**, with a full program guide (EPG) and scheduled recording. It wires together a tuner
server, hardware descrambling, a recording backend, and a modern web UI on top of a PLEX
PX-MLT–series tuner.

> **Status:** working reference setup for a **PLEX PX-MLT8PE** (8 tuners) in the Tokyo (関東) area.
> Everything is parameterized — adapt the tuner model, channel lineup, and paths to your environment
> (see [Adapting to your environment](#adapting-to-your-environment)).

---

## Features

- 📺 **Live TV in the browser** — no plugins; broadcast MPEG-2 is transcoded to H.264 on the fly (KonomiTV).
- 🗓️ **Program guide (EPG)** — collected by mirakc *and* EDCB.
- ⏺️ **Scheduled recording** — reservations, recording presets, and keyword auto-record via EDCB, driven from KonomiTV's UI.
- 🔓 **Hardware descrambling** — B-CAS/ACAS via the tuner's internal card reader, decoupled into its own service.
- 🎞️ **Recorded-video library** — browse, seek, and play recordings in KonomiTV.
- 🔌 **Open APIs** — Mirakurun-compatible REST (mirakc), EDCB HTTP/JSON API, KonomiTV REST API, and an IPTV M3U playlist + XMLTV.
- 🧩 **8 tuners** shared across live viewing, EPG gathering, and recording.

---

## Architecture

```
  PX-MLT8PE (PCIe): 8 tuners + internal B-CAS card reader
        │  px4_drv (yyya-nico fork) + ifd-px4 handler   ← kernel driver on the HOST
        ▼
  /dev/pxmlt8video0-7            /dev/pxmlt8card0
        │                              │
        ▼                              ▼
   ┌─────────┐   decode filter    ┌─────────┐  pcsc/TCP   ┌────────────────────┐
   │ mirakc  │ ─────────────────▶ │   b25   │ ──────────▶ │        bcas        │
   │ :40772  │ ◀── decoded TS ─── │ :40773  │             │ :40774 pcscd +     │
   └────┬────┘                    └─────────┘             │        ifd-px4     │
        │  Mirakurun-compatible HTTP API                  └────────────────────┘
        │
        ├───────────────────────────────────┐
        │  live TV                           │  BonDriver_LinuxMirakc (decode=1)
        ▼                                    ▼
   ┌──────────┐   reservations / EPG   ┌──────────────┐
   │ KonomiTV │ ◀────────────────────▶ │     EDCB     │  EpgTimerSrv
   │ :7000 HTTPS (Akebi)               │ :4510  :5510 │  recording + reservations + own EPG
   │ :7010 HTTP  (→ your proxy)        └──────┬───────┘
   └────┬─────┘                               ▼
   browser (mpegts.js / HLS)          /recordings/*.ts
```

Two independent data paths:

- **Live viewing** — KonomiTV pulls the (already-descrambled) stream from mirakc and transcodes
  MPEG-2 → H.264, delivered to the browser via `mpegts.js`. mirakc gets a decoded stream because its
  `decode-filter` pipes the raw TS through **b25** (the ARIB-B25 descrambler), which reads the B-CAS
  card through **bcas** (a `pcscd` + PX4 IFD-handler service).
- **Recording** — EDCB tunes through mirakc using **BonDriver_LinuxMirakc** with `DECODE_B25=1`, so it
  reuses the exact same descrambling chain (no card needed inside EDCB). EDCB owns reservations, recording,
  and its own EPG database; KonomiTV talks to it over the EpgTimerNW TCP API.

### Components

| Service | Role | Ports | Image / build | Upstream |
|---|---|---|---|---|
| **mirakc** | Tuner server + EPG (Mirakurun-compatible) | `40772` | `mirakc/mirakc:3.4.76-alpine` | [mirakc/mirakc](https://github.com/mirakc/mirakc) |
| **b25** | ARIB-B25 descrambler | `40773` | build `./b25` | [tsukumijima/libaribb25](https://github.com/tsukumijima/libaribb25) |
| **bcas** | Card-reader server (`pcscd` + PX4 IFD handler) | `40774` | build `./bcas` | [yyya-nico/px4_drv](https://github.com/yyya-nico/px4_drv) (`userland/ifd-px4`) |
| **edcb** | Recording backend (EpgTimerSrv) + Material WebUI | `4510`, `5510` | build `./edcb` | [xtne6f/EDCB](https://github.com/xtne6f/EDCB) · [matching/BonDriver_LinuxMirakc](https://github.com/matching/BonDriver_LinuxMirakc) · [EMWUI/EDCB_Material_WebUI](https://github.com/EMWUI/EDCB_Material_WebUI) |
| **konomitv** | Web UI — live & recorded viewing | `7000` (HTTPS), `7010` (HTTP) | submodule (fork of) | [tsukumijima/KonomiTV](https://github.com/tsukumijima/KonomiTV) |

---

## Prerequisites

- A **PLEX PX-MLT / PX4 / PX5-series tuner** (this reference uses PX-MLT8PE) with a **B-CAS or ACAS card**
  seated in the tuner's internal card slot.
- A **Linux host** with **Docker** and the **Docker Compose v2** plugin.
- The **px4_drv kernel driver** built and loaded on the host, exposing the device nodes:
  - `/dev/pxmlt8video0` … `pxmlt8video7` (tuners)
  - `/dev/pxmlt8card0` (card reader)

  Build it from the [`yyya-nico/px4_drv`](https://github.com/yyya-nico/px4_drv) fork (DKMS supported).
  > You only need the **kernel module** on the host. The PC/SC **IFD handler (`ifd-px4`)** is compiled
  > *inside the `bcas` image* — no host-side `pcscd`/handler install required.

Verify before starting:

```bash
ls /dev/pxmlt8video* /dev/pxmlt8card0     # devices exist
lsusb | grep 0511                          # tuner enumerated (VID 0x0511)
```

---

## Repository layout

```
.
├── docker-compose.yaml     # the orchestrator: ties all services together
├── mirakc/                 # mirakc config (tuners, channel lineup, decode filter)
├── b25/                    # ARIB-B25 descrambler image
├── bcas/                   # card-reader (pcscd + ifd-px4) image
├── edcb/                   # EDCB image (Dockerfile) + conf/ (INIs, ChSet)
├── KonomiTV/               # git submodule → your fork of KonomiTV
└── px4_drv/                # git submodule → yyya-nico/px4_drv (reference / IFD handler source)
```

`KonomiTV/` and `px4_drv/` are **git submodules** (their own upstream projects).

### About the KonomiTV fork

KonomiTV's internal HTTP server binds to a fixed loopback address in source, with no config option.
This stack changes it to `0.0.0.0` (one line in `server/KonomiTV.py`) so you can front KonomiTV with
**your own reverse proxy** on port `7010`. That change lives in a **fork** of KonomiTV, pinned as the
submodule. The fork carries a second small patch too — a `MetadataAnalyzer` fix so GPU-compressed HEVC
recordings catalog correctly (see [Post-record compression](#post-record-compression-optional-nvidia-gpu)).

> If you only use KonomiTV's built-in HTTPS (Akebi) on port `7000`, you don't need the change — point
> the submodule at upstream `tsukumijima/KonomiTV` instead.

---

## Setup

### 1. Install the host driver

Build and load `px4_drv` from the fork, insert your B-CAS/ACAS card, and confirm the device nodes exist
(see [Prerequisites](#prerequisites)).

### 2. Clone with submodules

```bash
git clone --recursive https://github.com/<your-username>/jptv-docker.git
cd jptv-docker
# already cloned without --recursive?
git submodule update --init --recursive
```

### 3. Configure

- **mirakc** — `mirakc/config.yml`: tuner devices, channel lineup (edit for your region), and the
  `decode-filter` that forwards to `b25`. The lineup here is Tokyo (関東) GR + BS.
- **KonomiTV** — copy `KonomiTV/config.example.yaml` → `KonomiTV/config.yaml` and set:
  ```yaml
  general:
      backend: 'EDCB'
      edcb_url: 'tcp://127.0.0.1:4510/'
      mirakurun_url: 'http://127.0.0.1:40772/'
      always_receive_tv_from_mirakurun: true   # live viewing stays direct on mirakc (low latency)
  video:
      recorded_folders: ['/recordings']         # host path; KonomiTV reads it via /host-rootfs
  ```
- **EDCB** — `edcb/conf/*.ini` ship with working defaults (8 tuners, EPG 4×/day, setting-file transfer
  enabled). Adjust `[BonDriver_LinuxMirakc.so] Count` if you have a different tuner count.

### 4. Prepare the recordings directory

`edcb` runs as UID `1000` so recordings are owned by your host user. Create the output dir owned by that UID:

```bash
sudo mkdir -p /recordings && sudo chown 1000:1000 /recordings
```

### 5. Build and start

```bash
docker compose up -d --build
```

### 6. Run the EDCB channel scan (one-time)

Generates `ChSet4/ChSet5` from mirakc's channel list. Re-run only when your lineup changes.

```bash
docker compose --profile scan run --rm edcb_chscan
```

### 7. Verify

```bash
# mirakc knows the services
curl -s http://127.0.0.1:40772/api/services | head
# EDCB reachable + recording presets load (proves CompatFlags + EpgTimerNW)
curl -s http://127.0.0.1:7010/api/recording/presets
```

Open KonomiTV at **`https://<host-ip-with-dashes>.local.konomi.tv:7000/`** (Akebi), or via your own
reverse proxy in front of `:7010`. EDCB's guide fills in after its first EPG gather (or trigger one from
the Material WebUI at `http://<host>:5510/`).

---

## Configuration reference

### Ports

| Port | Service | Purpose |
|---|---|---|
| `40772` | mirakc | Mirakurun-compatible HTTP API / streams |
| `40773` | b25 | ARIB-B25 descramble server (internal) |
| `40774` | bcas | `pcscd` proxy / card reader (internal) |
| `4510` | edcb | EpgTimerNW TCP API (KonomiTV ↔ EDCB) |
| `5510` | edcb | EDCB Material WebUI + HTTP/JSON API |
| `7000` | konomitv | KonomiTV HTTPS (via Akebi) |
| `7010` | konomitv | KonomiTV internal HTTP (front with your own proxy) |

### Key knobs

- **mirakc `decode-filter`** (`mirakc/config.yml`) — pipes each stream through `b25:40773` for descrambling.
- **KonomiTV** — `backend: EDCB`, `edcb_url`, `always_receive_tv_from_mirakurun: true`, `recorded_folders`.
- **EDCB `edcb/conf/EpgTimerSrv.ini`**:
  - `CompatFlags=128` — allows EpgTimerNW to serve setting files; **required** or KonomiTV's recording-preset
    fetch fails with `EpgTimerSrv.ini is empty`.
  - `[EPG_CAP]` — automatic EPG acquisition schedule (default: 5:00 / 11:00 / 17:00 / 23:00 daily).
  - `[BonDriver_LinuxMirakc.so] Count=8` — number of tuners EDCB may use via mirakc.
- **EDCB `BonDriver` `DECODE_B25=1`** — requests decoded streams from mirakc (reuses b25/bcas; EDCB needs no card).
- **`edcb` `user: "1000:1000"`** (compose) — recordings owned by the host user.

---

## Usage & APIs

- **KonomiTV** — live TV, program guide, recording reservations, recorded-video library.
- **mirakc (Mirakurun-compatible REST)**
  - Stream a service: `http://<host>:40772/api/services/{id}/stream?decode=1` (MPEG-TS)
  - IPTV playlist: `http://<host>:40772/api/iptv/playlist?decode=1` · XMLTV: `.../api/iptv/xmltv`
  - Docs: `http://<host>:40772/api/docs`
- **EDCB (HTTP/JSON API, `?json=1`)**
  - EPG: `http://<host>:5510/api/EnumEventInfo?json=1` · services: `.../api/EnumService?json=1`
  - reservations: `.../api/EnumReserveInfo?json=1` (+ `SetReserve` etc.)
- **KonomiTV (REST)** — full **interactive API docs are served by KonomiTV itself** (auto-generated
  OpenAPI; there is no separate doc on the upstream repo):
  - Swagger UI (try-it-out): `http://<host>:7010/api/docs`
  - ReDoc (reference): `http://<host>:7010/api/redoc`
  - OpenAPI spec (import into Postman/Insomnia): `http://<host>:7010/api/openapi.json`

  Handy endpoints: `GET /api/channels`, `GET /api/streams/live/{display_channel_id}/{quality}/mpegts`
  (H.264, play with `mpegts.js`; e.g. `gr011`/`1080p`), `GET /api/programs/timetable`,
  `POST /api/programs/search`, `GET/POST /api/recording/reservations`, `GET /api/recording/presets`,
  `GET /api/videos`. Some write/account endpoints need a Bearer token from `POST /api/users/token`.

> Note: mirakc's raw streams are broadcast **MPEG-2** and won't play in a bare browser `<video>`. Use a native
> player (mpv/VLC) for mirakc URLs, or KonomiTV (which transcodes to H.264) for browser playback.

---

## Recording notes

- Recording, reservations, keyword auto-record, and presets are provided by **EDCB** (the Mirakurun/mirakc
  backend of KonomiTV does *not* support recording — EDCB is required for it).
- EDCB keeps its **own** EPG (gathered through mirakc); it can't import mirakc's parsed EPG.
- Recordings land in `/recordings` as `*.ts`, owned by UID `1000`, and appear in KonomiTV's library.
- **Benign warning:** while a recording is in progress you'll see repeated
  `… .ts: File is not recording. ignored.` in KonomiTV's log. It's a cosmetic quirk of the file scanner
  (it can't confirm "actively recording" from the file's growth pattern across the container mount). The
  recording is unaffected and is cataloged normally when it finishes. **Don't cancel recordings because of it.**

---

## Hardware transcoding (optional, NVIDIA GPU)

By default KonomiTV transcodes live TV in **software** (FFmpeg / libx264). With an **NVIDIA GPU**
you can offload decode + encode to the GPU via **NVEncC** (NVDEC + NVENC), freeing the CPU:

1. On the host, install the **NVIDIA driver** and the **NVIDIA Container Toolkit**:
   ```bash
   sudo apt-get install -y nvidia-container-toolkit
   sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
   docker run --rm --gpus all ubuntu nvidia-smi     # should list your GPU
   ```
2. Set `encoder: 'NVEncC'` in `KonomiTV/config.yaml`.
3. Layer the GPU override (`docker-compose.nvidia.yaml`) onto the stack — either per command:
   ```bash
   docker compose -f docker-compose.yaml -f docker-compose.nvidia.yaml up -d
   ```
   or persistently: copy `.env.example` → `.env` and uncomment the `COMPOSE_FILE` line, after which
   plain `docker compose …` includes the override automatically.

KonomiTV validates the encoder against the GPU **at startup**, so do steps 1–2 before enabling the
override (otherwise it won't start). Verify with `nvidia-smi` while watching a channel — you'll see
an `NVEncC.elf` process and non-zero encoder/decoder utilization.

> The base `docker-compose.yaml` has **no** GPU requirement, so it runs anywhere. AMD (`VCEEncC` +
> `/dev/dri`) and Intel (`QSVEncC`) follow the same override pattern with the appropriate encoder.

## Post-record compression (optional, NVIDIA GPU)

EDCB writes recordings as raw MPEG-2 TS (~6–8 GB/hour). With a GPU, finished recordings are
auto-compressed to **HEVC** — **keeping ARIB captions and program metadata (SDT/EIT)** so they stay
fully catalogued in KonomiTV — cutting size by roughly **50–65%**.

How it works:
- A dedicated **`postrec`** service (a watcher built from the `tv-edcb` image — `edcb/watch-recordings.sh`)
  scans `/recordings` and compresses any recording whose size has been **stable for ~2 min** — i.e. any
  *finished* recording, whether it ended naturally **or was stopped/cancelled early**. (A watcher is used
  rather than EDCB's post-record bat because the bat only fires on natural completion.)
- It uses **[tsreplace](https://github.com/rigaya/tsreplace)** (rigaya) to re-encode *only* the video PID
  to HEVC via NVENC, copying audio / captions / SDT-EIT through unchanged, then replaces the raw `.ts`
  in place. Already-HEVC files are skipped (idempotent).
- The KonomiTV fork includes a small `MetadataAnalyzer` fix so re-encoded HEVC recordings catalog
  (upstream's sample-probe otherwise misses the re-muxed audio).

Requires the GPU override (`postrec` gets GPU access via `docker-compose.nvidia.yaml`). The watcher is a
**safe no-op** (recordings kept raw) on hosts without a GPU. To disable, just don't run the `postrec`
service. Captions are preserved (unlike a plain ffmpeg re-encode).

## Adapting to your environment

- **Different tuner model** — update the `devices:` and the card device in `docker-compose.yaml`, the
  device names in `mirakc/config.yml`, and (if the card-device prefix differs) confirm `ifd-px4` supports it.
- **Different region / channels** — edit the `channels:` list in `mirakc/config.yml`, then re-run the EDCB scan.
- **Different host UID** — change `user:` on the `edcb`/`edcb_chscan` services and the `/recordings` owner to match.
- **Own TLS / domain** — either front KonomiTV's `:7010` with your reverse proxy (this stack's default),
  or set `custom_https_certificate` / `custom_https_private_key` in KonomiTV's config to use Akebi with your cert.

---

## Keeping dependencies current

All images and git refs are **pinned** (see the reproducibility note in the Dockerfiles). To check
whether any upstream has a newer version:

```bash
python3 scripts/check-updates.py
```

It reads the current pins from the source files and compares them against upstream (Docker Hub tags,
git `HEAD`s, EDCB `work-plus-s-*` tags, KonomiTV releases), printing a table and exiting non-zero if
updates exist — so you can run it from cron or CI. To apply an update, edit the pin it points you to
(e.g. bump `mirakc/mirakc:3.4.x-alpine` or the EDCB tag / a clone SHA), then rebuild that service.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `b25 \| B_CAS_CARD::init() : code=-3` | `pcscd` in `bcas` can't see the reader — the `ifd-px4` handler must be in the image (it is, via the build). Ensure `/dev/pxmlt8card0` is passed and the tuner shows up as USB `0511:*`. |
| Recording preset fetch fails: `EpgTimerSrv.ini is empty` (HTTP 500) | Set `CompatFlags=128` in `edcb/conf/EpgTimerSrv.ini` and restart `edcb`. |
| Guide is empty on the EDCB backend | EDCB gathers EPG on the `[EPG_CAP]` schedule; trigger one now from the Material WebUI (`:5510`) or wait for the next slot. |
| Recordings owned by `root` | `edcb` must run as your UID (`user: "1000:1000"`), and `/recordings` + `edcb/conf/Setting` must be writable by it. |
| `File is not recording. ignored.` spam | Harmless (see [Recording notes](#recording-notes)). |

---

## Credits & licenses

This stack is glue around excellent upstream projects — all credit to their authors. Each retains its own license:

- [KonomiTV](https://github.com/tsukumijima/KonomiTV) · [mirakc](https://github.com/mirakc/mirakc) ·
  [EDCB (xtne6f)](https://github.com/xtne6f/EDCB) · [BonDriver_LinuxMirakc](https://github.com/matching/BonDriver_LinuxMirakc) ·
  [EDCB_Material_WebUI](https://github.com/EMWUI/EDCB_Material_WebUI) · [px4_drv (yyya-nico)](https://github.com/yyya-nico/px4_drv) ·
  [libaribb25](https://github.com/tsukumijima/libaribb25) · [Akebi](https://github.com/tsukumijima/Akebi)

This repository (the orchestration: compose file, service Dockerfiles, and configs) is provided as-is.
For personal, private use only — respect Japanese broadcasting terms and copyright.
