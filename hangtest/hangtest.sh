#!/bin/bash
# Does the gyp-next make fix hang GNU make 3.81 (macOS) the way Node's 2018
# attempt did (nodejs/node#23255)? Builds Node with the fix, then runs the
# 2018 reproducer and related scenarios; then repeats with the 2018 change as
# a control. A make with no output for STALL seconds is reported as HUNG.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W=${W:-$HOME/hangtest}
SHA=a43bfb5bb27fd0338258aef1adecc0fc355c6b85
N=${JOBS:-$(sysctl -n hw.ncpu)}
STALL=${STALL:-600}
MAKE=/usr/bin/make
LOGS=$W/logs
mkdir -p "$LOGS"
log() { echo "[$(date +%H:%M:%S)] $*"; }
log "$(sw_vers -productVersion) $(sysctl -n machdep.cpu.brand_string) ncpu=$(sysctl -n hw.ncpu); $($MAKE --version | head -1); jobs=$N stall=${STALL}s"

# run NAME J: make -jJ with a no-output watchdog. Prints result line.
run() {
  local name=$1 j=$2 out=$LOGS/$1.log
  local start=$(date +%s)
  ( cd "$W/node" && exec $MAKE -j"$j" ) > "$out" 2>&1 &
  local pid=$! last=0 still=0 status=done
  while kill -0 $pid 2>/dev/null; do
    sleep 15
    local size=$(wc -c < "$out")
    if [ "$size" = "$last" ]; then still=$((still + 15)); else still=0; last=$size; fi
    if [ $still -ge "$STALL" ]; then
      status=HUNG
      pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null; sleep 2; pkill -9 -f "make -C out" 2>/dev/null
      break
    fi
  done
  wait $pid 2>/dev/null; local rc=$?
  local secs=$(( $(date +%s) - start ))
  local cc=$(grep -cE 'CC\(target\)|CXX\(target\)|CC\(host\)|CXX\(host\)' "$out")
  local act=$(grep -c '  ACTION' "$out")
  local ln=$(grep -cE 'LINK\(|SOLINK|LIBTOOL' "$out")
  [ $status = HUNG ] && rc=hung
  log "RESULT $name -j$j: $status rc=$rc ${secs}s compiles=$cc actions=$act links=$ln"
}

# Generated files: one output of each multi-output action.
gen_outputs() {
  ( cd "$W/node/out/Release" && for n in Debugger.h DOMStorage.h ffi.h builtins-generated.cc; do find . -name "$n" -path '*gen*' | head -1; done )
}
scenarios() {  # tag
  local t=$1 j f
  for j in 2 4 $N; do
    run $t-noop-a $j
    rm -f "$W/node/out/Release/node" "$W/node/node"; find "$W/node/out" -name '*.stamp' -name 'rename_*' -delete 2>/dev/null
    run $t-rm-node $j
    for f in $(gen_outputs); do rm -f "$W/node/out/Release/$f"; done
    run $t-rm-generated $j
    for f in $(gen_outputs); do [ -f "$W/node/out/Release/$f" ] || log "MISSING after rebuild: $f"; done
    touch "$W/node/deps/v8/include/js_protocol.pdl" "$W/node/src/inspector/node_protocol.pdl"
    run $t-touch-inputs $j
    run $t-noop-b $j
  done
}

cd "$W"
if [ ! -d node/.git ]; then
  log "fetching node $SHA"
  git init -q node && (cd node && git remote add origin https://github.com/nodejs/node && git fetch -q --depth 1 origin $SHA && git checkout -q FETCH_HEAD) || exit 1
fi
cd node
G=tools/gyp/pylib/gyp/generator/make.py
git checkout -q -- tools/gyp
git show HEAD:$G > "$W/make-orig.py"
git apply "$HERE/node-gyp-fix.patch" || { log "patch failed"; exit 1; }
cp $G "$W/make-fixed.py"
python3 - "$W/make-orig.py" "$W/make-2018.py" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = '"{}: {}{}".format(intermediate, " ".join(inputs), force_append)'
assert s.count(old) == 1, s.count(old)
open(sys.argv[2], "w").write(s.replace(old, '"{}: {}".format(intermediate, " ".join(inputs))'))
PY
log "variants: fixed $(grep -c SECONDARY "$W/make-fixed.py") SECONDARY lines; 2018 $(grep -c 'force_append' "$W/make-2018.py") force_append uses (orig $(grep -c force_append "$W/make-orig.py"))"

if [ ! -x out/Release/node ]; then
  log "configure + full build with the fix"
  ./configure > "$LOGS/configure.log" 2>&1 || { log "configure failed"; tail -20 "$LOGS/configure.log"; exit 1; }
  STALL=3600 run full-build $N
fi
log "=== fixed gyp"
scenarios fixed

log "=== control: the 2018 change (nodejs/node 5d8373a)"
cp "$W/make-2018.py" $G
./configure > "$LOGS/configure-2018.log" 2>&1 || { log "configure failed"; exit 1; }
STALL=3600 run c2018-settle $N
scenarios c2018
cp "$W/make-fixed.py" $G
log "done"
