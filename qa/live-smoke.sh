#!/usr/bin/env bash
# Deterministic, LLM-free live smoke test for Ribbon. Drives RibbonDummy windows through Ribbon's
# command FIFO, compares every plan with AX ground truth (tolerance 4pt), then runs check_plans.py.
# Needs an unlocked session with Accessibility granted to this terminal. Run: make smoke
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/qa/tools"
QA_BIN="${TMPDIR:-/tmp}/ribbon-qa-tools"
RIBBON_BIN="${RIBBON_BIN:-$ROOT/build/Ribbon.app/Contents/MacOS/Ribbon}"
DUMMY_BIN="${DUMMY_BIN:-$ROOT/$(make -s -C "$ROOT" print-DUMMY)}"   # the edition this checkout builds
OMNI_APP="$HOME/Applications/OmniWM Dev.app"
TOL=4
RES=()
FAILS=0
DUMMY_PID=""
RIBBON_PID=""
OMNI_QUIT=0

cleanup() {
  local rc=$?
  [ -n "$RIBBON_PID" ] && kill "$RIBBON_PID" 2>/dev/null
  [ -n "$DUMMY_PID" ] && kill "$DUMMY_PID" 2>/dev/null
  if [ "$OMNI_QUIT" = 1 ]; then echo "relaunching OmniWM Dev"; open "$OMNI_APP"; fi
  exit "$rc"
}
trap cleanup EXIT

record() { RES+=("$1|$2|$3"); [ "$1" = PASS ] || FAILS=$((FAILS + 1)); }
summary() {
  echo
  printf '%-5s  %-42s  %s\n' RESULT CHECK DETAIL
  local r st name det
  for r in "${RES[@]}"; do
    IFS='|' read -r st name det <<<"$r"
    printf '%-5s  %-42s  %s\n' "$st" "$name" "$det"
  done
  if [ "$FAILS" -eq 0 ]; then echo "ALL PASS (${#RES[@]} checks)"; else echo "$FAILS FAILED of ${#RES[@]} checks"; fi
}
abort() { record FAIL "$1" "$2"; summary; exit 1; }

# Compile QA helpers on first run (and when their source changes).
mkdir -p "$QA_BIN"
for t in lockcheck axframes axclose axresize axdisplay; do
  if [ ! -x "$QA_BIN/$t" ] || [ "$TOOLS/$t.swift" -nt "$QA_BIN/$t" ]; then
    swiftc -O "$TOOLS/$t.swift" -o "$QA_BIN/$t" || { echo "swiftc failed for $t" >&2; exit 1; }
  fi
done

case "$("$QA_BIN/lockcheck")" in
  1|true) echo "screen locked; unlock and rerun" >&2; exit 2 ;;
esac
[ -x "$RIBBON_BIN" ] || { echo "missing $RIBBON_BIN (run make bundle)" >&2; exit 1; }
[ -x "$DUMMY_BIN" ] || { echo "missing $DUMMY_BIN (run make bundle)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ribbon-smoke.XXXXXX")"
FIFO="$WORK/cmd.fifo"
PLANLOG="$WORK/plans.jsonl"
echo "work dir: $WORK"
DISPLAY_RECT="$("$QA_BIN/axdisplay")"
echo "primary visibleFrame (AX): $DISPLAY_RECT"

frames() { "$QA_BIN/axframes" "$1"; }
plan_count() { wc -l < "$PLANLOG" | tr -d ' '; }
last_plan() { tail -n 1 "$PLANLOG"; }
plan_more() { [ "$(plan_count)" -gt "$1" ]; }
no_omni() { ! pgrep -x OmniWM >/dev/null; }
gone() { ! kill -0 "$1" 2>/dev/null; }
windows_ready() { [ "$(frames "$DUMMY_PID" | grep -o '"id"' | wc -l)" -ge 5 ]; }
wait_for() { # wait_for <seconds> <command...>
  local end=$(( $(date +%s) + $1 )); shift
  until "$@"; do [ "$(date +%s)" -ge "$end" ] && return 1; sleep 0.2; done
}
snap() { frames "$DUMMY_PID" > "$WORK/ax.json"; last_plan > "$WORK/plan.json"; }
check_frames() { # check_frames <label>: last plan vs AX ground truth
  snap
  local out
  if out=$(py cmp "$WORK/plan.json" "$WORK/ax.json" "$TOL"); then record PASS "$1" "$out"; else record FAIL "$1" "$out"; fi
}

read -r -d '' PY <<'PYEOF'
import json, sys

def load(path):
    with open(path) as f:
        return json.load(f)

def fmt(d):
    return "%d,%d %dx%d" % (d["x"], d["y"], d["w"], d["h"])

cmd, args = sys.argv[1], sys.argv[2:]
if cmd == "cmp":  # cmp PLAN AX TOL
    plan, ax, tol = load(args[0]), load(args[1]), float(args[2])
    byid = {w["id"]: w for w in ax}
    bad = []
    for f in plan.get("frames", []):
        w = byid.get(f["id"])
        if w is None:
            bad.append("id %s missing in AX" % f["id"])
        elif any(abs(f[k] - w[k]) > tol for k in "xywh"):
            bad.append("%s: plan %s AX %s" % (w["title"], fmt(f), fmt(w)))
    if not plan.get("frames"):
        bad.append("plan has no frames")
    print("; ".join(bad) if bad else "%d frames match" % len(plan["frames"]))
    sys.exit(1 if bad else 0)
elif cmd == "swipe":  # swipe STATS: one JSON line per qa_swipe; thresholds apply in snapshot mode
    rows = [json.loads(l) for l in open(args[0]) if l.startswith("{")]
    bad, notes = [], []
    if len(rows) < 2:
        bad.append("expected 2 swipe stat lines, got %d" % len(rows))
    for d in rows:
        L, i, nom = d["link"], d["link"]["interval_ms"], d["nominal_ms"]
        notes.append("%s p95 %.1fms (nominal %.1f) drops %d latency %.2f frames" % (d["mode"], i["p95"], nom, L["dropped_after_first"], d.get("latency_frames") or 0))
        if d["mode"] != "snapshot":
            continue
        if i["p95"] > 1.25 * nom: bad.append("p95 interval %.1f > 1.25x%.1f" % (i["p95"], nom))
        if L["dropped_after_first"] > 0: bad.append("%d dropped frames at %s" % (L["dropped_after_first"], L.get("hitch_at_frame")))
        if (d.get("latency_frames") or 0) > 1.0: bad.append("latency %.2f frames" % d["latency_frames"])
        if d["real_windows"]["moves_while_fingers_down"] > 0: bad.append("real windows moved during the gesture")
        if (d["commit"].get("final_error_px") or 0) > 1: bad.append("AX vs plan error %.1fpx" % d["commit"]["final_error_px"])
    print("; ".join(bad) if bad else " | ".join(notes))
    sys.exit(1 if bad else 0)
elif cmd == "focus":  # focus PLAN
    f = load(args[0]).get("focus")
    print("null" if f is None else f)
elif cmd == "lastfocus":  # lastfocus PLANLOG: plan.focus is null when focus did not change, so take the latest non-null
    f = [json.loads(l).get("focus") for l in open(args[0]) if l.strip()]
    f = [x for x in f if x is not None]
    print(f[-1] if f else "null")
elif cmd == "neighbors":  # neighbors PLAN ID: ids that may take focus after ID closes
    cols = load(args[0])["map"]["columns"]
    fid = int(args[1])
    ci = next(i for i, c in enumerate(cols) if any(w["id"] == fid for w in c["windows"]))
    sib = [w["id"] for w in cols[ci]["windows"] if w["id"] != fid]
    if not sib:
        nb = ci - 1 if ci > 0 else ci + 1
        sib = [w["id"] for w in cols[nb]["windows"]] if 0 <= nb < len(cols) else []
    print(" ".join(str(i) for i in sib) or "none")
elif cmd == "tabinfo":  # tabinfo PLAN: "<bars> <active ids> <tabbed columns> <parked windows>"
    pl = load(args[0])
    bars = pl.get("tab_bars", [])
    print("%d %s %d %d" % (len(bars), ",".join(str(b["active"]) for b in bars),
                          sum(1 for c in pl["map"]["columns"] if c.get("tabbed")), sum(1 for f in pl["frames"] if not f["on_screen"])))
elif cmd == "fwidth":  # fwidth PLAN ID
    print([f["w"] for f in load(args[0])["frames"] if f["id"] == int(args[1])][0])
elif cmd == "title":  # title AX ID
    t = [w["title"] for w in load(args[0]) if w["id"] == int(args[1])]
    if not t:
        sys.exit(1)
    print(t[0])
elif cmd == "width":  # width PLAN ID EXPECT TOL
    f = [f for f in load(args[0])["frames"] if f["id"] == int(args[1])]
    if not f:
        print("missing")
        sys.exit(1)
    ok = abs(f[0]["w"] - int(args[2])) <= float(args[3])
    print("width %d" % f[0]["w"])
    sys.exit(0 if ok else 1)
elif cmd == "onscreen":  # onscreen AX X,Y,W,H: every window must intersect the display
    ax = load(args[0])
    dx, dy, dw, dh = [int(v) for v in args[1].split(",")]
    bad = [w["title"] for w in ax
           if not (w["x"] < dx + dw and w["x"] + w["w"] > dx and w["y"] < dy + dh and w["y"] + w["h"] > dy)]
    print("%d of %d windows on primary display" % (len(ax) - len(bad), len(ax)) + ("; off: " + ", ".join(bad) if bad else ""))
    sys.exit(1 if bad or not ax else 0)
elif cmd == "samewidth":  # samewidth AX MINW TOL: every window equal width (within TOL), at least MINW, no horizontal overlap with a neighbour column
    ax = load(args[0]); minw, tol = float(args[1]), float(args[2])
    ws = [w["w"] for w in ax]
    bad = []
    if len(ax) < 2: bad.append("expected 2+ windows")
    if ws and max(ws) - min(ws) > tol: bad.append("widths differ: %s" % ws)
    if ws and min(ws) < minw - tol: bad.append("narrower than the floor: %s" % ws)
    print("; ".join(bad) if bad else "widths %s" % ws)
    sys.exit(1 if bad else 0)
elif cmd == "nooverlap":  # nooverlap PLAN: on-screen windows in the last plan never overlap each other
    fs = [f for f in load(args[0]).get("frames", []) if f.get("on_screen")]
    bad = ["%s/%s" % (a["id"], b["id"]) for i, a in enumerate(fs) for b in fs[i + 1:]
           if a["x"] < b["x"] + b["w"] and b["x"] < a["x"] + a["w"] and a["y"] < b["y"] + b["h"] and b["y"] < a["y"] + a["h"]]
    print(("overlap: " + ", ".join(bad)) if bad else "%d on-screen windows, none overlap" % len(fs))
    sys.exit(1 if bad or not fs else 0)
PYEOF
py() { python3 -I -c "$PY" "$@"; }

# Quit OmniWM before the dummies open, so it cannot tile them onto another display; the trap relaunches it on exit.
if ! no_omni; then
  echo "quitting OmniWM Dev for the test"
  OMNI_QUIT=1
  osascript -e 'tell application "OmniWM Dev" to quit' >/dev/null 2>&1
  wait_for 10 no_omni || { pkill -TERM -x OmniWM; wait_for 5 no_omni; }
fi

# Dummy windows (pid is the process's own pid, so $! is the AX owner).
mkfifo "$FIFO"
: > "$PLANLOG"
"$DUMMY_BIN" --count 5 --title-prefix Smoke > "$WORK/dummy.out" 2>&1 &
DUMMY_PID=$!
wait_for 10 windows_ready || abort "dummy windows" "RibbonDummy did not show 5 windows"

SWIPE_STATS="$WORK/swipe-stats.txt"
QAOUT="$WORK/qa.jsonl"
RIBBON_QA_OUT="$QAOUT" RIBBON_SWIPE_STATS="$SWIPE_STATS" RIBBON_ONLY_PIDS="$DUMMY_PID" RIBBON_CMD_FIFO="$FIFO" RIBBON_PLAN_LOG="$PLANLOG" \
  "$RIBBON_BIN" > "$WORK/ribbon.log" 2>&1 &
RIBBON_PID=$!
wait_for 10 plan_more 0 || abort "first plan" "no plan logged within 10s"
plan_quiet() { local c; c=$(plan_count); sleep 1; [ "$(plan_count)" = "$c" ]; }   # windows arrive one by one; the silent gather lands at ~0.6s
wait_for 15 plan_quiet || abort "initial layout" "plan log never went quiet"
check_frames "initial layout"

# Command matrix: send, wait 0.5s, compare the last plan with AX.
n=0
for cmd in focus_right focus_right focus_left move_left cycle_width cycle_width toggle_full toggle_full \
           stack unstack stack cycle_height cycle_height unstack undo redo "focus_index 1" "switch_desktop 2" "switch_desktop 1" toggle_float toggle_float; do
  n=$((n + 1))
  printf '%s\n' "$cmd" > "$FIFO"
  sleep "${SMOKE_WAIT:-0.5}"
  check_frames "$n $cmd"
done

# Tabbed columns: stack two windows, tab them, cycle, untab. Frames must match AX at every step.
printf '%s\n' "focus_index 1" > "$FIFO"; sleep 0.4
printf '%s\n' "focus_right" > "$FIFO"; sleep 0.4
printf '%s\n' "stack" > "$FIFO"; sleep 0.5
printf '%s\n' "toggle_tabs" > "$FIFO"; sleep 0.8
check_frames "tabs: toggle_tabs frames match AX"
snap; INFO="$(py tabinfo "$WORK/plan.json")"
case "$INFO" in "1 "*" 1 "*) record PASS "tabs: one bar, one tabbed column" "$INFO" ;; *) record FAIL "tabs: one bar, one tabbed column" "$INFO" ;; esac
A1="${INFO#1 }"; A1="${A1%% *}"
printf '%s\n' "next_tab" > "$FIFO"; sleep 0.8
check_frames "tabs: next_tab frames match AX"
snap; INFO2="$(py tabinfo "$WORK/plan.json")"; A2="${INFO2#1 }"; A2="${A2%% *}"
[ -n "$A2" ] && [ "$A1" != "$A2" ] && record PASS "tabs: next_tab shows another window" "$A1 -> $A2" || record FAIL "tabs: next_tab shows another window" "$A1 -> $A2"
printf '%s\n' "toggle_tabs" > "$FIFO"; sleep 0.8
check_frames "tabs: untabbed frames match AX"
snap; INFO3="$(py tabinfo "$WORK/plan.json")"
case "$INFO3" in "0 "*" 0 "*) record PASS "tabs: back to a plain stack" "$INFO3" ;; *) record FAIL "tabs: back to a plain stack" "$INFO3" ;; esac
printf '%s\n' "unstack" > "$FIFO"; sleep 0.5

# One-step tab group: toggle_tabs (⌃⌥T) on a lone window tabs it with its neighbour; undo is one step.
printf '%s\n' "focus_index 2" > "$FIFO"; sleep 0.5
printf '%s\n' "unstack" > "$FIFO"; sleep 0.4
snap; cols_before="$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["map"]["columns"]))' "$WORK/plan.json")"
printf '%s\n' "toggle_tabs" > "$FIFO"; sleep 0.8
check_frames "tab group: ⌃⌥T on a lone window, frames match AX"
snap; INFO4="$(py tabinfo "$WORK/plan.json")"
TOAST4="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("toast"))' "$WORK/plan.json")"
COLS4="$(python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1]))["map"]["columns"]; print(len(c), max(len(x["windows"]) for x in c))' "$WORK/plan.json")"
case "$INFO4" in "1 "*" 1 "*) [ "$COLS4" = "$((cols_before - 1)) 2" ] && record PASS "tab group: lone window + neighbour = one 2-tab column" "$INFO4; columns $cols_before -> ${COLS4% *}; $TOAST4" || record FAIL "tab group: lone window + neighbour = one 2-tab column" "$INFO4; $COLS4; $TOAST4" ;; *) record FAIL "tab group: lone window + neighbour = one 2-tab column" "$INFO4; $COLS4; $TOAST4" ;; esac
case "$TOAST4" in "Tab group: "*) record PASS "tab group: toast names the apps" "$TOAST4" ;; *) record FAIL "tab group: toast names the apps" "$TOAST4" ;; esac
printf '%s\n' "undo" > "$FIFO"; sleep 0.8
snap; INFO5="$(py tabinfo "$WORK/plan.json")"
COLS5="$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["map"]["columns"]))' "$WORK/plan.json")"
case "$INFO5" in "0 "*) [ "$COLS5" = "$cols_before" ] && record PASS "tab group: one undo step" "columns back to $COLS5" || record FAIL "tab group: one undo step" "columns $COLS5 want $cols_before" ;; *) record FAIL "tab group: one undo step" "$INFO5" ;; esac

# Tab menu picks (what the right-click menu sends), without a pointer: "Move to its own column" and "Close tab group".
ncols() { python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["map"]["columns"]))' "$WORK/plan.json"; }
for pick in popOut closeGroup; do
  printf '%s\n' "toggle_tabs" > "$FIFO"; sleep 0.8
  snap; I="$(py tabinfo "$WORK/plan.json")"; A="${I#1 }"; A="${A%% *}"
  printf '%s\n' "qa_tab $pick $A" > "$FIFO"; sleep 0.8
  check_frames "tab menu: $pick frames match AX"
  snap; I2="$(py tabinfo "$WORK/plan.json")"; C2="$(ncols)"
  case "$I2" in "0 "*) [ "$C2" = "$cols_before" ] && record PASS "tab menu: $pick ends the group" "tab $A; columns back to $C2" || record FAIL "tab menu: $pick ends the group" "columns $C2 want $cols_before" ;; *) record FAIL "tab menu: $pick ends the group" "$I -> $I2" ;; esac
done

# Width presets: six steps (25 33 50 66 75 100) that wrap, each matching AX.
FW="$(py lastfocus "$PLANLOG")"; WS=""
for i in 1 2 3 4 5 6; do
  printf '%s\n' "cycle_width" > "$FIFO"; sleep 0.6
  snap; WS="$WS $(py fwidth "$WORK/plan.json" "$FW")"
done
check_frames "presets: frames match AX after cycling"
if [ "$(echo $WS | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')" -ge 5 ] && [ "$(echo $WS | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')" -le 6 ]; then
  record PASS "presets: six-step width cycle" "widths:$WS"; else record FAIL "presets: six-step width cycle" "widths:$WS"; fi

# Direct width hotkeys (width_step N = the Nth step of the width list, what ⌃⌥⌘N sends): each lands on its preset width, matches AX,
# and undo returns to the width before. Expected px = frac * (avail + gap) - gap, with avail = display width - 2 * 12 outer gap.
DW="$(echo "$DISPLAY_RECT" | cut -d, -f3)"
expw() { awk -v dw="$DW" -v f="$1" 'BEGIN { printf "%d", f * (dw - 24 + 12) - 12 + 0.5 }'; }
FW="$(py lastfocus "$PLANLOG")"
for step in "1 0.25" "4 0.667" "6 1.0" "3 0.5"; do
  set -- $step
  printf 'width_step %s\n' "$1" > "$FIFO"; sleep 0.6
  snap
  W="$(py width "$WORK/plan.json" "$FW" "$(expw "$2")" 3)" && record PASS "width key $1 -> $2" "$W" || record FAIL "width key $1 -> $2" "$W (want $(expw "$2"))"
  check_frames "width key $1: frames match AX"
done
snap; before_w="$(py fwidth "$WORK/plan.json" "$FW")"
printf 'width_step 2\n' > "$FIFO"; sleep 0.6
printf 'undo\n' > "$FIFO"; sleep 0.6
snap; after_w="$(py fwidth "$WORK/plan.json" "$FW")"
[ "$before_w" = "$after_w" ] && record PASS "width key is one undo step" "$before_w" || record FAIL "width key is one undo step" "$before_w -> $after_w"
n_before=$(plan_count); printf 'width_step 9\n' > "$FIFO"; sleep 0.6
[ "$(plan_count)" = "$n_before" ] && record PASS "width key past the list is ignored" "no plan" || record FAIL "width key past the list is ignored" "plan changed"

# Focus mode: toggle_focus flips the session flag (qa_state), never touches the layout, and leaves again.
qa_flag() { : > "$QAOUT"; printf 'qa_state\n' > "$FIFO"; sleep 0.4; tail -n 1 "$QAOUT"; }
printf 'toggle_focus\n' > "$FIFO"; sleep 0.8
ON="$(qa_flag)"
case "$ON" in *'"focusMode":true'*) record PASS "focus mode on" "$(echo "$ON" | grep -o '"overlay":"[a-z]*"')" ;; *) record FAIL "focus mode on" "$ON" ;; esac
# While on, the blur must survive everyday moves (once seen: blur gone after a move, flag still on).
LOST=""
for mv in focus_right focus_left "qa_swipe 500 300" stack unstack move_left move_right toggle_full toggle_full focus_right; do
  printf '%s\n' "$mv" > "$FIFO"; case "$mv" in qa_swipe*) sleep 2.5 ;; *) sleep 0.8 ;; esac
  S="$(qa_flag)"
  case "$S" in *'"focusMode":true'*'"overlay":"off"'*|*'"overlay":"off"'*'"focusMode":true'*) LOST="$LOST $mv" ;; *'"dim":true'*) ;; *) LOST="$LOST $mv(dim)" ;; esac
done
[ -z "$LOST" ] && record PASS "focus mode: blur survives 10 moves" "overlay stayed on" || record FAIL "focus mode: blur survives 10 moves" "lost after:$LOST"
printf 'toggle_focus\n' > "$FIFO"; sleep 0.8
OFF="$(qa_flag)"
case "$OFF" in *'"focusMode":false'*) record PASS "focus mode off" "$(echo "$OFF" | grep -o '"overlay":"[a-z]*"')" ;; *) record FAIL "focus mode off" "$OFF" ;; esac
check_frames "focus mode leaves the layout alone"   # (qa_state queries log plans, so compare frames rather than counting plans)

# Close the focused window: focus must move to the left neighbour (right if leftmost), per the previous plan.
snap
cp "$WORK/plan.json" "$WORK/prev.json"
FOCUS="$(py lastfocus "$PLANLOG")"
[ "$FOCUS" != "null" ] || abort "close focused" "no focused window before close"
NEIGH="$(py neighbors "$WORK/prev.json" "$FOCUS")"
TITLE="$(py title "$WORK/ax.json" "$FOCUS")" || abort "close focused" "no AX title for id $FOCUS"
before=$(plan_count)
"$QA_BIN/axclose" "$DUMMY_PID" "$TITLE" > /dev/null || abort "close focused" "axclose failed for '$TITLE'"
if wait_for 3 plan_more "$before"; then
  sleep 0.5
  snap
  NEWF="$(py lastfocus "$PLANLOG")"
  case " $NEIGH " in
    *" $NEWF "*) record PASS "close '$TITLE' -> neighbour focus" "focus $NEWF (allowed: $NEIGH)" ;;
    *) record FAIL "close '$TITLE' -> neighbour focus" "focus $NEWF (allowed: $NEIGH)" ;;
  esac
  check_frames "close layout"
else
  record FAIL "close '$TITLE' -> neighbour focus" "no plan within 3s of close"
fi

# User resize: a width set through AX must be adopted by the plan, then the plan log must go idle.
snap
TARGET="$(py lastfocus "$PLANLOG")"
TTITLE="$(py title "$WORK/ax.json" "$TARGET")" || abort "user resize" "no focused window to resize"
before=$(plan_count)
"$QA_BIN/axresize" "$DUMMY_PID" "$TTITLE" 900 || abort "user resize" "axresize failed for '$TTITLE'"
if wait_for 3 plan_more "$before"; then
  sleep 0.5
  snap
  W="$(py width "$WORK/plan.json" "$TARGET" 900 "$TOL")" && record PASS "user resize adopted" "$W (target 900)" \
    || record FAIL "user resize adopted" "$W (target 900)"
else
  record FAIL "user resize adopted" "no plan within 3s of resize"
fi
c1=$(plan_count); sleep 3; c2=$(plan_count)
if [ "$c1" = "$c2" ]; then record PASS "idle after resize (3s)" "no new plans"
else record FAIL "idle after resize (3s)" "$((c2 - c1)) plans while idle"; fi

# Swipe smoothness: two synthetic three-finger swipes go through the real trackpad pipeline (qa_swipe); Ribbon writes one JSON line
# per swipe (RIBBON_SWIPE_STATS). Snapshot mode (Screen Recording granted): steady frame pacing, no drops, first movement within a
# frame, real windows untouched while the fingers are down, and the AX frames equal the plan after the commit. Direct mode is reported only.
# A shared or loaded VM can stall the main thread once in a while, so a failing pair is repeated (up to 3 pairs, fresh stats each).
swipe_ok=0
for attempt in 1 2 3; do
  : > "$SWIPE_STATS"
  for sp in "-700 600" "700 600"; do printf 'qa_swipe %s\n' "$sp" > "$FIFO"; sleep 4; done
  if out="$(py swipe "$SWIPE_STATS")"; then swipe_ok=1; break; fi
done
if [ "$swipe_ok" = 1 ]; then record PASS "swipe smoothness (pair $attempt)" "$out"; else record FAIL "swipe smoothness (3 pairs)" "$out"; fi

# Quit through the FIFO: Ribbon restores windows, all dummy windows must stay on the primary display.
printf 'quit\n' > "$FIFO"
if wait_for 5 gone "$RIBBON_PID"; then record PASS "quit exits Ribbon" "pid $RIBBON_PID gone"
else record FAIL "quit exits Ribbon" "pid $RIBBON_PID still running"; fi
RIBBON_PID=""
sleep 0.5
frames "$DUMMY_PID" > "$WORK/ax.json"
out="$(py onscreen "$WORK/ax.json" "$DISPLAY_RECT")" && record PASS "dummies on primary after quit" "$out" \
  || record FAIL "dummies on primary after quit" "$out"

# Stack width floor: a window that cannot get narrower (min width 890) stacked with a normal one makes the whole column that wide.
FLOOR_PIDS=""
FIFO2="$WORK/cmd2.fifo"; PLANLOG2="$WORK/plans2.jsonl"; mkfifo "$FIFO2"; : > "$PLANLOG2"
"$DUMMY_BIN" --count 2 --title-prefix Floor --min-width 890 > "$WORK/dummy2.out" 2>&1 &
DUMMY2_PID=$!
FLOOR_PIDS="$DUMMY2_PID"
wait_for 10 sh -c "[ \"\$('$QA_BIN/axframes' $DUMMY2_PID | grep -o '\"id\"' | wc -l)\" -ge 2 ]" || record FAIL "stack floor: dummies" "RibbonDummy did not show 2 windows"
RIBBON_ONLY_PIDS="$DUMMY2_PID" RIBBON_CMD_FIFO="$FIFO2" RIBBON_PLAN_LOG="$PLANLOG2" "$RIBBON_BIN" > "$WORK/ribbon2.log" 2>&1 &
RIBBON_PID=$!
sleep 3
printf '%s\n' "focus_index 2" > "$FIFO2"; sleep 0.5
printf '%s\n' "stack" > "$FIFO2"
sleep 3   # reconcile runs ~0.45s after the plan settles; allow a few rounds
"$QA_BIN/axframes" "$DUMMY2_PID" > "$WORK/ax2.json"; tail -n 1 "$PLANLOG2" > "$WORK/plan2.json"
if out=$(py samewidth "$WORK/ax2.json" 886 "$TOL"); then record PASS "stack floor: stacked min-width window, same width" "$out"; else record FAIL "stack floor: stacked min-width window, same width" "$out"; fi
if out=$(py cmp "$WORK/plan2.json" "$WORK/ax2.json" "$TOL"); then record PASS "stack floor: plan matches AX" "$out"; else record FAIL "stack floor: plan matches AX" "$out"; fi
c1=$(wc -l < "$PLANLOG2"); sleep 2; c2=$(wc -l < "$PLANLOG2")
[ "$c1" = "$c2" ] && record PASS "stack floor: settles (no write loop)" "no new plans" || record FAIL "stack floor: settles (no write loop)" "$((c2 - c1)) plans while idle"
printf 'quit\n' > "$FIFO2"; wait_for 5 gone "$RIBBON_PID"; RIBBON_PID=""
kill "$DUMMY2_PID" 2>/dev/null

# Stack height floor: two windows that each refuse to be shorter than ~60% of the display cannot share a column.
# Ribbon must learn the floors, give up on stacking (tabs instead) and settle, not resize back and forth.
FIFO3="$WORK/cmd3.fifo"; PLANLOG3="$WORK/plans3.jsonl"; mkfifo "$FIFO3"; : > "$PLANLOG3"
MINH=$(echo "$DISPLAY_RECT" | awk -F, '{ printf "%d", $4 * 0.62 }')
"$DUMMY_BIN" --count 2 --title-prefix Tall --min-height "$MINH" > "$WORK/dummy3.out" 2>&1 &
DUMMY3_PID=$!
FLOOR_PIDS="$FLOOR_PIDS $DUMMY3_PID"
wait_for 10 sh -c "[ \"\$('$QA_BIN/axframes' $DUMMY3_PID | grep -o '\"id\"' | wc -l)\" -ge 2 ]" || record FAIL "height floor: dummies" "RibbonDummy did not show 2 windows"
RIBBON_ONLY_PIDS="$DUMMY3_PID" RIBBON_CMD_FIFO="$FIFO3" RIBBON_PLAN_LOG="$PLANLOG3" "$RIBBON_BIN" > "$WORK/ribbon3.log" 2>&1 &
RIBBON_PID=$!
sleep 3
printf '%s\n' "focus_index 2" > "$FIFO3"; sleep 0.5
c0=$(wc -l < "$PLANLOG3")
printf '%s\n' "stack" > "$FIFO3"
sleep 5   # two refusals, then the switch to tabs
c1=$(wc -l < "$PLANLOG3"); sleep 3; c2=$(wc -l < "$PLANLOG3")
[ "$c1" = "$c2" ] && [ $((c1 - c0)) -lt 15 ] && record PASS "height floor: settles (no resize loop)" "$((c1 - c0)) plans to settle, none while idle" \
  || record FAIL "height floor: settles (no resize loop)" "$((c1 - c0)) plans to settle, $((c2 - c1)) while idle"
tail -n 1 "$PLANLOG3" > "$WORK/plan3.json"
if out=$(py nooverlap "$WORK/plan3.json"); then record PASS "height floor: windows never overlap" "$out"; else record FAIL "height floor: windows never overlap" "$out"; fi
printf 'quit\n' > "$FIFO3"; wait_for 5 gone "$RIBBON_PID"; RIBBON_PID=""
kill "$DUMMY3_PID" 2>/dev/null

# Smooth-swipe offer: without Screen Recording (faked), the first swipe offers smooth swiping once, and never again.
RB_DOMAIN=com.makeautomation.ribbon
OLD_OFFER="$(defaults read "$RB_DOMAIN" smoothSwipeOffered 2>/dev/null)"
defaults delete "$RB_DOMAIN" smoothSwipeOffered >/dev/null 2>&1
"$DUMMY_BIN" --count 3 --title-prefix Card > "$WORK/dummy4.out" 2>&1 &
DUMMY4_PID=$!
FLOOR_PIDS="$FLOOR_PIDS $DUMMY4_PID"
wait_for 10 sh -c "[ \"\$('$QA_BIN/axframes' $DUMMY4_PID | grep -o '\"id\"' | wc -l)\" -ge 3 ]" || record FAIL "smooth offer: dummies" "RibbonDummy did not show 3 windows"
card_run() {   # card_run LABEL: one Ribbon session, one swipe, prints the smoothCard flag
  local fifo="$WORK/cmd4-$1.fifo" qa="$WORK/qa4-$1.jsonl"; mkfifo "$fifo"; : > "$qa"
  RIBBON_QA_NO_SCREEN=1 RIBBON_QA_OUT="$qa" RIBBON_ONLY_PIDS="$DUMMY4_PID" RIBBON_CMD_FIFO="$fifo" "$RIBBON_BIN" > "$WORK/ribbon4-$1.log" 2>&1 &
  RIBBON_PID=$!; sleep 3
  printf 'qa_swipe 400 300\n' > "$fifo"; sleep 2
  printf 'qa_state\n' > "$fifo"; sleep 0.5
  python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["chain2"]["smoothCard"])' "$qa" 2>&1
  printf 'quit\n' > "$fifo"; wait_for 5 gone "$RIBBON_PID"; RIBBON_PID=""
}
first="$(card_run 1)"; second="$(card_run 2)"
[ "$first" = "True" ] && record PASS "smooth offer: shown after the first direct swipe" "card $first" || record FAIL "smooth offer: shown after the first direct swipe" "card $first"
[ "$second" = "False" ] && record PASS "smooth offer: never shown twice" "card $second" || record FAIL "smooth offer: never shown twice" "card $second"
if [ -n "$OLD_OFFER" ]; then defaults write "$RB_DOMAIN" smoothSwipeOffered -bool "$OLD_OFFER"; else defaults delete "$RB_DOMAIN" smoothSwipeOffered >/dev/null 2>&1; fi
kill "$DUMMY4_PID" 2>/dev/null

# Plan invariants (display = primary visibleFrame).
if out="$(python3 "$ROOT/qa/check_plans.py" --display "$DISPLAY_RECT" "$PLANLOG" 2>&1)"; then
  record PASS "check_plans.py" "$(echo "$out" | tail -n 1)"
else
  record FAIL "check_plans.py" "$(echo "$out" | tail -n 3 | tr '\n' ' ')"
fi

summary
echo "logs: $WORK"
[ "$FAILS" -eq 0 ]
