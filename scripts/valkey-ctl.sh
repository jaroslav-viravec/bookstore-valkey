#!/usr/bin/env bash
# valkey-ctl.sh — monitor and online-upgrade an operator-managed Valkey, in any
# namespace, with OR without Sentinel (plain master/replica or standalone too).
#
# Subcommands:
#   watch                 Print where the primary is, on a loop (or once).
#   upgrade <version>     Bump spec.version; the operator rolls the StatefulSet one
#                         pod at a time; the primary is monitored throughout so you
#                         see any failover ('*** PRIMARY MOVED ***').
#
# "Where is the primary?" is answered mode-agnostically by querying the data nodes
# with `INFO replication` (not Sentinel), so the same logic works whether Sentinel
# is enabled or not. The CR's spec.sentinel.enabled / spec.tls.enabled are read to
# label the mode and decide whether to use TLS.
#
# Usage:
#   ./scripts/valkey-ctl.sh watch   -n bookstore --name valkey
#   ./scripts/valkey-ctl.sh watch   -n valkey-with-sentinel --name i344017-valkey --once
#   ./scripts/valkey-ctl.sh upgrade 9.1.2 -n bookstore --name valkey
#   ./scripts/valkey-ctl.sh upgrade 9.1.2 -n prod --name cache --context my-ctx --load
#
# Flags (env fallback in parens):
#   -n, --namespace NS   namespace                 (NS, default: bookstore)
#       --name NAME      Valkey CR name            (CR_NAME, default: valkey)
#       --context CTX    kube context              (CONTEXT, default: kind-bookstore)
#       --sts NAME       StatefulSet               (STS, default: auto-discover)
#       --cluster NAME   kind cluster for --load   (CLUSTER, default: bookstore)
#       --secret NAME    password secret           (SECRET, default: valkey-<name>)
#       --cert-dir DIR   in-pod TLS cert dir       (CERT_DIR, default: /opt/bitnami/valkey/certs)
#       --interval SECS  monitor poll interval     (INTERVAL, default: 2)
#       --load           docker pull + kind load the new images first (upgrade)
#       --measure        measure failover timing during upgrade (ms): Sentinel event
#                        timing (sentinel mode) + client write-downtime via a short-lived
#                        in-cluster probe pod. Writes a report file (see --log-dir).
#       --log-dir DIR    where to write the --measure report      (LOG_DIR, default: .)
#                        file: <namespace>.<cr-name>.<timestamp>.log
#       --once           print primary once and exit (watch)
set -euo pipefail

usage() {
  cat <<'EOF'
valkey-ctl.sh — monitor and online-upgrade an operator-managed Valkey CR

SUBCOMMANDS
  watch                   Print which pod is the current primary, on a loop.
  upgrade <VERSION>       Bump spec.version on the CR; the operator rolls pods
                          one at a time while the primary is monitored.

QUICK EXAMPLES
  # Watch primary (default namespace + CR name)
  ./scripts/valkey-ctl.sh watch

  # Watch once and exit
  ./scripts/valkey-ctl.sh watch --once

  # Upgrade with failover measurement, results in ./logs/
  ./scripts/valkey-ctl.sh upgrade 9.1.2 --measure --log-dir logs

  # Full upgrade: custom namespace, preload images, measure, save to ./logs/
  ./scripts/valkey-ctl.sh upgrade 9.1.2 \
      -n bookstore --name valkey \
      --load --measure --log-dir logs

  # 8.1.4 → 9.1.2 with everything (see "MIGRATION" section below)
  ./scripts/valkey-ctl.sh upgrade 9.1.2 \
      -n bookstore --name valkey \
      --load --measure --log-dir logs 2>&1 | tee logs/upgrade-9.1.2.log

FLAGS
  Connection / targeting
    -n, --namespace NS     Kubernetes namespace          (env NS,       default: bookstore)
        --name NAME        Valkey CR name                (env CR_NAME,  default: valkey)
        --context CTX      kubectl context               (env CONTEXT,  default: kind-bookstore)
        --sts NAME         StatefulSet name (skip auto-discover)
                                                         (env STS,      default: auto)

  Image loading (upgrade)
        --cluster NAME     kind cluster for --load       (env CLUSTER,  default: bookstore)
        --load             docker pull + kind load the new images before patching the CR

  Credentials / TLS
        --secret NAME      Secret holding valkey-password
                                                         (env SECRET,   default: valkey-<name>)
        --cert-dir DIR     In-pod TLS cert directory     (env CERT_DIR, default: /opt/bitnami/valkey/certs)

  Monitoring
        --interval SECS    Primary-poll interval (seconds)
                                                         (env INTERVAL, default: 2)
        --once             (watch only) print primary once and exit

  Measurement (upgrade)
        --measure          Measure failover timing with an in-cluster probe pod:
                             • Sentinel events (sentinel mode): failover-triggered → promoted → switch-master
                             • Client write-downtime: ms windows where SET commands failed
                           Writes a structured report file to --log-dir.
        --log-dir DIR      Directory for the --measure report file
                                                         (env LOG_DIR,  default: .)
                           File name: <namespace>.<cr-name>.<timestamp>.log

MIGRATION RECIPE  (8.1.4 → 9.1.2, results in ./logs/)
  mkdir -p logs
  ./scripts/valkey-ctl.sh upgrade 9.1.2 \
      -n bookstore --name valkey \
      --load --measure --log-dir logs \
      2>&1 | tee logs/upgrade-9.1.2.log

  --load   pulls docker.io/bitnami/valkey:9.1.2 and loads it into the kind
           cluster so pods never hit the registry during the roll.
  --measure  starts a probe pod that writes to the primary every loop; records
           every failed-write window in ms and (sentinel mode) all Sentinel
           events with timing. Report is written to logs/ when the roll ends.
  tee      captures both stdout and stderr so the live terminal output (primary
           pod tracking, *** PRIMARY MOVED *** lines) is also in the log.

EOF
}

CMD="${1:-}"; shift || true
case "$CMD" in
  watch|upgrade) ;;
  -h|--help|"") usage; exit 0 ;;
  *) echo "ERROR: unknown subcommand '$CMD' (expected 'watch' or 'upgrade')" >&2
     echo "Run '$0 --help' for usage." >&2; exit 2 ;;
esac

NS="${NS:-bookstore}"
CR_NAME="${CR_NAME:-valkey}"
CONTEXT="${CONTEXT:-kind-bookstore}"
STS="${STS:-}"
CLUSTER="${CLUSTER:-bookstore}"
SECRET="${SECRET:-}"
CERT_DIR="${CERT_DIR:-/opt/bitnami/valkey/certs}"
INTERVAL="${INTERVAL:-2}"
LOG_DIR="${LOG_DIR:-.}"
LOAD=false; ONCE=false; MEASURE=false
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NS="$2"; shift 2 ;;
    --name)         CR_NAME="$2"; shift 2 ;;
    --context)      CONTEXT="$2"; shift 2 ;;
    --sts)          STS="$2"; shift 2 ;;
    --cluster)      CLUSTER="$2"; shift 2 ;;
    --secret)       SECRET="$2"; shift 2 ;;
    --cert-dir)     CERT_DIR="$2"; shift 2 ;;
    --interval)     INTERVAL="$2"; shift 2 ;;
    --log-dir)      LOG_DIR="$2"; shift 2 ;;
    --load)         LOAD=true; shift ;;
    --measure)      MEASURE=true; shift ;;
    --once)         ONCE=true; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "unknown flag: $1" >&2; exit 2 ;;
    *)              POSITIONAL+=("$1"); shift ;;
  esac
done

kc() { kubectl --context "$CONTEXT" -n "$NS" "$@"; }

# ── Read CR facts (version / sentinel / tls) ─────────────────────────────────────
CUR_VER="$(kc get valkey "$CR_NAME" -o jsonpath='{.spec.version}' 2>/dev/null || true)"
if [[ -z "$CUR_VER" ]]; then
  echo "ERROR: Valkey CR '$CR_NAME' not found in ns/$NS (ctx $CONTEXT). Check -n/--name/--context." >&2
  exit 1
fi
SENTINEL_ENABLED="$(kc get valkey "$CR_NAME" -o jsonpath='{.spec.sentinel.enabled}' 2>/dev/null || true)"
TLS_ENABLED="$(kc get valkey "$CR_NAME" -o jsonpath='{.spec.tls.enabled}' 2>/dev/null || true)"
[[ "$SENTINEL_ENABLED" == "true" ]] && MODE="sentinel" || MODE="master/replica"
[[ -z "$SECRET" ]] && SECRET="valkey-${CR_NAME}"
# All of a CR's resources carry this instance label (scopes pods + statefulsets).
SELECTOR="app.kubernetes.io/instance=${CR_NAME}"

# ── Discover the StatefulSet(s) ──────────────────────────────────────────────────
# master/replica mode has two (…-primary, …-replicas); sentinel mode has one (…-node).
if [[ -n "$STS" ]]; then
  STS_LIST="$STS"
else
  STS_LIST="$(kc get sts -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
fi
if [[ -z "$STS_LIST" ]]; then
  echo "ERROR: could not find any StatefulSet for CR '$CR_NAME' in ns/$NS. Pass --sts <name>." >&2
  exit 1
fi

# ── valkey-cli plumbing (password + optional TLS), mode-agnostic ─────────────────
PASS="$(kc get secret "$SECRET" -o jsonpath='{.data.valkey-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
TLS_ARGS=()
if [[ "$TLS_ENABLED" == "true" ]]; then
  TLS_ARGS=(--tls --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/tls.crt" --key "$CERT_DIR/tls.key")
fi

# Run valkey-cli inside a given pod's `valkey` container.
vcli_on() {
  local pod="$1"; shift
  kc exec -i "$pod" -c valkey -- \
    env REDISCLI_AUTH="$PASS" valkey-cli -p 6379 "${TLS_ARGS[@]}" "$@" 2>/dev/null
}

# Resolve an address (raw IP or pod DNS hostname) to a pod name.
resolve_pod() {
  local addr="$1"
  if [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    kc get pods -o jsonpath='{range .items[*]}{.status.podIP}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | awk -v ip="$addr" '$1==ip {print $2; f=1} END{if(!f) print "?"}'
  elif [[ -n "$addr" ]]; then
    printf '%s' "${addr%%.*}"
  else
    printf '?'
  fi
}

# Find the current primary pod via INFO replication (works with/without sentinel).
# Tries each node pod until one responds, then reads role / master_host.
find_primary() {
  local pods p info role mh
  pods="$(kc get pods -l "$SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  for p in $pods; do
    info="$(vcli_on "$p" INFO replication || true)"
    [[ -z "$info" ]] && continue
    info="$(printf '%s' "$info" | tr -d '\r')"
    role="$(awk -F: '/^role:/{print $2}'        <<<"$info")"
    if [[ "$role" == "master" ]]; then printf '%s' "$p"; return 0; fi
    if [[ "$role" == "slave" ]]; then
      mh="$(awk -F: '/^master_host:/{print $2}' <<<"$info")"
      resolve_pod "$mh"; return 0
    fi
  done
  printf '?'; return 1
}

print_primary_line() {  # $1 = previous primary (for failover marker), echoes new primary
    local prev="$1" pod ts
    pod="$(find_primary || true)"
    ts="$(date +%T)"
    if [[ "$pod" == "?" || -z "$pod" ]]; then
      printf '[%s] primary=? (no node responded — rolling/failover?)\n' "$ts" >&2
    else
      printf '[%s] primary=%s   mode=%s\n' "$ts" "$pod" "$MODE" >&2
      if [[ -n "$prev" && "$prev" != "?" && "$pod" != "$prev" ]]; then
        printf '  *** PRIMARY MOVED: %s -> %s ***\n' "$prev" "$pod" >&2
      fi
    fi
    printf '%s' "$pod"   # return value on stdout
}

# Sentinel master group name for this CR (e.g. "myprimary"), queried from a node pod.
resolve_master_name() {
  local m
  m="$(kc exec -i "${STS_LIST%% *}-0" -c sentinel -- env REDISCLI_AUTH="$PASS" \
    valkey-cli -p 26379 "${TLS_ARGS[@]}" sentinel masters 2>/dev/null | tr -d '\r' | sed -n '2p')"
  printf '%s' "${m:-myprimary}"
}

# ── failover measurement (only used by `upgrade --measure`) ──────────────────────
MEASURE_DIR=""; LOG_PID=""; PROBE_POD=""
PROBE_LOG=""; LOG_FILE=""

# Start an in-cluster probe pod that BOTH subscribes to Sentinel events and tight-loops
# SET against the current primary — one pod, one ms-stamped log, survives the whole roll
# (reconnects if the sentinel it is talking to gets rolled). Lines are tagged EVENT/WRITE.
measure_start() {
  MEASURE_DIR="$(mktemp -d -t valkey-measure.XXXXXX)"
  PROBE_LOG="$MEASURE_DIR/probe"; : >"$PROBE_LOG"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  LOG_FILE="${LOG_DIR%/}/${NS}.${CR_NAME}.$(date +%Y%m%dT%H%M%S).log"
  echo "    report file: $LOG_FILE"

  local svc="valkey-${CR_NAME}" headless="valkey-${CR_NAME}-headless" crt="${SECRET}-crt"
  local node0 valkey_img master_name primary_dns primary_sts tls_in="" script sub=""

  valkey_img="$(kc get sts ${STS_LIST%% *} -o jsonpath="{.spec.template.spec.containers[?(@.name=='valkey')].image}" 2>/dev/null)"
  [[ "$TLS_ENABLED" == "true" ]] && tls_in="--tls --cacert /certs/ca.crt --cert /certs/tls.crt --key /certs/tls.key"

  if [[ "$MODE" == "sentinel" ]]; then
    local node_sts="${STS_LIST%% *}" replicas i ep subs=""
    node0="${node_sts}-0"
    replicas="$(kc get sts "$node_sts" -o jsonpath='{.spec.replicas}' 2>/dev/null)"; [[ -z "$replicas" ]] && replicas=3
    master_name="$(resolve_master_name)"
    # One subscriber per node Sentinel (reconnect loop each). Only one pod rolls at a
    # time, so >=2 streams stay live → failover-start events are never lost. Duplicate
    # events across streams are fine: the report takes the earliest occurrence.
    for ((i=0; i<replicas; i++)); do
      ep="${node_sts}-${i}.${headless}"
      subs+="( while true; do valkey-cli -h $ep -p 26379 $tls_in psubscribe '*' 2>/dev/null | while IFS= read -r l; do case \"\$l\" in [+-]*) echo \"EVENT \$(date +%s%3N) \$l\";; esac; done; sleep 0.2; done ) & "
    done
    script="export REDISCLI_AUTH=\"\$VALKEY_PASSWORD\"; $subs
      while true; do t=\$(date +%s%3N);
        a=\$(valkey-cli -h $svc -p 26379 $tls_in sentinel get-master-addr-by-name $master_name 2>/dev/null);
        h=\$(printf '%s\n' \"\$a\" | sed -n 1p); p=\$(printf '%s\n' \"\$a\" | sed -n 2p);
        if [ -n \"\$h\" ] && valkey-cli -h \"\$h\" -p \"\$p\" $tls_in set __ctl_probe__ 1 >/dev/null 2>&1; then echo \"WRITE \$t OK\"; else echo \"WRITE \$t FAIL\"; fi;
      done"
  else
    for s in $STS_LIST; do [[ "$s" == *-primary ]] && primary_sts="$s"; done
    [[ -z "$primary_sts" ]] && primary_sts="${STS_LIST%% *}"
    primary_dns="${primary_sts}-0.${headless}"
    script="export REDISCLI_AUTH=\"\$VALKEY_PASSWORD\";
      while true; do t=\$(date +%s%3N);
        if valkey-cli -h $primary_dns -p 6379 $tls_in set __ctl_probe__ 1 >/dev/null 2>&1; then echo \"WRITE \$t OK\"; else echo \"WRITE \$t FAIL\"; fi;
      done"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "    WARNING: jq not found; skipping measurement (needed to build the probe pod)." >&2
    PROBE_POD=""; return 0
  fi
  PROBE_POD="valkey-ctl-probe-$$"
  local manifest
  manifest="$(jq -n \
    --arg name "$PROBE_POD" --arg ns "$NS" --arg img "$valkey_img" \
    --arg script "$script" --arg secret "$SECRET" --arg crt "$crt" \
    '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns},
      spec:{restartPolicy:"Never",
        containers:[{name:"probe",image:$img,command:["/bin/bash","-c",$script],
          env:[{name:"VALKEY_PASSWORD",valueFrom:{secretKeyRef:{name:$secret,key:"valkey-password"}}}],
          volumeMounts:[{name:"certs",mountPath:"/certs",readOnly:true}]}],
        volumes:[{name:"certs",secret:{secretName:$crt,optional:true}}]}}')"
  if ! printf '%s' "$manifest" | kc apply -f - >/dev/null 2>&1; then
    echo "    WARNING: could not start probe pod; continuing without measurement." >&2
    PROBE_POD=""; return 0
  fi
  kc wait --for=condition=Ready "pod/$PROBE_POD" --timeout=60s >/dev/null 2>&1 || true
  ( kc logs -f "pod/$PROBE_POD" 2>/dev/null >>"$PROBE_LOG" ) & LOG_PID=$!
  disown "$LOG_PID" 2>/dev/null || true
  echo "    measurement probe started (pod/$PROBE_POD, mode=$MODE)"
}

measure_stop() {
  [[ -n "$LOG_PID" ]] && kill "$LOG_PID" 2>/dev/null; LOG_PID=""
  [[ -n "$PROBE_POD" ]] && kc delete pod "$PROBE_POD" --now --ignore-not-found >/dev/null 2>&1; PROBE_POD=""
}

# Write the failover measurement as a structured report to $LOG_FILE (one file per
# migration); stdout only gets a pointer to it.
measure_report() {
  # Pre-compute the headline write-downtime figures so they can lead the report.
  local win_n win_max win_sum win_ok win_fail
  read -r win_n win_max win_sum win_ok win_fail <<<"$(awk '
    $1=="WRITE" && $3=="OK"{ ok++; if(infail){ dt=$2-lastok; n++; s+=dt; if(dt>mx)mx=dt; infail=0 } lastok=$2 }
    $1=="WRITE" && $3=="FAIL"{ fail++; if(!infail) infail=1 }
    END{ printf "%d %d %d %d %d", n+0, mx+0, s+0, ok+0, fail+0 }
  ' "$PROBE_LOG" 2>/dev/null)"
  {
    echo "# Valkey failover / availability measurement"
    echo "namespace:    $NS"
    echo "cr:           $CR_NAME"
    echo "mode:         $MODE"
    echo "tls:          ${TLS_ENABLED:-false}"
    echo "statefulsets: $STS_LIST"
    echo "from_version: $CUR_VER"
    echo "to_version:   $VERSION"
    echo "finished:     $(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo
    echo "==================== SUMMARY ===================="
    if [[ "${win_n:-0}" -gt 0 ]]; then
      echo "  downtime (worst single write outage): ${win_max} ms"
      echo "  downtime (total, all failovers):      ${win_sum} ms across ${win_n} window(s)"
    else
      echo "  downtime: none observed (0 failed writes)"
    fi
    echo "================================================="
    echo

    # Client write-downtime is the authoritative, multi-failover-safe measurement:
    # the real window(s) where a connected client could not write. Reported first.
    # A real failover shows up as a large window; sub-~100ms single-write blips are
    # transient reconnects (e.g. a non-primary Sentinel pod rolling), not a flip.
    echo "== Client write-downtime (windows where writes failed) =="
    if awk '$1=="WRITE"{found=1} END{exit !found}' "$PROBE_LOG"; then
      awk '
        $1=="WRITE" && $3=="OK"{ ok++; if(infail){ dt=$2-lastok; n++; sum+=dt;
            printf "  window #%d: %5d ms (%d failed writes)%s\n", n, dt, cnt, (dt>=500?"   <- failover":"   (transient)");
            if(dt>max)max=dt; infail=0 } lastok=$2 }
        $1=="WRITE" && $3=="FAIL"{ fail++; if(!infail){ infail=1; cnt=0 } cnt++ }
        END{ if(n==0){ print "  no write downtime observed (0 failed writes)" }
             else { printf "  ---\n  longest window: %d ms   total write-unavailable: %d ms across %d window(s)\n", max, sum, n }
             printf "  samples: ok=%d fail=%d\n", ok, fail }
      ' "$PROBE_LOG"
    else
      echo "  no samples captured"
    fi
    echo

    if [[ "$MODE" == "sentinel" ]]; then
      local start_ts promote_ts switch_ts first_ev anchor label
      # earliest occurrence of each milestone (robust to duplicate streams)
      start_ts="$(awk '$1=="EVENT" && $3 ~ /\+(failover-triggered|try-failover|odown)/ {print $2; exit}' "$PROBE_LOG")"
      promote_ts="$(awk '$1=="EVENT" && $3=="+promoted-slave"{print $2; exit}' "$PROBE_LOG")"
      switch_ts="$(awk '$1=="EVENT" && $3=="+switch-master"{print $2; exit}' "$PROBE_LOG")"
      echo "== Sentinel failover timing (first failover) =="
      if [[ -n "$start_ts" && -n "$promote_ts" ]]; then
        echo "  new primary promoted (writable):  $((promote_ts - start_ts)) ms  (from Sentinel starting the failover)"
      fi
      if [[ -n "$start_ts" && -n "$switch_ts" ]]; then
        echo "  full failover (+switch-master):   $((switch_ts - start_ts)) ms  (incl. replica reconfig)"
      fi
      if [[ -z "$start_ts" ]]; then
        echo "  (failover-start events not captured — see client write-downtime above for the observed outage)"
      fi
      echo
      # deduped event timeline, anchored to the failover start, limited to the
      # failover window so unrelated earlier/later events don't clutter it.
      if [[ -n "$start_ts" ]]; then
        anchor="$start_ts"; label="failover start"
      else
        first_ev="$(awk '$1=="EVENT"{print $2; exit}' "$PROBE_LOG")"; anchor="$first_ev"; label="first event"
      fi
      if [[ -n "$anchor" ]]; then
        echo "== Sentinel event timeline (ms from $label) =="
        awk -v s="$anchor" -v sw="$switch_ts" '
          $1=="EVENT" && !seen[$3]++ { d=$2-s; if (d>=0 && (sw=="" || d<=(sw-s)+2000)) printf "  %+7d ms  %s\n", d, $3 }
        ' "$PROBE_LOG"
      fi
    fi
  } > "$LOG_FILE"
  # Also surface the headline numbers on stdout (full detail stays in the file).
  echo "==> Failover measurement summary (full report: $LOG_FILE):"
  grep -E 'downtime \(|window #|new primary promoted|full failover|failover-start events not captured' "$LOG_FILE" \
    | sed 's/^/   /'
}

echo "==> context=$CONTEXT ns=$NS cr=$CR_NAME  mode=$MODE  tls=${TLS_ENABLED:-false}  sts=[$STS_LIST]  version=$CUR_VER"

# ── watch ────────────────────────────────────────────────────────────────────────
if [[ "$CMD" == "watch" ]]; then
  if $ONCE; then print_primary_line "" >/dev/null; exit 0; fi
  echo "Watching primary (mode=$MODE). Ctrl-C to stop."
  prev=""
  while true; do prev="$(print_primary_line "$prev")"; sleep "$INTERVAL"; done
fi

# ── upgrade ───────────────────────────────────────────────────────────────────────
VERSION="${POSITIONAL[0]:-}"
if [[ -z "$VERSION" ]]; then
  echo "ERROR: 'upgrade' needs a target version, e.g. $0 upgrade 9.1.2 -n $NS --name $CR_NAME" >&2
  exit 2
fi
echo "==> Current images:"
for s in $STS_LIST; do
  kc get sts "$s" -o jsonpath="{range .spec.template.spec.containers[*]}    $s/{.name}={.image}{\"\n\"}{end}" 2>/dev/null || true
done
if [[ "$CUR_VER" == "$VERSION" ]]; then
  echo "CR is already on $VERSION; nothing to patch." >&2
  exit 0
fi
echo "==> Target version: $CUR_VER -> $VERSION"
echo

# Show the current primary / Sentinel master BEFORE the migration starts.
echo "==> Before upgrade:"
if [[ "$MODE" == "sentinel" ]]; then
  echo "    sentinel master group: $(resolve_master_name)"
fi
echo "    current primary pod:   $(find_primary)"
echo

# optionally preload images into kind (repos derived from the live STS)
if $LOAD; then
  echo "==> Preloading images into kind cluster '$CLUSTER'"
  declare -A seen=()
  for s in $STS_LIST; do
    for cname in valkey sentinel; do
      repo="$(kc get sts "$s" -o jsonpath="{.spec.template.spec.containers[?(@.name=='$cname')].image}" 2>/dev/null | sed -E 's/:[^:/]+$//')"
      [[ -z "$repo" ]] && continue
      img="${repo}:${VERSION}"
      [[ -n "${seen[$img]:-}" ]] && continue
      seen[$img]=1
      echo "    pull + load $img"; docker pull "$img"; kind load docker-image "$img" --name "$CLUSTER"
    done
  done
  echo
fi

# Monitor the primary in the background while the operator rolls the pods.
MON_PID=""
cleanup() {
  [[ -n "$MON_PID" ]] && kill "$MON_PID" 2>/dev/null
  measure_stop
  return 0
}
trap cleanup EXIT

if $MEASURE; then
  echo "==> Starting failover measurement (--measure):"
  measure_start
  echo
fi

echo "==> Monitoring primary every ${INTERVAL}s during the rollout:"
( prev=""; while true; do prev="$(print_primary_line "$prev")"; sleep "$INTERVAL"; done ) &
MON_PID=$!
disown "$MON_PID" 2>/dev/null || true
echo

echo "==> Patching CR '$CR_NAME': $CUR_VER -> $VERSION  (live CR only; manifest on disk unchanged)"
kc patch valkey "$CR_NAME" --type merge -p "{\"spec\":{\"version\":\"$VERSION\"}}"
echo

# The operator reconciles the CR → StatefulSet asynchronously. Wait until it has
# actually written the new version into the STS before trusting `rollout status`,
# otherwise rollout status sees the still-old (complete) STS and returns immediately.
echo "==> Waiting for the operator to apply $VERSION to the StatefulSet(s)..."
applied_deadline=$(( $(date +%s) + 300 ))
for s in $STS_LIST; do
  until [[ "$(kc get sts "$s" -o jsonpath="{.spec.template.spec.containers[?(@.name=='valkey')].image}" 2>/dev/null)" == *":$VERSION" ]]; do
    [[ "$(date +%s)" -gt "$applied_deadline" ]] && { echo "    WARNING: operator did not update $s to $VERSION within 300s" >&2; break; }
    sleep 2
  done
done

echo "==> Waiting for StatefulSet(s) [$STS_LIST] to roll out..."
deadline=$(( $(date +%s) + 1800 ))
for s in $STS_LIST; do
  until kc rollout status "sts/$s" --timeout=60s 2>/dev/null; do
    [[ "$(date +%s)" -gt "$deadline" ]] && { echo "ERROR: rollout of $s not complete within time budget." >&2; break; }
    echo "    ...$s still rolling (one pod at a time; primary monitor above shows any failover)"
  done
done
echo

# stop the primary monitor, but let the measurement run a few more seconds so the
# probe records the post-failover recovery (first OK after the FAIL window).
[[ -n "$MON_PID" ]] && kill "$MON_PID" 2>/dev/null; MON_PID=""
if $MEASURE; then sleep 3; measure_stop; fi
echo "==> New images:"
for s in $STS_LIST; do
  kc get sts "$s" -o jsonpath="{range .spec.template.spec.containers[*]}    $s/{.name}={.image}{\"\n\"}{end}" 2>/dev/null || true
done
echo "==> Final primary:"; print_primary_line "" >/dev/null
echo
$MEASURE && measure_report
$MEASURE && echo
echo "Done. CR '$CR_NAME' now requests version: $(kc get valkey "$CR_NAME" -o jsonpath='{.spec.version}')"
