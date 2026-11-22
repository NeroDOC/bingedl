#!/usr/bin/env bash
# End-to-end test: generate a local HLS stream (2 qualities, 2 audio tracks),
# serve it over HTTP and download it with bingedl. Needs ffmpeg, ffprobe, python3, curl.
# Usage: tests/e2e.sh
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD

for c in ffmpeg ffprobe python3 curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "e2e: $c not found" >&2; exit 2; }
done

T=$(mktemp -d "${TMPDIR:-/tmp}/bingedl-e2e.XXXXXX") || exit 1
SRV=""
trap '[ -n "$SRV" ] && { kill "$SRV"; wait "$SRV"; } 2>/dev/null; rm -rf "$T"' EXIT

PASS=0; FAIL=0
eq() { # name expected actual
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

# --- HLS fixture
H="$T/www"; mkdir -p "$H/v180" "$H/v360" "$H/a_uk" "$H/a_en"
mkvideo() { # size dir
  ffmpeg -nostdin -loglevel error -f lavfi -i "testsrc=size=$1:rate=25:duration=6" \
    -c:v libx264 -pix_fmt yuv420p -g 50 -an \
    -f hls -hls_time 2 -hls_playlist_type vod -hls_segment_filename "$H/$2/s%d.ts" "$H/$2/index.m3u8"
}
mkaudio() { # freq dir
  ffmpeg -nostdin -loglevel error -f lavfi -i "sine=frequency=$1:duration=6" -c:a aac -vn \
    -f hls -hls_time 2 -hls_playlist_type vod -hls_segment_filename "$H/$2/s%d.ts" "$H/$2/index.m3u8"
}
if ! { mkvideo 320x180 v180 && mkvideo 640x360 v360 && mkaudio 440 a_uk && mkaudio 880 a_en; }; then
  echo "e2e: cannot generate HLS fixture" >&2; exit 1
fi
cat >"$H/master.m3u8" <<'EOF'
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Ukrainian",LANGUAGE="uk",DEFAULT=YES,URI="a_uk/index.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=NO,URI="a_en/index.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=320x180,AUDIO="aud"
v180/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="aud"
v360/index.m3u8
EOF
printf '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x"\n#EXTINF:2,\nv180/s0.ts\n#EXT-X-ENDLIST\n' >"$H/drm.m3u8"

# --- server on a free port
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$H" >"$T/srv.log" 2>&1 &
SRV=$!
PORT=""
for _ in $(seq 50); do
  PORT=$(sed -n 's/.* port \([0-9][0-9]*\) .*/\1/p' "$T/srv.log")
  [ -n "$PORT" ] && break
  sleep 0.1
done
[ -n "$PORT" ] || { echo "e2e: http server did not start" >&2; cat "$T/srv.log" >&2; exit 1; }
URL="http://127.0.0.1:$PORT"

# --- isolated config: no notifications, no user settings
export XDG_CONFIG_HOME="$T/cfg" NO_COLOR=1
mkdir -p "$XDG_CONFIG_HOME/bingedl"
printf 'NOTIFY_FILE="off"\nNOTIFY_SEASON="off"\nNOTIFY_DONE="off"\nRETRIES="0"\n' >"$XDG_CONFIG_HOME/bingedl/config"
OUT="$T/out"

run() { LOG=$("$ROOT/bingedl" --no-progress -o "$OUT" "$@" </dev/null 2>&1); RC=$?; }
height() { ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$1"; }
langs()  { ffprobe -v error -select_streams a -show_entries stream_tags=language -of csv=p=0 "$1" | paste -sd, -; }

# 1. series, best quality, all audio tracks
run -s -n "My Show" -S 2 -a all "$URL/master.m3u8" "$URL/master.m3u8"
E1="$OUT/My Show/Season 02/My_Show_S02Ep01.mp4"; E2="$OUT/My Show/Season 02/My_Show_S02Ep02.mp4"
eq "series rc" 0 "$RC"
eq "series ep1 exists" yes "$([ -s "$E1" ] && echo yes || echo no)"
eq "series ep2 exists" yes "$([ -s "$E2" ] && echo yes || echo no)"
eq "series height" 360 "$(height "$E1")"
eq "series audio" "ukr,eng" "$(langs "$E1")"
eq "no .part left" "" "$(find "$OUT" -name '*.part')"
[ "$RC" -eq 0 ] || printf '%s\n' "$LOG"

eq "state saved" "My Show|2|3" "$(sed -n 's/^LAST_TITLE="\(.*\)"/\1/p;s/^LAST_SEASON="\(.*\)"/\1/p;s/^LAST_EP="\(.*\)"/\1/p' "$XDG_CONFIG_HOME/bingedl/state" | paste -sd'|' -)"

# 2. rerun: existing files are skipped
run -s -n "My Show" -S 2 -a all "$URL/master.m3u8" "$URL/master.m3u8"
eq "rerun rc" 0 "$RC"
eq "rerun skipped" yes "$(printf '%s' "$LOG" | grep -q '0 downloaded, 2 skipped, 0 failed' && echo yes || echo no)"

# 3. movie, capped quality, one audio language
run -m -n "Cat" -q 200 -a en "$URL/master.m3u8"
M="$OUT/Cat/Cat.mp4"
eq "movie rc" 0 "$RC"
eq "movie height" 180 "$(height "$M")"
eq "movie audio" "eng" "$(langs "$M")"
[ "$RC" -eq 0 ] || printf '%s\n' "$LOG"

# 4. 404 fails with a clear reason and non-zero exit
run -m -n "Missing" "$URL/nope.m3u8"
eq "404 rc" 1 "$RC"
eq "404 retry file" yes "$(grep -q 'nope.m3u8' "$XDG_CONFIG_HOME/bingedl/last-failed.txt" && echo yes || echo no)"
eq "404 reason" yes "$(printf '%s' "$LOG" | grep -q 'HTTP 404' && echo yes || echo no)"

# 4b. parallel downloads (-j 2), and a successful run clears the retry file
run -s -n "Par" -j 2 "$URL/master.m3u8" "$URL/master.m3u8"
eq "parallel rc" 0 "$RC"
eq "parallel files" 2 "$(find "$OUT/Par" -name '*.mp4' | wc -l | tr -d ' ')"
eq "retry file cleared" no "$([ -e "$XDG_CONFIG_HOME/bingedl/last-failed.txt" ] && echo yes || echo no)"

# 5. DRM is detected and reported
run -m -n "Locked" "$URL/drm.m3u8"
eq "drm rc" 1 "$RC"
eq "drm reason" yes "$(printf '%s' "$LOG" | grep -q 'DRM-protected' && echo yes || echo no)"
eq "drm no file" no "$([ -e "$OUT/Locked/Locked.mp4" ] && echo yes || echo no)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
