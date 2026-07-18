# shellcheck shell=bash
# SPDX-License-Identifier: Unlicense
#
# tests/lib/fixtures.sh - shared test config generator.

# write_test_config <config_path> <run_dir> <segment_dir> <key_file>
#                    [min_gap_seconds] [grace_restart] [grace_rotation]
#                    [poll_interval] [max_before_escalation] [backoff_ceiling]
write_test_config() {
    local config_path="$1" run_dir="$2" segment_dir="$3" key_file="$4"
    local min_gap="${5:-150}" grace_restart="${6:-300}" grace_rotation="${7:-480}"
    local poll_interval="${8:-180}" max_before_escalation="${9:-3}" backoff_ceiling="${10:-1800}"
    cat > "$config_path" <<EOF
camera:
  device: /dev/null
  input_format: mjpeg
  resolution: "1920x1080"
  framerate: 30
encode:
  preset: veryfast
  tune: ""
  bitrate_kbps: 6000
  maxrate_kbps: 6000
  bufsize_kbps: 12000
audio:
  mode: synthetic
  synthetic_amplitude: 0.001
  sample_rate: 48000
  real_source: ""
youtube:
  ingest_url: "rtmps://example.invalid/live2"
  stream_key_file: ${key_file}
  rotation:
    mode: restart
    interval: "11h45m"
    min_gap_seconds: ${min_gap}
archive:
  enabled: true
  segment_dir: ${segment_dir}
  segment_length_seconds: 3600
  segment_format: mpegts
  daytime_start: "04:00"
  daytime_end: "20:30"
  daytime_keep_minutes: 60
  nighttime_discard: true
watchdog:
  check_interval_seconds: 30
  stall_timeout_seconds: 60
  progress_file: ${run_dir}/progress
  usb_reset:
    enabled: true
    escalate_after_restarts: 1
    method: uhubctl
    hub_location: "1-1"
    port: "2"
    usb_path: ""
external_check:
  enabled: true
  method: yt-dlp
  channel_live_url: "https://www.youtube.com/@testchannel/live"
  yt_dlp_timeout_seconds: 5
  poll_interval_seconds: ${poll_interval}
  grace_period_after_restart_seconds: ${grace_restart}
  grace_period_after_rotation_seconds: ${grace_rotation}
  max_restarts_before_escalation: ${max_before_escalation}
  backoff_ceiling_seconds: ${backoff_ceiling}
reencode:
  enabled: false
  codec: libx265
  preset: faster
  crf: 26
EOF
}
