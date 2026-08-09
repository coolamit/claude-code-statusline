#!/bin/bash
# Claude Code statusline
# Two independent signals:
#   CTX bar = how full THIS model's window is  (safe <40% | warn 40-60% | crit >60%)
#   badge   = token milestone, scaled to the window: min(200k, window/2)
#             -> 200k window: fires at 100k | 1M window: fires at 200k

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

input=$(cat)

# <<< instead of `echo "$input" |` : a herestring avoids forking a subshell
# for each pipeline, which adds up on a script that runs on every render.
cwd=$(jq -r '.cwd' <<< "$input")
cwd="${cwd/#$HOME/~}"
model_id=$(jq -r '.model.display_name // empty' <<< "$input")
effort=$(jq -r '.effort.level // empty' <<< "$input")
ctx_pct=$(jq -r '.context_window.used_percentage // empty' <<< "$input")
ctx_cur=$(jq -r '.context_window.total_input_tokens // empty' <<< "$input")
ctx_size=$(jq -r '.context_window.context_window_size // 200000' <<< "$input")
transcript=$(jq -r '.transcript_path // empty' <<< "$input")
cost_usd=$(jq -r '.cost.total_cost_usd // empty' <<< "$input")
dur_ms=$(jq -r '.cost.total_duration_ms // empty' <<< "$input")

# 8-char hash of a string, used to key the /tmp caches.
# NOTE: do NOT write this as `printf | md5sum | cut || fallback` -- the pipeline's
# exit status is cut's, and cut succeeds even when md5sum is missing, so the ||
# never fires and the hash comes back EMPTY (every path then shares one cache
# file). Keeping md5sum last in its pipeline makes its failure the one that counts.
hash8() {
  local s=$1 h=""
  h=$(printf '%s' "$s" | md5sum 2>/dev/null) || h=$(md5 -q -s "$s" 2>/dev/null) || h=""
  h=${h%% *}                       # md5sum appends "  -"
  [ -n "$h" ] && printf '%.8s' "$h" || printf 'stable'
}

# Current context fill in tokens.
# Prefer total_input_tokens: it IS the current window fill (input +
# cache_creation + cache_read) -- the same input-only sum used_percentage is
# computed from -- so it needs no window size. Fall back to pct x size.
# current_usage/used_percentage are null on a fresh session and right after
# /compact, so both paths must tolerate empty. Never add total_output_tokens.
ctx_tokens=$(awk -v c="$ctx_cur" -v p="$ctx_pct" -v s="$ctx_size" \
  'BEGIN{ if (c+0 > 0) printf "%.0f", c+0; else if (p+0 > 0) printf "%.0f", (p/100)*s; else printf "0" }')

# Badge threshold scaled to the window: min(200k, window/2).
#   200k window -> 100k   |   1M window -> 200k
badge_at=$(awk -v s="$ctx_size" 'BEGIN{ h=s/2; b=200000; printf "%.0f", (h<b?h:b) }')
badge_txt=$(awk -v t="$badge_at" 'BEGIN{ if (t>=1000000) printf "%gM", t/1000000; else printf "%gk", t/1000 }')

# Colors (per element)
RST='\033[0m'
C_DIM='\033[38;2;120;120;120m'
C_WARN='\033[38;2;255;0;121m'
C_CRIT='\033[38;2;239;68;68m'
C_PATH='\033[38;2;149;191;71m'
C_CTX_BAR='\033[38;2;227;252;2m'
C_TOKENS='\033[38;2;227;252;2m'
C_COST='\033[38;2;0;252;237m'
C_DURATION='\033[38;2;120;120;120m'
C_OVER200K='\033[38;2;255;107;0m'
C_UNDER200K='\033[38;2;0;230;118m'
C_GIT_BRANCH='\033[38;2;149;191;71m'
C_MODEL_ID='\033[38;2;120;120;120m'

# Color the CTX bar by how full THIS model's window is (capacity pressure).
pick_color() {
  local p=$1 safe=$2
  if [ "$p" -gt 60 ] 2>/dev/null; then printf '%b' "$C_CRIT"
  elif [ "$p" -ge 40 ] 2>/dev/null; then printf '%b' "$C_WARN"
  else printf '%b' "$safe"
  fi
}

make_bar_block() {
  local p=$1 w=$2 cc=$3
  local f=$((p * w / 100))
  [ "$f" -gt "$w" ] && f=$w
  local i=0
  while [ $i -lt $f ]; do printf '%b' "${cc}█"; i=$((i+1)); done
  while [ $i -lt "$w" ]; do printf '%b' "${C_DIM}░"; i=$((i+1)); done
}

fmt_tok() {
  local t=$1
  if [ "$t" -ge 1000000 ] 2>/dev/null; then awk "BEGIN{printf \"%.1fM\", $t/1000000}"
  elif [ "$t" -ge 1000 ] 2>/dev/null; then awk "BEGIN{printf \"%.1fk\", $t/1000}"
  else printf '%d' "$t"
  fi
}

fmt_dur() {
  # Each dependent assignment on its OWN local line: on a single `local` line
  # bash expands every $(( )) against the *pre-existing* value, so `s` read an
  # unset `ms` and came out 0 -- that's what pinned the timer at 0s.
  local ms=$1
  local s=$((ms/1000))
  local h=$((s/3600)) m=$(((s%3600)/60)) ss=$((s%60))
  if   [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm%02ds' "$m" "$ss"
  else printf '%ds' "$ss"
  fi
}

fmt_cost() {
  # Fixed 2 dp: 0.5424315 -> 0.54, 1 -> 1.00
  printf '%.2f' "$1"
}

# Git (cached 5s)
_gc="/tmp/sl-git-$(hash8 "$PWD")"
_ga=999
[ -f "$_gc" ] && _ga=$(( $(date +%s) - $(stat -f%m "$_gc" 2>/dev/null || stat -c%Y "$_gc" 2>/dev/null || echo 0) ))
if [ "$_ga" -gt 5 ]; then
  _gb=$(git branch --show-current 2>/dev/null)
  _gs=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
  _gm=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
  printf '%s\n' "${_gb}|${_gs}|${_gm}" > "$_gc"
else
  # `IFS=... read` is a prefix assignment to a *regular* builtin, so it does not
  # persist -- no save/restore needed.
  IFS='|' read -r _gb _gs _gm < "$_gc"
fi

# Cumulative session token usage, summed from the transcript JSONL.
# The payload only reports CURRENT context (not session totals), so we tally
# every assistant turn's usage from transcript_path. Cached on the file's mtime
# so the full scan runs once per turn, not on every redraw.
sess_in=0; sess_out=0; sess_cache=0
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  _tc="/tmp/sl-tok-$(hash8 "$transcript")"
  _sig=$(stat -f%m "$transcript" 2>/dev/null || stat -c%Y "$transcript" 2>/dev/null || echo 0)
  _csig=""
  [ -f "$_tc" ] && IFS='|' read -r _csig sess_in sess_out sess_cache < "$_tc"
  if [ "$_csig" != "$_sig" ]; then
    # jq emits per-turn counts (small -> always clean integers); awk does the big
    # summing and prints clean integers. This sidesteps jq's scientific-notation
    # rendering of large sums and bash's integer-only arithmetic, both of which
    # blank out the value. sess_in here is TOTAL input (fresh + cache).
    read -r sess_in sess_out sess_cache < <(
      jq -r 'select(type=="object") | .message.usage // empty
             | "\(.input_tokens // 0) \(.output_tokens // 0) \(.cache_read_input_tokens // 0) \(.cache_creation_input_tokens // 0)"' "$transcript" 2>/dev/null \
      | awk '{i+=$1; o+=$2; c+=$3+$4} END{printf "%.0f %.0f %.0f", i+c, o, c}')
    printf '%s|%s|%s|%s\n' "$_sig" "${sess_in:-0}" "${sess_out:-0}" "${sess_cache:-0}" > "$_tc"
  fi
  : "${sess_in:=0}"; : "${sess_out:=0}"; : "${sess_cache:=0}"
fi

SEP=' | '
VS15=$'\xef\xb8\x8e'   # U+FE0E: force text presentation

# Output
printf '%b' "${C_PATH}${cwd}${RST}"
printf '%b' "$SEP"
[ -n "$_gb" ] && printf '%b' "${C_GIT_BRANCH}⎇ ${_gb}${RST}"
printf '%b' "$SEP"
if [ -n "$model_id" ]; then
  # Append effort in brackets only when the model reports it: "Fable 5 (xhigh)".
  # Models without an effort level (e.g. Haiku) show the bare name.
  [ -n "$effort" ] && model_id="$model_id ($effort)"
  printf '%b' "${C_MODEL_ID}${model_id}${RST}"
fi
echo
if [ -n "$ctx_pct" ]; then
  ci=$(printf '%.0f' "$ctx_pct")
  cc=$(pick_color "$ci" "${C_CTX_BAR}")
  printf '%b' "${cc}CTX "
  make_bar_block "$ci" 10 "$cc"
  printf '%b%%' " ${cc}${ci}"; printf '%b' "${RST}"
else
  printf '%b' "${C_DIM}CTX ░░░░░░░░░░ -"; printf '%%'; printf '%b' "${RST}"
fi
printf '%b' "$SEP"
[ -n "$transcript" ] && printf '%b' "${C_TOKENS}↑$(fmt_tok "$sess_in") ↓$(fmt_tok "$sess_out")${RST}"
printf '%b' "$SEP"
[ -n "$cost_usd" ] && printf '%b' "${C_COST}\$$(fmt_cost "$cost_usd")${RST}"
printf '%b' "$SEP"
[ -n "$dur_ms" ] && printf '%b' "${C_DURATION}$(fmt_dur "$dur_ms")${RST}"
printf '%b' "$SEP"
# Badge -- threshold scales with the window (see badge_at above), so the label
# and the trigger always agree: <100k / >100k on 200k, <200k / >200k on 1M.
if [ "$ctx_tokens" -ge "$badge_at" ] 2>/dev/null; then
  printf '%b' "${C_OVER200K}⚠${VS15} >${badge_txt}${RST}"
else
  printf '%b' "${C_UNDER200K}✔${VS15} <${badge_txt}${RST}"
fi

echo
