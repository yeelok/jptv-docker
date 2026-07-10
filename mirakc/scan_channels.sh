#!/bin/sh
# mirakc channel scan for PX-MLT8PE (using mirakc docker container image)
# based on uru2's scan_ch_mirakc_docker.sh
#
# require: docker, jq
#
# IMPORTANT (PX-MLT8PE / PX-MLT5PE):
#   Disable discard_null_packets before scanning, otherwise recpt1 hangs
#   on some BS channels (e.g. BS03_2) past the record duration:
#     options px4_drv discard_null_packets=N
#   then reload px4_drv (rmmod/modprobe or reboot).
#
# Your device nodes (px4_drv 0.5.6):
#   /dev/pxmlt8video0 .. /dev/pxmlt8video7  (8 tuners, all GR/BS/CS capable)

set -eu
export LANG=C.UTF-8

readonly EXTRACT_SID="${EXTRACT_SID:-0}"
readonly OUTPUT_FILE='mirakc_channels.yml'

readonly CONTAINER_IMAGE='docker.io/mirakc/mirakc:latest'

# PX-MLT8PE: any node can tune GR/BS/CS. Adjust as you like.
readonly DEVICE_MAP_GR='/dev/pxmlt8video0:/dev/pxmlt8video0'
readonly DEVICE_MAP_BS='/dev/pxmlt8video1:/dev/pxmlt8video1'
readonly DEVICE_MAP_CS='/dev/pxmlt8video1:/dev/pxmlt8video1'

# record commands. PX-MLT8PE supplies LNB power internally, so no --lnb needed.
readonly RECORD_COMMAND_GR='recpt1 --device /dev/pxmlt8video0 <channel> 10 -'
readonly RECORD_COMMAND_BS='recpt1 --device /dev/pxmlt8video1 <channel> 20 -'
readonly RECORD_COMMAND_CS='recpt1 --device /dev/pxmlt8video1 <channel> 10 -'

# scan target channels: GR (physical channels 13-52; trim to your region)
CHANNELS_GR="$(cat << 'EOT'
13
14
15
16
17
18
19
20
21
22
23
24
25
26
27
28
29
30
31
32
33
34
35
36
37
38
39
40
41
42
43
44
45
46
47
48
49
50
51
52
EOT
)"
CHANNELS_GR=$(echo "${CHANNELS_GR}" | grep -e '^[^#]')

# scan target channels: BS
CHANNELS_BS="$(cat << 'EOT'
BS01_0
BS01_1
BS01_2
BS01_3
BS03_0
BS03_1
BS03_2
BS03_3
BS05_0
BS05_1
BS05_2
BS05_3
BS09_0
BS09_1
BS09_2
BS09_3
BS11_0
BS11_1
BS11_2
BS11_3
BS13_0
BS13_1
BS13_2
BS13_3
BS15_0
BS15_1
BS15_2
BS15_3
BS19_0
BS19_1
BS19_2
BS19_3
BS21_0
BS21_1
BS21_2
BS21_3
BS23_0
BS23_1
BS23_2
BS23_3
EOT
)"
CHANNELS_BS=$(echo "${CHANNELS_BS}" | grep -e '^[^#]')

# scan target channels: CS
CHANNELS_CS="$(cat << 'EOT'
CS2
CS4
CS6
CS8
CS10
CS12
CS14
CS16
CS18
CS20
CS22
CS24
EOT
)"
CHANNELS_CS=$(echo "${CHANNELS_CS}" | grep -e '^[^#]')

# find required tools
if [ ! "$(which docker)" ]; then echo 'require docker' >&2; exit 1; fi
if [ ! "$(which jq)" ]; then echo 'require jq' >&2; exit 1; fi

all_lists=''

scan_band() {
  type="$1"; channels="$2"; cmd_base="$3"; dev_map="$4"
  list=''
  for ch in ${channels}; do
    echo "[type: ${type}, channel: ${ch}]" >&2
    rec_cmd="$(echo "${cmd_base}" | sed -e "s/<channel>/${ch}/")"
    json=$(docker run --rm "--device=${dev_map}" --entrypoint= -i "${CONTAINER_IMAGE}" \
      sh -c "${rec_cmd} 2> /dev/null | /usr/local/bin/mirakc-arib scan-services 2> /dev/null" \
      | jq -M -c || printf '')
    [ -z "${json}" ] && continue

    sname=$(echo "${json}" | jq -M -r '.[0] | .name')
    sid=$(echo "${json}" | jq -M -r '.[] | .sid' | jq -M -s . | jq -M -r 'join(",")')

    # duplicate-sid skip (BS empty slots return slot 0 info)
    if [ "${type}" = 'BS' ] && [ -n "${list}" ]; then
      for line in ${list}; do
        [ "$(echo "${line}" | cut -f 4)" = "${sid}" ] && { sid=''; break; }
      done
      [ -z "${sid}" ] && continue
    fi

    [ "${type}" = 'CS' ] && sname="${ch}"
    list=$(printf '%s\n%s\t%s\t%s\t%s' "${list}" "${type}" "${ch}" "${sname}" "${sid}" | sed '/^$/d')
  done
  if [ -n "${list}" ]; then
    all_lists=$(printf '%s\n%s' "${all_lists}" "${list}" | sed '/^$/d')
  fi
}

[ -n "${DEVICE_MAP_GR}" ] && [ -n "${RECORD_COMMAND_GR}" ] && scan_band 'GR' "${CHANNELS_GR}" "${RECORD_COMMAND_GR}" "${DEVICE_MAP_GR}"
[ -n "${DEVICE_MAP_BS}" ] && [ -n "${RECORD_COMMAND_BS}" ] && scan_band 'BS' "${CHANNELS_BS}" "${RECORD_COMMAND_BS}" "${DEVICE_MAP_BS}"
[ -n "${DEVICE_MAP_CS}" ] && [ -n "${RECORD_COMMAND_CS}" ] && scan_band 'CS' "${CHANNELS_CS}" "${RECORD_COMMAND_CS}" "${DEVICE_MAP_CS}"

# generate mirakc channels configuration
if [ -n "${all_lists}" ]; then
  echo 'channels:' > "${OUTPUT_FILE}"
  echo "${all_lists}" | awk -F "\t" -v "EXTRACT_SID=${EXTRACT_SID}" '
  {
    printf("  - name: '\''%s'\''\n", $3);
    printf("    type: '\''%s'\''\n", $1);
    printf("    channel: '\''%s'\''\n", $2);
    printf("    extra-args: '\'''\''\n");
    if (EXTRACT_SID == "1") { printf("    services: [%s]\n", $4); }
    printf("    disabled: false\n\n");
  }' >> "${OUTPUT_FILE}"
fi

echo "channel scan finished, output to ${OUTPUT_FILE}" >&2