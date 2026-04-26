#!/usr/bin/env bash
# Wiki-ingest benchmark harness.
#
# Subcommands:
#   setup         Clone $SOURCE_VAULT (default ~/vault) to /tmp/vault-bench,
#                 disable hook auto-spawn, save pristine tarball
#   reset         Restore /tmp/vault-bench from pristine tarball
#   touch <n>     Modify the first N raw/handovers files (hash change)
#   run <s> <n>   Run scenario s1|s2|s3|s4, N iterations, append CSV
#   all <n>       Run all four scenarios, N iterations each
#   show <csv>    Print median, min, max from a results CSV
#
# Env:
#   SOURCE_VAULT  defaults to $HOME/vault
#   CLAUDE_BIN    defaults to `claude`
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_VAULT="/tmp/vault-bench"
PRISTINE="/tmp/vault-bench-pristine.tar.gz"
SOURCE_VAULT="${SOURCE_VAULT:-$HOME/vault}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
RESULTS_DIR="$REPO_DIR/bench/results"

stat_size() {
  if stat -f '%z' "$1" 2>/dev/null; then
    return
  fi
  stat -c '%s' "$1" 2>/dev/null || echo 0
}

touch_files() {
  local n="$1"
  local ts
  ts="$(date +%s%N)"
  local count=0
  while IFS= read -r -d '' f; do
    printf '\n<!-- bench:%s -->\n' "$ts" >> "$f"
    count=$((count + 1))
    [ "$count" -ge "$n" ] && break
  done < <(find "$BENCH_VAULT/raw/handovers" -type f -name '*.md' -print0 | sort -zR)
  if [ "$count" -lt "$n" ]; then
    echo "[bench] WARNING: only $count handover files available, requested $n" >&2
  fi
}

run_once() {
  local scenario="$1"
  local out_csv="$2"
  local iter="$3"

  "$0" reset

  case "$scenario" in
    s1) ;;
    s2) touch_files 1 ;;
    s3) touch_files 3 ;;
    s4) touch_files 10 ;;
    *) echo "unknown scenario: $scenario" >&2; return 1 ;;
  esac

  local log_before
  log_before="$(stat_size "$BENCH_VAULT/.ingest.log")"

  local start end wall exit_code log_after log_delta
  start="$(date +%s.%N)"
  set +e
  local plugin_dir_flag=""
  if [ "${BENCH_USE_REPO_PLUGIN:-0}" = "1" ]; then
    plugin_dir_flag="--plugin-dir $REPO_DIR/plugins/exomemory2"
  fi

  printf '%s\n' '{"type":"user","message":{"role":"user","content":"/exomemory2:wiki-ingest"}}' | \
    EXOMEMORY_VAULT="$BENCH_VAULT" "$CLAUDE_BIN" -p \
      --input-format stream-json \
      --output-format stream-json \
      --verbose \
      --permission-mode bypassPermissions \
      $plugin_dir_flag \
      >>"$BENCH_VAULT/.ingest.log" 2>&1
  exit_code=$?
  set -e
  end="$(date +%s.%N)"

  wall="$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e - s }')"
  log_after="$(stat_size "$BENCH_VAULT/.ingest.log")"
  log_delta="$((log_after - log_before))"

  printf '%s,%s,%s,%s,%s\n' "$scenario" "$iter" "$wall" "$log_delta" "$exit_code" >> "$out_csv"
  printf '  [%s iter %d] wall=%ss exit=%d log_delta=%db\n' "$scenario" "$iter" "$wall" "$exit_code" "$log_delta" >&2
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  setup)
    if [ ! -d "$SOURCE_VAULT" ]; then
      echo "source vault not found: $SOURCE_VAULT" >&2
      exit 1
    fi
    rm -rf "$BENCH_VAULT"
    rsync -a \
      --exclude='.ingest.lock' \
      --exclude='.ingest.log' \
      --exclude='.last-ingest' \
      --exclude='.clip-queue' \
      "$SOURCE_VAULT/" "$BENCH_VAULT/"
    cat > "$BENCH_VAULT/.exomemory-config" <<'EOF'
# bench config: disable hook auto-spawn so capture.sh only writes the
# session handover (which gets wiped by `reset`) without recursively
# launching another /wiki-ingest.
AUTO_INGEST=0
AUTO_CLIP=0
AUTO_INGEST_THRESHOLD=99999
AUTO_INGEST_INTERVAL_SEC=99999
EOF
    rm -f "$PRISTINE"
    tar -czf "$PRISTINE" -C /tmp vault-bench
    pristine_size="$(stat_size "$PRISTINE")"
    echo "[bench] vault: $BENCH_VAULT"
    echo "[bench] pristine tarball: $PRISTINE ($pristine_size bytes)"
    ;;

  reset)
    if [ ! -f "$PRISTINE" ]; then
      echo "pristine tarball missing; run 'setup' first" >&2
      exit 1
    fi
    rm -rf "$BENCH_VAULT"
    tar -xzf "$PRISTINE" -C /tmp
    ;;

  touch)
    n="${1:?usage: touch <n>}"
    touch_files "$n"
    ;;

  run)
    scenario="${1:?usage: run <scenario> <iterations> [csv]}"
    iterations="${2:-5}"
    label="${3:-}"
    mkdir -p "$RESULTS_DIR"
    if [ -n "$label" ]; then
      out_csv="$RESULTS_DIR/${label}-${scenario}.csv"
    else
      out_csv="$RESULTS_DIR/${scenario}-$(date +%Y%m%dT%H%M%S).csv"
    fi
    if [ ! -f "$out_csv" ]; then
      echo "scenario,iter,wall_s,log_delta_bytes,exit_code" > "$out_csv"
    fi
    for i in $(seq 1 "$iterations"); do
      run_once "$scenario" "$out_csv" "$i"
    done
    echo "[bench] results: $out_csv"
    "$0" show "$out_csv"
    ;;

  all)
    iterations="${1:-5}"
    label="${2:-baseline-$(date +%Y%m%dT%H%M%S)}"
    mkdir -p "$RESULTS_DIR"
    out_csv="$RESULTS_DIR/${label}.csv"
    echo "scenario,iter,wall_s,log_delta_bytes,exit_code" > "$out_csv"
    for s in s1 s2 s3 s4; do
      for i in $(seq 1 "$iterations"); do
        run_once "$s" "$out_csv" "$i"
      done
    done
    echo "[bench] all results: $out_csv"
    "$0" show "$out_csv"
    ;;

  show)
    csv="${1:?usage: show <csv>}"
    awk -F, '
      NR == 1 { next }
      {
        if (walls[$1] == "") walls[$1] = $3; else walls[$1] = walls[$1] " " $3
        if (logs[$1]  == "") logs[$1]  = $4; else logs[$1]  = logs[$1]  " " $4
        cnt[$1]++
      }
      END {
        printf "%-4s  %-5s  %-12s  %-12s  %-12s  %-14s\n", "scen", "n", "min_s", "median_s", "max_s", "median_log_b"
        for (s in cnt) {
          c = split(walls[s], w, " ")
          if (c == 0) continue
          for (i = 1; i <= c - 1; i++) for (j = i + 1; j <= c; j++) if (w[i] + 0 > w[j] + 0) { t = w[i]; w[i] = w[j]; w[j] = t }
          mn = w[1] + 0
          mx = w[c] + 0
          if (c % 2) med = w[(c + 1) / 2] + 0; else med = (w[c/2] + w[c/2 + 1]) / 2

          d = split(logs[s], lg, " ")
          for (i = 1; i <= d - 1; i++) for (j = i + 1; j <= d; j++) if (lg[i] + 0 > lg[j] + 0) { t = lg[i]; lg[i] = lg[j]; lg[j] = t }
          if (d % 2) med_log = lg[(d + 1) / 2] + 0; else med_log = (lg[d/2] + lg[d/2 + 1]) / 2

          printf "%-4s  %-5d  %-12.3f  %-12.3f  %-12.3f  %-14.0f\n", s, cnt[s], mn, med, mx, med_log
        }
      }
    ' "$csv"
    ;;

  help|*)
    sed -n '1,20p' "$0"
    ;;
esac
