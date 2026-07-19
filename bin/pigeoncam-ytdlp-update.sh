#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-ytdlp-update.sh - keeps the standalone yt-dlp binary current.
#
# yt-dlp is deliberately not installed via apt or system-wide pip (README
# quickstart step 1): distro packages lag YouTube's frontend changes and
# can silently misparse the page, and a pip install carries the same
# staleness risk once installed, since nothing would ever re-run it.
# Installed instead as the standalone release binary at /usr/local/bin/
# yt-dlp, which supports safe in-place self-update via `-U` - exactly the
# operation this script runs, as root, on the daily timer in
# systemd/pigeoncam-ytdlp-update.timer (root is what owns
# /usr/local/bin/yt-dlp in the first place, so no new privilege is needed
# beyond what every other unit in this project already runs as).

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/pigeoncam-common.sh
source "$SCRIPT_DIR/../lib/pigeoncam-common.sh"

PIGEONCAM_LOG_TAG="pigeoncam-ytdlp-update"

main() {
    require_cmd yt-dlp

    local before after output
    before=$(yt-dlp --version 2>/dev/null || echo "unknown")

    if ! output=$(yt-dlp -U 2>&1); then
        log_error "yt-dlp self-update failed: $output (see docs/TROUBLESHOOTING.md 'Keeping yt-dlp current')"
        exit 1
    fi

    after=$(yt-dlp --version 2>/dev/null || echo "unknown")
    if [[ "$before" != "$after" ]]; then
        log_info "yt-dlp updated: $before -> $after"
    else
        log_info "yt-dlp already up to date ($after)"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
