#!/usr/bin/env bash
# shellcheck disable=SC2034
# Offline tests for bingedl helper functions. Usage: tests/selftest.sh
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=bingedl
. ./bingedl

PASS=0; FAIL=0
eq() { # name expected actual
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

set_defaults
HOME=/home/test

# --- resolve_url
eq "resolve relative"   "https://h.example/a/b/v1.m3u8"  "$(resolve_url 'https://h.example/a/b/master.m3u8?x=1' 'v1.m3u8')"
eq "resolve absolute"   "https://h.example/v1.m3u8"      "$(resolve_url 'https://h.example/a/b/master.m3u8' '/v1.m3u8')"
eq "resolve full"       "https://o.example/z.m3u8"       "$(resolve_url 'https://h.example/a/master.m3u8' 'https://o.example/z.m3u8')"
eq "resolve dotdot"     "https://h.example/a/audio/u.m3u8" "$(resolve_url 'https://h.example/a/b/master.m3u8' '../audio/u.m3u8')"
eq "resolve parens"     "https://h.example/t@k/Stream(03)/i.m3u8" "$(resolve_url 'https://h.example/t@k/master.m3u8' 'Stream(03)/i.m3u8')"

# --- attr
L='#EXT-X-STREAM-INF:BANDWIDTH=5000000,AVERAGE-BANDWIDTH=4000000,CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=1920x1080,AUDIO="aud"'
eq "attr bandwidth"  "5000000"  "$(attr "$L" BANDWIDTH)"
eq "attr avg"        "4000000"  "$(attr "$L" AVERAGE-BANDWIDTH)"
eq "attr quoted"     'avc1.64001f,mp4a.40.2' "$(attr "$L" CODECS)"
eq "attr audio"      "aud"      "$(attr "$L" AUDIO)"

# --- variants
MASTER='#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Ukrainian",LANGUAGE="uk",DEFAULT=YES,URI="a_uk.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=NO,URI="a_en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="other",NAME="Nope",LANGUAGE="de",DEFAULT=NO,URI="a_de.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360,AUDIO="aud"
v360.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,AUDIO="aud"
v1080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,AUDIO="aud"
v720.m3u8'
V=$(parse_variants "$MASTER")
eq "variants count"  "3" "$(printf '%s\n' "$V" | wc -l | tr -d ' ')"
eq "pick best"       "v1080.m3u8" "$(printf '%s\n' "$V" | pick_variant 0 | cut -f4)"
eq "pick max 720"    "v720.m3u8"  "$(printf '%s\n' "$V" | pick_variant 720 | cut -f4)"
eq "pick max 900"    "v720.m3u8"  "$(printf '%s\n' "$V" | pick_variant 900 | cut -f4)"
eq "pick below all"  "v360.m3u8"  "$(printf '%s\n' "$V" | pick_variant 200 | cut -f4)"

A=$(parse_audio "$MASTER" aud 'https://h.example/x/master.m3u8')
eq "audio count"     "2" "$(printf '%s\n' "$A" | wc -l | tr -d ' ')"
eq "audio first"     "Ukrainian|uk|YES|https://h.example/x/a_uk.m3u8" "$(printf '%s\n' "$A" | head -1 | tr '\t' '|')"

# --- audio choice
AN=(Ukrainian English); AL=(uk en); AD=(YES NO); AU=(u1 u2)
AUDIO=auto;   choose_audio; eq "audio auto"   " 0"    "$SEL"
AUDIO=all;    choose_audio; eq "audio all"    " 0 1"  "$SEL"
AUDIO=en;     choose_audio; eq "audio lang"   " 1"    "$SEL"
AUDIO="uk,English"; choose_audio; eq "audio mix" " 0 1" "$SEL"
AUDIO=xx;     choose_audio 2>/dev/null; eq "audio fallback" " 0" "$SEL"
AUDIO_MEMO="English"; AUDIO=ask; choose_audio; eq "audio memo" " 1" "$SEL"

# --- iso3
eq "iso3 uk"   ukr "$(iso3 uk)"
eq "iso3 en-US" eng "$(iso3 en-US)"
eq "iso3 3let" fra "$(iso3 FRA)"
eq "iso3 empty" und "$(iso3 '')"

# --- drm / duration
eq "drm fairplay" yes "$(is_drm '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://abc"' && echo yes || echo no)"
eq "drm widevine" yes "$(is_drm '#EXT-X-KEY:KEYFORMAT="urn:uuid:edef8ba9"' && echo yes || echo no)"
eq "drm aes128 ok" no "$(is_drm '#EXT-X-KEY:METHOD=AES-128,URI="https://k/key"' && echo yes || echo no)"
eq "duration" "12.50" "$(playlist_duration $'#EXTM3U\n#EXTINF:10.000,\na.ts\n#EXTINF:2.5,\nb.ts')"
eq "duration_ok close" ok "$(duration_ok 1498 1500 && echo ok || echo bad)"
eq "duration_ok short" bad "$(duration_ok 600 1500 && echo ok || echo bad)"

# --- names & paths
eq "fs_name"   "Breaking_Bad" "$(SPACES=underscore fs_name ' Breaking  Bad ')"
eq "fs_name colon" "Mr_Robot_Pilot" "$(SPACES=underscore fs_name 'Mr Robot: Pilot')"
eq "fs_name keep" "Breaking Bad" "$(SPACES=keep fs_name 'Breaking Bad')"
MODE=series; TITLE="Breaking Bad"; SERIES_DIR=/s; LAYOUT=folders; SPACES=underscore; OUTPUT_OVERRIDE=""
eq "path series folders" "/s/Breaking Bad/Season 02/Breaking_Bad_S02Ep08.mp4" "$(out_path 2 08)"
LAYOUT=flat
eq "path series flat"    "/s/Breaking_Bad_S02Ep08.mp4" "$(out_path 2 8)"
MODE=movie; MOVIES_DIR=/m; LAYOUT=folders; TITLE="Cat"
eq "path movie"          "/m/Cat/Cat.mp4" "$(out_path 1 1)"
OUTPUT_OVERRIDE=/o; LAYOUT=flat
eq "path override"       "/o/Cat.mp4" "$(out_path 1 1)"
OUTPUT_OVERRIDE=""
MOVIES_DIR=/m/; LAYOUT=folders
eq "path trailing slash" "/m/Cat/Cat.mp4" "$(out_path 1 1)"
OUTPUT_OVERRIDE=/o//; LAYOUT=flat
eq "path override slashes" "/o/Cat.mp4" "$(out_path 1 1)"
OUTPUT_OVERRIDE=""

# --- queue / list file
T=$(mktemp -d); QUEUE="$T/q"; : >"$QUEUE"
printf '# c\nhttps://a/1   # first\n\nhttps://a/2\n@season 3  # next\nhttps://a/3\n@start 7\nhttps://a/4\r\nbad line\n' >"$T/l.txt"
Q_SEASON=2; Q_EP=5
read_listfile "$T/l.txt" 2>/dev/null
eq "queue" "2|5|https://a/1;2|6|https://a/2;3|1|https://a/3;3|7|https://a/4" "$(tr '\t' '|' <"$QUEUE" | paste -sd';' -)"
rm -rf "$T"

# --- settings validation
eq "set ok"      ok  "$(set_setting MAX_HEIGHT 1080 && echo ok || echo bad)"
eq "set bad"     bad "$(set_setting MAX_HEIGHT 10x80 2>/dev/null && echo ok || echo bad)"
eq "set jobs 0"  bad "$(set_setting JOBS 0 2>/dev/null && echo ok || echo bad)"
eq "set notify"  bad "$(set_setting NOTIFY_FILE maybe 2>/dev/null && echo ok || echo bad)"

# --- menu header (no screen clear when stdout is not a terminal)
VERSION=9.9.9; STATUS="saved."
eq "header text"   "bingedl v9.9.9|saved." "$(header | paste -sd'|' -)"
eq "header status once" "bingedl v9.9.9" "$(STATUS=""; header)"
eq "header no escape" "0" "$(STATUS=""; header | grep -c "$(printf '\033')")"

# --- remembered series, retry file
T=$(mktemp -d); CONFIG_DIR="$T/c"; STATE_FILE="$T/c/state"; FAILED_FILE="$T/c/last-failed.txt"
save_state 'My "Show"' 2 7; load_state
eq "state title"  "My Show" "$LAST_TITLE"
eq "state season" "2" "$LAST_SEASON"
eq "state ep"     "7" "$LAST_EP"
WORK="$T/w"; mkdir -p "$WORK"; QUEUE="$T/q"; MODE=series; TITLE=Foo
printf '1\t1\tu1\n1\t2\tu2\n' >"$QUEUE"
printf 'ok\t1\ta\t-\n' >"$WORK/results"; remember_series; load_state
eq "remember next" "Foo|1|3" "$LAST_TITLE|$LAST_SEASON|$LAST_EP"
printf 'fail\t1\ta\tx\n' >"$WORK/results"; save_state Bar 1 1; remember_series; load_state
eq "remember none" "Bar|1|1" "$LAST_TITLE|$LAST_SEASON|$LAST_EP"
printf '2\t5\tuB\n1\t3\tuA\n' >"$WORK/failed"; write_retry >/dev/null
eq "retry series" "# bingedl: links that failed in the last run|@season 1|@start 3|uA|@season 2|@start 5|uB" "$(paste -sd'|' - <"$FAILED_FILE")"
MODE=movie; printf '1\t1\tuM\n' >"$WORK/failed"; write_retry >/dev/null
eq "retry movie"  "# bingedl: links that failed in the last run|uM" "$(paste -sd'|' - <"$FAILED_FILE")"
: >"$WORK/failed"; write_retry
eq "retry removed" "no" "$([ -e "$FAILED_FILE" ] && echo yes || echo no)"
rm -rf "$T"

# --- main menu status panel
MOVIES_DIR=/home/test/M; SERIES_DIR=/other/S; MAX_HEIGHT=720; AUDIO=uk; FFV=9.9
eq "panel movies"  "1" "$(status_panel | grep -c 'Movies .* ~/M$')"
eq "panel series"  "1" "$(status_panel | grep -c 'Series .* /other/S$')"
eq "panel quality" "1" "$(status_panel | grep -c 'Quality .* 720, audio: uk$')"
eq "panel ffmpeg"  "1" "$(status_panel | grep -c 'ffmpeg .* 9.9$')"
FFV=missing
eq "panel missing" "1" "$(status_panel | grep -c 'not found')"

# --- about
AUTHOR="A B"; REPO_URL="https://x.example/r"; LINKEDIN_URL=""
eq "about repo"       "1" "$(about | grep -c 'https://x.example/r/issues')"
eq "about no linkedin" "0" "$(about | grep -c LinkedIn)"
eq "about share"      "1" "$(about | grep -c 'named and numbered: bingedl https://x.example/r')"
LINKEDIN_URL="https://www.linkedin.com/in/x"
eq "about linkedin"   "1" "$(about | grep -c 'linkedin.com/in/x')"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
