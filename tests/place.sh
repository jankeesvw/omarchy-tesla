#!/usr/bin/env bash
# Formatter and cmd_place tests. No network. No personal coordinates.
set -euo pipefail

root=$(cd "$(dirname -- "$0")/.." && pwd)
jq_prog="$root/bin/place.jq"
tesla="$root/bin/tesla"
fail=0

pass() { printf 'ok  %s\n' "$1"; }
bad()  { printf 'not ok  %s\n' "$1"; fail=1; }

[ -f "$jq_prog" ] || { echo "missing $jq_prog"; exit 1; }

# --- place.jq fixtures -------------------------------------------------------

for inp in "$root"/tests/fixtures/a*.in.json "$root"/tests/fixtures/iso_bare.in.json; do
  [ -f "$inp" ] || continue
  base=$(basename "$inp" .in.json)
  exp="$root/tests/fixtures/$base.out.json"
  got=$(jq -c -f "$jq_prog" "$inp")
  want=$(jq -c . "$exp")
  if [ "$got" = "$want" ]; then
    pass "format $base"
  else
    bad "format $base"
    printf '  got  %s\n  want %s\n' "$got" "$want"
  fi
  case "$got" in
    *leak-display*|*leak-postcode*|*leak-county*|*leak-country*)
      bad "format $base leaked extra keys"
      ;;
  esac
  lines=$(printf '%s\n' "$got" | wc -l)
  [ "$lines" -eq 1 ] || bad "format $base not one line ($lines)"
done

# --- PLACE_CACHE_USABLE from bin/tesla, never source tesla -------------------

expr=$(grep -m1 '^PLACE_CACHE_USABLE=' "$tesla") || {
  bad "PLACE_CACHE_USABLE assignment missing in bin/tesla"
  expr='PLACE_CACHE_USABLE="false"'
}
eval "$expr"

usable() { printf '%s' "$1" | jq -e "$PLACE_CACHE_USABLE" >/dev/null 2>&1; }

old='{"ok":true,"street":"Main Street","number":"12","town":"Springfield","place":"Main Street 12, Springfield"}'
if usable "$old"; then bad "A13 old cache must miss"; else pass "A13 old cache miss"; fi

hit=$(jq -c . "$root/tests/fixtures/a1.out.json")
if usable "$hit"; then pass "A13b usable cache"; else bad "A13b usable cache"; fi

if usable '{"ok":false,"number_first":true}'; then bad "A13c ok false"; else pass "A13c ok false"; fi
if usable '{"number_first":true}'; then bad "A13c ok missing"; else pass "A13c ok missing"; fi

# --- cmd_place, isolated dirs, stub curl -------------------------------------

if [ ! -x "$tesla" ]; then
  echo "skip cmd_place: bin/tesla not executable"
  [ "$fail" -eq 0 ]
  exit "$fail"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export OMARCHY_TESLA_CACHE_DIR="$work/cache"
export OMARCHY_TESLA_CONFIG_DIR="$work/config"
mkdir -p "$work/bin" "$OMARCHY_TESLA_CACHE_DIR/places" "$OMARCHY_TESLA_CONFIG_DIR"

# Record curl invocations; behaviour comes from CURL_MODE.
: > "$work/curl.log"
cat > "$work/bin/curl" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
case "${CURL_MODE:-fail}" in
  fail) exit 1 ;;
  a1) cat "${A1_IN:?}" ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$work/bin/curl"
export CURL_LOG="$work/curl.log"
export A1_IN="$root/tests/fixtures/a1.in.json"
export PATH="$work/bin:$PATH"

run_place() { "$tesla" place 38.8977 -77.0365; }

# tesla rounds with %.4f
key=$(awk -v a=38.8977 -v b=-77.0365 'BEGIN { printf "%.4f_%.4f", a, b }')
seed="$OMARCHY_TESLA_CACHE_DIR/places/$key.json"
printf '%s\n' "$hit" > "$seed"
: > "$CURL_LOG"
export CURL_MODE=fail
out=$(run_place)
if [ "$out" = "$hit" ] && [ ! -s "$CURL_LOG" ]; then
  pass "cmd_place A13b stdout is seeded JSON, no curl"
else
  bad "cmd_place A13b"
  printf '  out=%s\n  curl_log=%s\n' "$out" "$(cat "$CURL_LOG")"
fi
lines=$(printf '%s\n' "$out" | wc -l)
[ "$lines" -eq 1 ] || bad "cmd_place A13b not one line"

# A13: unusable old file, stub curl fails, must not return the old object
printf '%s\n' "$old" > "$seed"
: > "$CURL_LOG"
export CURL_MODE=fail
out=$(run_place) || true
if printf '%s' "$out" | jq -e '.ok == false' >/dev/null 2>&1 \
   && ! printf '%s' "$out" | grep -q 'Main Street' \
   && [ "$(cat "$seed")" = "$old" ]; then
  pass "cmd_place A13 unusable cache not returned"
else
  bad "cmd_place A13 unusable cache"
  printf '  out=%s\n  seed=%s\n' "$out" "$(cat "$seed")"
fi

# Cache miss, success: curl returns A1 fixture
rm -f "$seed"
: > "$CURL_LOG"
export CURL_MODE=a1
out=$(run_place)
want=$(jq -c . "$root/tests/fixtures/a1.out.json")
if [ "$out" = "$want" ] && [ -f "$seed" ] && [ "$(cat "$seed")" = "$want" ]; then
  pass "cmd_place miss writes and prints A1 contract"
else
  bad "cmd_place miss-success"
  printf '  out=%s\n  file=%s\n  want=%s\n' "$out" "$(cat "$seed" 2>/dev/null || echo missing)" "$want"
fi

# Missing place.jq
copy="$work/lonely"
mkdir -p "$copy"
cp "$tesla" "$copy/tesla"
chmod +x "$copy/tesla"
: > "$CURL_LOG"
export CURL_MODE=a1
rm -f "$seed"
out=$("$copy/tesla" place 38.8977 -77.0365) || true
if printf '%s' "$out" | jq -e '.ok == false' >/dev/null 2>&1 \
   && [ ! -f "$seed" ] \
   && [ ! -s "$CURL_LOG" ]; then
  pass "cmd_place missing place.jq fails without cache write"
else
  bad "cmd_place missing place.jq"
  printf '  out=%s\n  curl_log=%s\n' "$out" "$(cat "$CURL_LOG")"
fi

[ "$fail" -eq 0 ]
