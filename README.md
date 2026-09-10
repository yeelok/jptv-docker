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
   browser (mpegts.js / HLS)          /recordings/*.ts ◀──▶ ┌──────────────────┐
        ▲   recorded playback                               │     postrec      │
        └───────────────────────────────────────────────── │  NVEncC (GPU):   │
                     (KonomiTV reads /recordings)           │  MPEG-2 → HEVC   │
                                                            │  in place        │
                                                            └──────────────────┘
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
| **postrec** | Post-record compressor — watches `/recordings`, re-encodes finished recordings MPEG-2 → HEVC in place (optional, NVIDIA GPU) | — | build `./edcb` (reuses `tv-edcb`) | [rigaya/tsreplace](https://github.com/rigaya/tsreplace) · [rigaya/NVEnc](https://github.com/rigaya/NVEnc) |

---

## Prerequisites

- A **PLEX PX-MLT / PX4 / PX5-series tuner** (this reference uses PX-MLT8PE) with a **B-CAS or ACAS card**
  seated in the tuner's internal card slot.
- A **Linux host** with **Docker** and the **Docker Compose v2** plugin.
- The **px4_drv kernel driver — specifically the [`yyya-nico/px4_drv`](https://github.com/yyya-nico/px4_drv)
  fork** — built and loaded on the host, exposing the device nodes:
  - `/dev/pxmlt8video0` … `pxmlt8video7` (tuners)
  - `/dev/pxmlt8card0` (card reader)

  > **The fork is not optional.** Upstream px4_drv (nns779 / tsukumijima, and any distro package built
  > from it) creates only the `*video*` nodes — it has no card-reader code at all. Only the fork ships
  > `driver/px4_card.c` and registers `/dev/pxmlt8card0`. Without that node there is nothing to
  > descramble with, and the whole b25/bcas chain is dead. See
  > [1. Install the host driver](#1-install-the-host-driver).

  > You only need the **kernel module** on the host — the PC/SC **IFD handler (`ifd-px4`)** is compiled
  > *inside the `bcas` image*. The host must **not** run its own `pcscd`; see
  > [Disable the host-side PC/SC daemon](#disable-the-host-side-pcsc-daemon).

Verify before starting:

```bash
ls /dev/pxmlt8video* /dev/pxmlt8card0     # all nine nodes exist (pxmlt8card0 ⇒ the fork is loaded)
grep pxmlt8card /proc/devices              # char major registered by the fork's card driver
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
├── edcb/                   # EDCB image (Dockerfile) + conf/ (INIs, ChSet) + watch-recordings.sh (postrec)
├── KonomiTV/               # git submodule → your fork of KonomiTV
└── px4_drv/                # git submodule → yyya-nico/px4_drv (reference / IFD handler source)
```

`KonomiTV/` and `px4_drv/` are **git submodules** (their own upstream projects).

### About the KonomiTV fork

KonomiTV's internal HTTP server binds to a fixed loopback address in source, with no config option.
This stack changes it to `0.0.0.0` (one line in `server/KonomiTV.py`) so you can front KonomiTV with
**your own reverse proxy** on port `7010`. That change lives in a **fork** of KonomiTV, pinned as the
submodule. The fork carries two additions over upstream:

- **`bind-0.0.0.0`** — the one-line listen-address change above.
- **Live HLS endpoint** — an API-only addition that serves the live stream as HLS (see
  [Live HLS streaming](#live-hls-streaming-api-only)); upstream only offers live TV as MPEG-TS.

> If you only use KonomiTV's built-in HTTPS (Akebi) on port `7000`, you don't need the change — point
> the submodule at upstream `tsukumijima/KonomiTV` instead.

---

## Setup

### 1. Install the host driver

The card-reader node `/dev/pxmlt8card0` is created by the **kernel module**, and only the
[`yyya-nico/px4_drv`](https://github.com/yyya-nico/px4_drv) fork has that code. Install upstream px4_drv
(or a distro package) and you get the eight tuner nodes and no card node — live TV tunes, but nothing
can ever be descrambled.

This failure is easy to misread, because building the fork's `userland/ifd-px4` on the host **is not
enough on its own**: the handler installs and loads fine, then correctly reports that the device it
needs does not exist —

```
ifdhandler.c:801:px4_ifd_open_by_usb_path() No available device for VID=0511 PID=0253 (prefix=pxmlt8card)
readerfactory.c:371:RFAddReader() PLEX PX-MLT8PE Smart Card Reader (…) init failed.
```

That message means **the wrong kernel driver is installed**, not that the handler or the card is broken.

Install the fork via DKMS (the `px4_drv/` submodule in this repo *is* that fork, pinned):

> These commands run from a clone of this repo, so do [2. Clone with submodules](#2-clone-with-submodules)
> first if you haven't — or clone [`yyya-nico/px4_drv`](https://github.com/yyya-nico/px4_drv) on its own
> and use that path instead.

```bash
git submodule update --init px4_drv          # if you didn't clone with --recursive

# 1. remove any px4_drv already installed, so only one module is ever in play
dkms status | grep px4_drv                   # e.g. "px4_drv/0.5.6, 7.0.0-30-generic, x86_64: installed"
sudo dkms remove px4_drv/<installed-version> --all
sudo rm -rf /usr/src/px4_drv-<installed-version>

# 2. install the fork — its dkms.conf declares 0.5.5, and the directory name must match
sudo rsync -a --exclude .git px4_drv/ /usr/src/px4_drv-0.5.5/
sudo dkms add     -m px4_drv -v 0.5.5
sudo dkms install -m px4_drv -v 0.5.5        # post_install also installs the udev rules + firmware

# 3. reload
sudo modprobe -r px4_drv && sudo modprobe px4_drv
```

Insert your B-CAS/ACAS card, then confirm **all nine** nodes exist — `pxmlt8card0` is the one that
proves the fork is loaded:

```bash
ls -l /dev/pxmlt8video* /dev/pxmlt8card0
```

The kernel log should show the card node being created alongside the tuners:

```
px4_drv: px4_card: device context group (pxmlt8card) created
px4_usb 2-1:1.0: /dev/pxmlt8card0
```

If `/dev/pxmlt8card0` is missing, the wrong driver is still installed — re-check `dkms status`,
`grep pxmlt8card /proc/devices`, and that `/usr/src/px4_drv-*/driver/px4_card.c` exists.

> The fork tracks an older upstream release (0.5.5 vs 0.5.6), so this is a slight downgrade of the
> tuner driver itself. That is inherent to using it.

#### Disable the host-side PC/SC daemon

This stack runs **`pcscd` + `ifd-px4` inside the `bcas` container**, so the host must not run its own.
`/dev/pxmlt8card0` is opened **exclusively** — whichever `pcscd` claims it first wins and the other gets
nothing. A host `pcscd` is easy to start by accident: it is socket-activated, so *any* local PC/SC client
(`pcsc_scan`, GnuPG, a browser smart-card module) spawns it on demand, and it then takes the reader away
from `bcas`, which fails with `B_CAS_CARD::init() : code=-3`.

Disable **and mask** both units — masking is what actually stops socket activation from bringing it back:

```bash
sudo systemctl disable --now pcscd.socket pcscd.service
sudo systemctl mask pcscd.socket pcscd.service
```

Verify nothing holds the device:

```bash
systemctl is-active pcscd.socket pcscd.service   # inactive  inactive
pgrep -a pcscd                                    # no output
```

If you want to test the card on the host first, do it **before** masking — and know that two unrelated
quirks make a perfectly good reader look broken:

- `pcsc_scan` as a normal user over SSH fails with `SCardEstablishContext: Access denied.` The
  `org.debian.pcsc-lite.access_pcsc` polkit action grants only `allow_active`, and an SSH session is
  seatless, so it does not qualify. Use `sudo pcsc_scan`.
- Starting `pcscd.service` directly wipes `/run/pcscd` (`RuntimeDirectory=pcscd`), deleting the
  `pcscd.comm` socket that `pcscd.socket` is listening on; clients then get
  `SCardEstablishContext: Service not available.` Recreate it with `sudo systemctl restart pcscd.socket`.

A healthy reader prints the B-CAS ATR, e.g. `ATR: 3B F0 12 00 FF 91 81 B1 7C 45 1F 03 99` →
*Japanese Chijou Digital B-CAS Card (pay TV)*. Re-mask `pcscd` when you are done.

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

`edcb` and `postrec` run as UID `1000` so recordings are owned by your host user. For a **local**
directory, create it owned by that UID:

```bash
sudo mkdir -p /recordings && sudo chown 1000:1000 /recordings
```

#### If `/recordings` is a network share (NFS/SMB)

Ownership is then the *server's* to decide and `chown` on the client is meaningless — you have to make
the export writable by UID `1000` on the server side. Watch out for one trap: **the mode bits you see on
the client can be misleading.** A share can show `drwxrwxrwx` yet still refuse writes, because the real
grant lives in the server's ACL / share permissions and is keyed to a specific uid or gid.

The failure is asymmetric and easy to misdiagnose — the host writes fine while the containers don't:

```bash
touch /recordings/probe                                                   # works as your user
docker run --rm -u 1000:1000 -v /recordings:/t busybox touch /t/probe     # Permission denied
```

That gap is supplementary groups. Your login shell carries a dozen of them; a container started with
`user: "1000:1000"` carries **none**, so any grant that depends on a group is silently lost. AUTH_SYS
sends bare numeric ids, so a *local* group of yours can also collide with an unrelated group on the
server and make host writes succeed for the wrong reason.

Find the gid the server actually honours by bisecting your own groups:

```bash
for g in $(id -G); do
  printf 'gid %-5s ' "$g"
  docker run --rm -u 1000:1000 --group-add "$g" -v /recordings:/t busybox \
    sh -c 'touch /t/.probe && rm -f /t/.probe && echo OK || echo FAIL'
done
```

then add the winner to the services that write recordings — `edcb` and `postrec` (not `edcb_chscan`,
which has no `/recordings` mount):

```yaml
  edcb:
    user: "1000:1000"
    group_add:
      - "101"      # gid the share grants write to
```

> The reference `docker-compose.yaml` ships `group_add: ["101"]` because this setup stores recordings on
> a Synology NAS over NFS, where that share is writable by gid `101` (`administrators`). **Change or drop
> it to match your storage** — it is environment-specific, not a general requirement.

Verify the whole recording lifecycle before starting the stack, since a mid-recording `mv` failure in
`postrec` is a much worse way to find out:

```bash
docker run --rm -u 1000:1000 --group-add 101 -v /recordings:/t busybox sh -c '
  echo x > /t/rec.ts && mv /t/rec.ts /t/rec.part.ts && rm -f /t/rec.part.ts && echo LIFECYCLE_OK'
```

KonomiTV needs no such treatment: it runs as root and reaches recordings through its `/` → `/host-rootfs`
bind mount, which carries the network submount along with it.

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

> **Create an account.** Live/recorded viewing works anonymously, but **admin-only actions —
> deleting recordings, changing server settings — require being logged in as an admin**, otherwise
> you'll see *"録画ファイルを削除するには管理者権限が必要です。"*. Register from the KonomiTV UI
> (アカウント作成); the **first account created is automatically the admin**.

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
  (H.264, play with `mpegts.js`; e.g. `gr011`/`1080p`), `GET /api/streams/live/{…}/{…}/hls`
  ([live HLS](#live-hls-streaming-api-only), this fork), `GET /api/programs/timetable`,
  `POST /api/programs/search`, `GET/POST /api/recording/reservations`, `GET /api/recording/presets`,
  `GET /api/videos`. Some write/account endpoints need a Bearer token from `POST /api/users/token`.

> Note: mirakc's raw streams are broadcast **MPEG-2** and won't play in a bare browser `<video>`. Use a native
> player (mpv/VLC) for mirakc URLs, or KonomiTV (which transcodes to H.264) for browser playback.

### Live HLS streaming (API only)

Upstream KonomiTV serves live TV only as a continuous MPEG-TS (`…/mpegts`, for `mpegts.js`). This fork
adds a **live HLS** endpoint (API only — not wired into the KonomiTV UI):

- Playlist: `GET /api/streams/live/{display_channel_id}/{quality}/hls` → sliding-window `.m3u8`
- Segments: `GET /api/streams/live/{display_channel_id}/{quality}/hls/{segment}` → MPEG-TS segment

Example: `http://<host>:7010/api/streams/live/gr011/1080p/hls` plays in any HLS player (Safari, hls.js,
VLC, ffmpeg). How it works: it taps the **same shared encoder** as `…/mpegts` via an internal client and
runs `ffmpeg -c copy -f hls` (no second transcode), so live-HLS and `mpegts.js` viewers share one tuner.
The segmenter starts on first playlist request and **auto-stops ~30 s after the last request**, freeing
the tuner. First request blocks briefly (a few seconds) while the tuner spins up and the first segments
are written.

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

## Surviving a host reboot

`mirakc`'s compose entry lists all eight tuner device nodes, and Docker fails at **container
creation** when even one is absent:

```
Error response from daemon: error gathering device information while adding
custom device "/dev/pxmlt8video5": no such file or directory
```

A creation failure never reaches the restart policy, so `mirakc` stays `Exited (255)` indefinitely
and **KonomiTV crash-loops behind it** (it validates `mirakurun_url` at startup and refuses to run
without a reachable tuner server). The result is a total, silent outage — no alert anywhere, missed
recordings, and nothing recovers on its own.

This is not hypothetical: on a virtualised host the hypervisor presented only one of the card's two
USB devices at VM boot, `video5-7` never appeared, and the stack sat down for three days.

**The real fix is host-side.** If the tuner is a PCIe card in a VM, pass the *card* through with
VFIO instead of forwarding its individual USB devices — the guest then owns the real controller and
does not depend on the hypervisor re-presenting two USB devices correctly at every boot.

### The watchdog (guest-side safety net)

`scripts/tuner-watchdog.sh` + a systemd timer make the guest recover by itself. Every 5 minutes
(and 90 s after boot) it:

1. checks all nine device nodes (`pxmlt8video0-7` + `pxmlt8card0`);
2. if any are missing, re-enumerates the card's USB devices via `/sys/.../authorized` — which
   recovers a device the kernel bound but left in a no-data state, though it cannot conjure one the
   hypervisor never presented — and logs a loud `ERROR` if they are still absent;
3. once all devices are present, runs `docker compose up -d` to start whatever is down.

On a healthy system it is a silent no-op. Install it with:

```bash
sudo cp scripts/jptv-watchdog.service scripts/jptv-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now jptv-watchdog.timer
```

Check on it with:

```bash
systemctl list-timers jptv-watchdog.timer      # next/last run
journalctl -u jptv-watchdog.service -n 50      # what it did, and why
```

> **Debugging?** `touch .watchdog-disabled` in the project root and the watchdog does nothing, so a
> deliberate `docker stop` isn't undone 5 minutes later. Remove the file to re-arm it.

> The timer uses `OnUnitInactiveSec`, not `OnUnitActiveSec`: the service is `Type=oneshot`, so it
> goes inactive as soon as it finishes and `OnUnitActiveSec` would leave the timer with no anchor
> (`systemctl list-timers` shows an empty `NEXT`).

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
  to HEVC, copying audio / captions / SDT-EIT through unchanged, then replaces the raw `.ts` in place.
  Already-HEVC files are skipped (idempotent).
- tsreplace drives **[NVEncC](https://github.com/rigaya/NVEnc)** (rigaya, GPU) as its encoder — *not*
  ffmpeg. NVEncC reads the ARIB TS natively and preserves its PTS/DTS, so tsreplace interleaves the
  passthrough streams (audio / captions / PSI / PCR) evenly across the output. This is essential:
  KonomiTV plays recordings by seeking to a mid-file keyframe and re-encoding forward, so an encoder
  whose output made tsreplace cluster PSI/PCR (as an ffmpeg pipe does) would leave mid-file segments
  with no PAT/PMT and no audio, and both cataloging and playback would fail. Because NVEncC keeps the
  mux well-formed, the recordings catalog and play with **stock KonomiTV** — no fork patches needed.

Requires the GPU override (`postrec` gets GPU access via `docker-compose.nvidia.yaml`). The watcher is a
**safe no-op** (recordings kept raw) on hosts without a GPU. To disable, just don't run the `postrec`
service. Captions are preserved (unlike a plain ffmpeg re-encode).

Progress and results go to the container's stdout — follow them with:

```bash
docker logs -f postrec       # "compressing…", "done: N -> M bytes", or failures (with NVEncC output)
```

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
| `/dev/pxmlt8card0` missing (tuner nodes fine) | The **wrong px4_drv** is installed — upstream has no card-reader code. Install the fork, see [1. Install the host driver](#1-install-the-host-driver). Confirm with `grep pxmlt8card /proc/devices`. |
| pcscd: `No available device for VID=0511 … (prefix=pxmlt8card)` | Same cause. The `ifd-px4` handler is working and telling you `/dev/pxmlt8card0` doesn't exist — it's the kernel module that's wrong, not the handler. |
| `b25 \| B_CAS_CARD::init() : code=-3` | `pcscd` in `bcas` can't get the reader. Either a **host `pcscd` has the device open exclusively** (mask it — see [Disable the host-side PC/SC daemon](#disable-the-host-side-pcsc-daemon)), or `/dev/pxmlt8card0` isn't passed / doesn't exist. The `ifd-px4` handler itself is already in the image via the build. |
| `pcsc_scan`: `SCardEstablishContext: Access denied.` | polkit, not the driver — `access_pcsc` allows only `allow_active` and an SSH session is seatless. Use `sudo pcsc_scan`. Irrelevant once the host `pcscd` is masked. |
| `pcsc_scan`: `SCardEstablishContext: Service not available.` | `pcscd.service` started directly wiped `/run/pcscd` and with it the `pcscd.comm` socket. `sudo systemctl restart pcscd.socket`. |
| Recording preset fetch fails: `EpgTimerSrv.ini is empty` (HTTP 500) | Set `CompatFlags=128` in `edcb/conf/EpgTimerSrv.ini` and restart `edcb`. |
| Guide is empty on the EDCB backend | EDCB gathers EPG on the `[EPG_CAP]` schedule; trigger one now from the Material WebUI (`:5510`) or wait for the next slot. |
| `mirakc` `Exited (255)`, KonomiTV restart-looping | A tuner device node is missing, so Docker can't create the mirakc container (`error gathering device information ... no such file or directory`), and a create-time failure bypasses the restart policy. Check `ls /dev/pxmlt8video*` and `lsusb \| grep 0511` — if a USB device is absent the hypervisor must re-present it. See [Surviving a host reboot](#surviving-a-host-reboot). |
| Recordings owned by `root` | `edcb` must run as your UID (`user: "1000:1000"`), and `/recordings` + `edcb/conf/Setting` must be writable by it. |
| `edcb`/`postrec`: `Permission denied` writing to `/recordings`, but your shell writes there fine | `/recordings` is a network share whose grant is keyed to a **group**. A `user: "1000:1000"` container carries no supplementary groups, so it loses that grant while your login shell keeps it. Find the gid and add it via `group_add` — see [If `/recordings` is a network share](#if-recordings-is-a-network-share-nfssmb). Note the mode can read `drwxrwxrwx` and still deny writes. |
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
