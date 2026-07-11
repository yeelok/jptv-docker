#!/bin/sh
# Capture + descramble test using the mirakc container image.
#
# The mirakc image's recpt1/recdvb are built WITHOUT --enable-b25, so recpt1
# does NOT descramble. Descrambling is done by mirakc-arib's `decode` filter,
# which talks to the B-CAS card via pcscd. This script mirrors mirakc's real
# pipeline: recpt1 (tune/capture raw) | mirakc-arib decode (descramble).
#
# Requires: docker, a B-CAS card seated in the tuner slot, pcscd running on host.
# Usage:   ./mirakc_capture_test.sh <channel> [tuner_device] [duration_sec]
# Example: ./mirakc_capture_test.sh 27
#          ./mirakc_capture_test.sh BS15_0 /dev/pxmlt8video1 15

set -eu

IMAGE='docker.io/mirakc/mirakc:3.4.76-alpine'
CHANNEL="${1:-}"
TUNER="${2:-/dev/pxmlt8video0}"
DURATION="${3:-10}"

OUT_DIR="$(pwd)"
RAW_FILE="mirakc_test_raw.ts"       # scrambled capture
DEC_FILE="mirakc_test_decoded.ts"   # after mirakc-arib decode

if [ -z "${CHANNEL}" ]; then
  echo "Usage: $0 <channel> [tuner_device] [duration_sec]" >&2
  echo "  e.g. $0 27" >&2
  echo "       $0 BS15_0 /dev/pxmlt8video1 15" >&2
  exit 1
fi

# host-side sanity checks
[ -e "${TUNER}" ]    || { echo "ERROR: tuner ${TUNER} not found on host" >&2; exit 1; }
[ -e /dev/pxmlt8card0 ] || { echo "ERROR: /dev/pxmlt8card0 not found - is px4_drv loaded with card support?" >&2; exit 1; }

echo "== Test 1: capture ${DURATION}s raw (scrambled) on ${CHANNEL} via ${TUNER} =="
docker run --rm \
  --device="${TUNER}:${TUNER}" \
  --device=/dev/pxmlt8card0:/dev/pxmlt8card0 \
  -v "${OUT_DIR}:/out" \
  --entrypoint= \
  "${IMAGE}" \
  sh -c "recpt1 --device ${TUNER} ${CHANNEL} ${DURATION} /out/${RAW_FILE}" \
  || { echo "recpt1 capture failed - check channel/tuner/signal" >&2; exit 1; }
echo "raw capture:"; ls -l "${OUT_DIR}/${RAW_FILE}"

echo
echo "== Test 2: descramble the raw capture with mirakc-arib decode (uses card via pcscd) =="
docker run --rm \
  --device=/dev/pxmlt8card0:/dev/pxmlt8card0 \
  -v "${OUT_DIR}:/out" \
  --entrypoint= \
  "${IMAGE}" \
  sh -c "cat /out/${RAW_FILE} | mirakc-arib decode > /out/${DEC_FILE}" \
  || { echo "mirakc-arib decode failed - card not readable via pcscd?" >&2; exit 1; }
echo "decoded output:"; ls -l "${OUT_DIR}/${DEC_FILE}"

echo
echo "== Test 3: analyze the decoded stream with mirakc-arib =="
# scan-services only returns data if the stream demuxes cleanly (i.e. descrambled)
docker run --rm \
  -v "${OUT_DIR}:/out" \
  --entrypoint= \
  "${IMAGE}" \
  sh -c "cat /out/${DEC_FILE} | mirakc-arib scan-services 2>/dev/null | jq -M . || echo '(scan-services returned nothing)'" \
  || true

cat << 'EOT'

== How to read the result ==
* Test 2 produces a decoded file of similar (slightly smaller) size to the raw
  file, and Test 3 prints one or more services (with sid/name) as JSON:
    -> DESCRAMBLING WORKS. Tuner + internal card reader + mirakc-arib decode
       are all functioning. You are done with the driver/card side.
* Test 2 fails, or Test 3 prints nothing / errors:
    -> the stream was NOT descrambled. Verify on the host that `pcsc_scan`
       shows the reader AND an ATR line (card inserted), and that the card is
       a valid B-CAS/ACAS card seated in the tuner slot.
* Compare sizes: a successfully decoded TS is close to the raw size; a near-zero
  or empty decoded file means decode produced nothing.

Note: this image has NO ffprobe/ffmpeg and recpt1 is built WITHOUT --enable-b25
by design - descrambling is mirakc-arib's job, which is what this script tests.
EOT