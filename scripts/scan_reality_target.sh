#!/usr/bin/env bash
#
# scan_reality_target.sh - find Reality target candidates in an IPv4 CIDR.
#
# For every IP in the CIDR it performs one TLS 1.3 handshake WITHOUT SNI,
# offering ALPN "h2" and only X25519-family key-exchange groups, then reports
# the certificate metadata. A host is listed only when the probe criteria used
# by the official XTLS/RealiTLScanner are met:
#   * TLS 1.3 negotiated
#   * ALPN "h2" selected
#   * a certificate with a non-empty leaf CN and a non-empty issuer
#     organization (the official scanner's `feasible` predicate)
#   * key exchange negotiated with an accepted X25519-family group
#     (plain X25519 or the X25519MLKEM768 hybrid; enforced by offering only
#     those groups, since the REALITY server mirrors the client ClientHello)
#
# This reproduces the official scanner's probing criteria. It does NOT check
# every README recommendation (foreign geography and non-redirect are not
# checked) and it does NOT verify certificate trust/expiry/hostname. It also
# does not implement the shared-list (gfwlist), HTTP status, CDN or popularity
# checks that RealityChecker adds; those are not official requirements.
#
# It also reports OCSP stapling and treats Cloudflare CDN nodes as unqualified:
#   * OCSP_STAPLE : whether THIS handshake returned a stapled OCSP response
#                   (not proof of permanent support or a valid OCSP result)
#   * CLOUDFLARE  : IPs inside Cloudflare's published proxy ranges are treated
#                   as unqualified and are NOT printed
#
# Usage:
#   ./scan_reality_target.sh <CIDR> [PORT]
#
# Environment knobs:
#   THREADS=64                    parallel workers (GNU parallel -j)
#   TIMEOUT=5                     per-handshake openssl timeout in seconds
#   PRECHECK=1                    fast TCP connect test before the handshake (0=off)
#   PRECHECK_TIMEOUT=1            timeout for the precheck in seconds
#   OUT=out.txt                   output file (never stdout); if unset the
#                                 default is out.txt (plain) / out.csv (csv)
#   FORMAT=plain                  plain (IP / Server Name / OCSP) or csv
#   VERBOSE=0                     log rejected hosts to stderr (1=on)
#   TLS_GROUPS=X25519:X25519MLKEM768  accepted groups only (X25519 / X25519MLKEM768)
#   MAX_HOSTS=65536               refuse CIDRs larger than this unless FORCE=1
#   FORCE=0                       allow oversized CIDRs
#   DELAY=0                       seconds between job starts (e.g. 0.05)
#   JOBLOG=""                     GNU parallel job log path (exit 0 = probe
#                                 completed, NOT that the target qualified)
#   PROGRESS=auto                 progress bar: auto = on when stderr is a
#                                 terminal, 1 = always, 0 = never
#   QUIET=0                       suppress startup status lines (1=on)
#   CF_RANGES_FILE=""             override the Cloudflare IPv4 range list path
#                                 (dispatcher normally fetches it)
#
# Re-exec under bash if invoked via sh/dash (needed for /dev/tcp and arrays).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

set -u

# GNU parallel dispatches single hosts as:  <script> --worker <ip>
WORKER=0
if [ "${1:-}" = "--worker" ]; then
  WORKER=1
  WORKER_IP=${2:-}
fi

# --- settings (env wins; used by both the dispatcher and the workers) ------
PORT=${PORT:-443}
TIMEOUT=${TIMEOUT:-5}
PRECHECK=${PRECHECK:-1}
PRECHECK_TIMEOUT=${PRECHECK_TIMEOUT:-1}
OUT=${OUT:-}
FORMAT=${FORMAT:-plain}
VERBOSE=${VERBOSE:-0}
TLS_GROUPS=${TLS_GROUPS:-X25519:X25519MLKEM768}
MAX_HOSTS=${MAX_HOSTS:-65536}
FORCE=${FORCE:-0}
THREADS=${THREADS:-64}
DELAY=${DELAY:-0}
JOBLOG=${JOBLOG:-}
PROGRESS=${PROGRESS:-auto}
QUIET=${QUIET:-0}
CF_RANGES_FILE=${CF_RANGES_FILE:-}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { [ "$VERBOSE" = "1" ] && printf '%s\n' "$*" >&2 || true; }
csvq() { printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"; }
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
require_bins() { local b; for b in "$@"; do command -v "$b" >/dev/null 2>&1 || die "$b not found"; done; }

# Enumerate exactly <size> addresses starting at the network address <net>.
enum_ips() {
  awk -v net="$1" -v size="$2" 'BEGIN {
    for (i = 0; i < size; i++) {
      x = net + i
      printf "%d.%d.%d.%d\n", int(x/16777216)%256, int(x/65536)%256, int(x/256)%256, x%256
    }
  }'
}

# Membership in Cloudflare's published IPv4 ranges: yes / no / unknown.
cf_check() {
  local ip="$1"
  if [ -z "${CF_RANGES_FILE:-}" ] || [ ! -s "$CF_RANGES_FILE" ]; then printf 'unknown'; return 0; fi
  awk -v ip="$ip" -v rf="$CF_RANGES_FILE" '
    function toint(s, a, n, i, r) { n = split(s, a, "."); r = 0; for (i = 1; i <= n; i++) r = r*256 + a[i]; return r }
    BEGIN {
      if (ip !~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) { print "unknown"; exit }
      ipn = toint(ip)
      while ((getline line < rf) > 0) {
        sub(/\r$/, "", line); if (line == "") continue
        split(line, p, "/"); base = toint(p[1]); size = 2^(32 - (p[2] + 0)); net = int(base/size)*size
        if (ipn >= net && ipn < net + size) { print "yes"; exit }
      }
      print "no"
    }'
}

# Run one s_client handshake; stdout+stderr merged so diagnostics are visible.
# The function's exit status is the handshake's status.
ssl_run() { printf '' | timeout "$TIMEOUT" openssl s_client "$@" 2>&1; }

# Classify a probe: 0 = ok, 1 = ordinary probe failure, 2 = local/exec error.
probe_status() {
  local raw="$1" rc="$2" label="$3"
  if printf '%s' "$raw" | grep -qiE 'unknown option|invalid option|unsupported option|SSL_CONF_cmd|cannot open|no such file'; then
    printf 'scan_reality_target: openssl/local error for %s: %s\n' "$label" "$(printf '%s\n' "$raw" | head -1)" >&2
    return 2
  fi
  if [ "$rc" -ge 125 ] && [ "$rc" -le 127 ]; then
    printf 'scan_reality_target: openssl execution failed for %s (rc=%s)\n' "$label" "$rc" >&2
    return 2
  fi
  [ "$rc" -eq 0 ]
}

extract_cert() { printf '%s\n' "$1" | awk '/BEGIN CERTIFICATE/{f=1} f{print} /END CERTIFICATE/{if(f)exit}'; }

# Scan one host. Returns 0 for "probe completed" (row or no row), and a
# nonzero status only for local/operational errors that must surface.
scan_one() {
  local ip="$1" raw rc cert fields text ps issuer issuer_org
  local tls alpn curve ncert sigalg pubkey cn sans notafter ocsp cf

  if [ "$PRECHECK" = "1" ]; then
    timeout "$PRECHECK_TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$ip" "$PORT" 2>/dev/null
    case "$?" in
      0)          : ;;
      124)        log "reject $ip: tcp/$PORT timeout"; return 0 ;;
      125|126|127) printf 'scan_reality_target: precheck execution failed for %s\n' "$ip" >&2; return 2 ;;
      *)          log "reject $ip: tcp/$PORT not reachable"; return 0 ;;
    esac
  fi

  # Single no-SNI handshake; -status requests OCSP stapling for the report.
  raw=$(ssl_run -noservername -connect "$ip:$PORT" -status -alpn h2 \
                -groups "$TLS_GROUPS" -tls1_3 -showcerts)
  rc=$?
  probe_status "$raw" "$rc" "$ip"; ps=$?
  [ "$ps" -eq 2 ] && return 2
  [ "$ps" -ne 0 ] && { log "reject $ip: handshake failed (rc=$rc)"; return 0; }

  # TLS 1.3 must have been negotiated (a failed handshake can still echo
  # "Protocol: TLSv1.3" together with "New, (NONE), Cipher is (NONE)").
  printf '%s\n' "$raw" | grep -qE 'New, TLSv1\.3, Cipher is ' || \
    printf '%s\n' "$raw" | grep -qE 'Protocol *: *TLSv1\.3' || \
    { log "reject $ip: no TLS1.3"; return 0; }

  printf '%s\n' "$raw" | grep -q 'ALPN protocol: h2' || { log "reject $ip: no ALPN h2"; return 0; }
  tls="TLSv1.3"; alpn="h2"

  cert=$(extract_cert "$raw")
  [ -n "$cert" ] || { log "reject $ip: no certificate"; return 0; }
  fields=$(printf '%s\n' "$cert" | openssl x509 -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null)
  if [ $? -ne 0 ] || [ -z "$fields" ]; then log "reject $ip: unparseable certificate"; return 0; fi

  # Official scanner predicate: non-empty leaf CN and issuer organization.
  cn=$(printf '%s\n' "$fields" | sed -nE 's/^subject=.*CN *= *([^,]+).*/\1/p' | head -1)
  [ -n "$cn" ] || { log "reject $ip: certificate has no CN"; return 0; }
  issuer=$(printf '%s\n' "$fields" | sed -nE 's/^issuer=//p' | head -1)
  issuer_org=$(printf '%s\n' "$issuer" | tr ',' '\n' | sed -nE 's/^ *O *= *//p' | head -1)
  [ -n "$issuer_org" ] || { log "reject $ip: certificate has no issuer organization"; return 0; }

  # Negotiated key-exchange group: wording varies between OpenSSL versions.
  curve=$(printf '%s\n' "$raw" | sed -nE 's/^ *(Server Temp Key|Peer Temp Key): *([^,]+).*/\2/p' | head -1)
  [ -n "$curve" ] || curve=$(printf '%s\n' "$raw" | sed -nE 's/^ *Negotiated TLS1.3 group: *//p' | head -1)
  [ -n "$curve" ] || curve="-"
  ncert=$(printf '%s\n' "$raw" | grep -c -- 'BEGIN CERTIFICATE')

  notafter=$(printf '%s\n' "$fields" | sed -nE 's/^notAfter=//p' | head -1)
  sans=$(printf '%s\n' "$fields" | grep -o 'DNS:[^,]*' | sed 's/^DNS://' | paste -sd';' -)
  text=$(printf '%s\n' "$cert" | openssl x509 -noout -text 2>/dev/null)
  sigalg=$(printf '%s\n' "$text" | grep -m1 'Signature Algorithm' | awk '{print $3}')
  pubkey=$(printf '%s\n' "$text" | grep -m1 'Public Key Algorithm' | awk '{print $4}')

  # Informational only.
  ocsp="no"
  printf '%s\n' "$raw" | grep -qE 'OCSP Response Status:|number of responses: [1-9]' && ocsp="yes"
  cf=$(cf_check "$ip")

  # Cloudflare CDN nodes are treated as unqualified and not reported.
  if [ "$cf" = "yes" ]; then log "reject $ip: Cloudflare CDN node"; return 0; fi

  local prc=0
  if [ "$FORMAT" = "csv" ]; then
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$ip" "$tls" "$alpn" "$curve" "$ncert" "${sigalg:--}" "${pubkey:--}" \
      "$(csvq "$cn")" "$(csvq "$sans")" "$(csvq "$issuer")" "$(csvq "$notafter")" \
      "$ocsp" "$cf"
  else
    printf '%s\t%s\t%s\n' "$ip" "$cn" "$ocsp"
  fi
  prc=$?
  [ -n "${RESULT_COUNTER:-}" ] && printf 'x' >> "$RESULT_COUNTER" 2>/dev/null
  return "$prc"
}

# --- worker: scan exactly one host and exit ---------------------------------
if [ "$WORKER" = "1" ]; then
  [ -n "$WORKER_IP" ] || die "--worker requires an IP address"
  require_bins openssl sed grep paste awk
  [ "$PRECHECK" = "1" ] && require_bins timeout
  scan_one "$WORKER_IP"
  exit $?
fi

# --- dispatcher -------------------------------------------------------------
CIDR=${1:-}
case "$CIDR" in */*) ;; *) die "expected a CIDR (e.g. 203.0.113.0/24); domains are not supported" ;; esac
base=${CIDR%/*}
pfx=${CIDR#*/}

require_bins openssl parallel awk timeout sed grep paste head wc

# The group offer may only contain the accepted X25519-family groups, so a
# configuration cannot silently bypass the stated requirement.
case "$TLS_GROUPS" in
  X25519|X25519MLKEM768|X25519:X25519MLKEM768|X25519MLKEM768:X25519) ;;
  *) die "TLS_GROUPS must be X25519 and/or X25519MLKEM768 (got: $TLS_GROUPS)" ;;
esac

# Validate the whole CIDR (octets, 1-2 digit decimal prefix) before opening OUT.
if [[ ! "$base" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
  die "invalid IPv4 address: $base"
fi
o1=$((10#${BASH_REMATCH[1]})); o2=$((10#${BASH_REMATCH[2]}))
o3=$((10#${BASH_REMATCH[3]})); o4=$((10#${BASH_REMATCH[4]}))
for o in "$o1" "$o2" "$o3" "$o4"; do
  [ "$o" -le 255 ] || die "invalid IPv4 address: $base"
done
[[ "$pfx" =~ ^[0-9]{1,2}$ ]] || die "invalid prefix in '$CIDR'"
pfx=$((10#$pfx))
[ "$pfx" -le 32 ] || die "invalid IPv4 prefix: $pfx"

[ -n "${2:-}" ] && PORT=$2
is_uint "$PORT" && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "invalid PORT: $PORT"
is_uint "$THREADS" && [ "$THREADS" -ge 1 ] || die "invalid THREADS: $THREADS"
is_uint "$TIMEOUT" && [ "$TIMEOUT" -ge 1 ] || die "invalid TIMEOUT: $TIMEOUT"
is_uint "$PRECHECK_TIMEOUT" && [ "$PRECHECK_TIMEOUT" -ge 1 ] || die "invalid PRECHECK_TIMEOUT: $PRECHECK_TIMEOUT"
is_uint "$MAX_HOSTS" && [ "$MAX_HOSTS" -ge 1 ] || die "invalid MAX_HOSTS: $MAX_HOSTS"
case "$PRECHECK" in 0|1) ;; *) die "PRECHECK must be 0 or 1" ;; esac
case "$FORCE" in 0|1) ;; *) die "FORCE must be 0 or 1" ;; esac
case "$PROGRESS" in 0|1|auto) ;; *) die "PROGRESS must be 0, 1 or auto" ;; esac
case "$QUIET" in 0|1) ;; *) die "QUIET must be 0 or 1" ;; esac
case "$FORMAT" in plain|csv) ;; *) die "FORMAT must be plain or csv" ;; esac
if [ -z "$OUT" ]; then
  case "$FORMAT" in csv) OUT=out.csv ;; *) OUT=out.txt ;; esac
fi
case "$DELAY" in ''|*[!0-9.]*|*.*.*) die "invalid DELAY: $DELAY" ;; esac

# Fetch Cloudflare's published IPv4 proxy ranges once (best effort). On any
# failure the CLOUDFLARE column is reported as "unknown", never "no".
cf_tmp=""; cf_clean=""
if [ -z "$CF_RANGES_FILE" ]; then
  [ "$QUIET" = "1" ] || printf 'scan_reality_target: fetching Cloudflare IPv4 ranges...\n' >&2
  if command -v curl >/dev/null 2>&1 && command -v mktemp >/dev/null 2>&1; then
    cf_tmp=$(mktemp 2>/dev/null) || cf_tmp=""
    if [ -n "$cf_tmp" ]; then
      cf_clean="$cf_tmp.cidr"
      if curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v4 -o "$cf_tmp" 2>/dev/null; then
        tr -d '\r' < "$cf_tmp" | grep -v '^[[:space:]]*$' > "$cf_clean" 2>/dev/null || true
        if [ -s "$cf_clean" ] && \
           awk '{ if ($0 !~ /^([0-9]{1,3}\.){3}[0-9]{1,3}\/[0-9]{1,2}$/) bad=1; else n++ } END { exit (bad || n==0) }' "$cf_clean"; then
          CF_RANGES_FILE="$cf_clean"
        else
          CF_RANGES_FILE=""
        fi
      fi
    fi
  fi
fi
trap 'rm -f "$cf_tmp" "$cf_clean" "$RESULT_COUNTER"' EXIT
RESULT_COUNTER=""
if command -v mktemp >/dev/null 2>&1; then RESULT_COUNTER=$(mktemp 2>/dev/null) || RESULT_COUNTER=""; fi
if [ -n "$CF_RANGES_FILE" ] && [ -s "$CF_RANGES_FILE" ]; then
  [ "$QUIET" = "1" ] || printf 'scan_reality_target: Cloudflare ranges ready (%s prefixes)\n' "$(wc -l < "$CF_RANGES_FILE")" >&2
else
  [ "$QUIET" = "1" ] || printf 'scan_reality_target: Cloudflare ranges unavailable (CLOUDFLARE=unknown)\n' >&2
fi

# Network address and address count (decimal, leading-zero safe).
ipnum=$(( o1*16777216 + o2*65536 + o3*256 + o4 ))
size=$(( 1 << (32 - pfx) ))
net=$(( ipnum / size * size ))
if [ "$size" -gt "$MAX_HOSTS" ] && [ "$FORCE" != "1" ]; then
  die "$CIDR contains $size hosts (> MAX_HOSTS=$MAX_HOSTS); set MAX_HOSTS or FORCE=1 to override"
fi
[ "$QUIET" = "1" ] || printf 'scan_reality_target: scanning %s (%s hosts, %s workers, port %s)\n' \
  "$CIDR" "$size" "$THREADS" "$PORT" >&2
if [ -n "$OUT" ]; then : > "$OUT" || die "cannot write $OUT"; fi
if [ "$FORMAT" = "csv" ]; then
  HDR='IP,TLS,ALPN,CURVE,CERT_COUNT,CERT_SIGALG,CERT_PUBKEY,CERT_DOMAIN,CERT_SANS,CERT_ISSUER,CERT_NOT_AFTER,OCSP_STAPLE,CLOUDFLARE'
else
  HDR=$(printf 'IP\tServer Name\tOCSP_STAPLE')
fi
printf '%s\n' "$HDR" >> "$OUT" || die "cannot write $OUT"

# Settings must reach the worker processes spawned by parallel.
export PORT TIMEOUT PRECHECK PRECHECK_TIMEOUT VERBOSE TLS_GROUPS CF_RANGES_FILE FORMAT RESULT_COUNTER

# Absolute path to this script, so workers can be re-invoked anywhere.
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

opts=( -j "$THREADS" --will-cite )
[ "$DELAY" != "0" ] && opts+=( --delay "$DELAY" )
[ -n "$JOBLOG" ]     && opts+=( --joblog "$JOBLOG" )
progress_on=0
[ "$PROGRESS" = "1" ] && progress_on=1
{ [ "$PROGRESS" = "auto" ] && [ -t 2 ]; } && progress_on=1
[ "$progress_on" = "1" ] && opts+=( --bar )

# --quote protects the script path (spaces); GNU parallel groups job output.
enum_ips "$net" "$size" | parallel "${opts[@]}" --quote bash "$SELF" --worker {} >> "$OUT"
st=("${PIPESTATUS[@]}")
[ "${st[0]:-0}" -eq 0 ] || die "CIDR enumeration failed"
[ "${st[1]:-0}" -eq 0 ] || die "scan failed (parallel exit ${st[1]})"

[ -n "$JOBLOG" ] && printf 'job log: %s\n' "$JOBLOG" >&2
if [ -n "$RESULT_COUNTER" ]; then rows=$(wc -c < "$RESULT_COUNTER"); else rows="?"; fi
printf 'done: %s result(s) -> %s\n' "$rows" "$OUT" >&2
