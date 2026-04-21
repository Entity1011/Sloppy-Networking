#!/usr/bin/env bash
# =============================================================================
# net_test.sh — Comprehensive Network Test for Rocky Linux 8.10
# Runtime: ~10 minutes | Run as root for full results
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { echo -e "  ${GREEN}✔ $*${RESET}"; }
fail()  { echo -e "  ${RED}✗ $*${RESET}"; }
info()  { echo -e "  ${CYAN}→ $*${RESET}"; }
warn()  { echo -e "  ${YELLOW}⚠ $*${RESET}"; }
header(){ echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
          echo -e "${BOLD}  $*${RESET}"; \
          echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

LOGFILE="/tmp/net_test_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "Log: $LOGFILE"

# ── Dependency installer ──────────────────────────────────────────────────────
install_pkg() {
    local pkg=$1
    if ! command -v "$2" &>/dev/null; then
        warn "$pkg not found — installing..."
        dnf install -y -q "$pkg" 2>/dev/null || \
        dnf install -y -q --enablerepo=epel "$pkg" 2>/dev/null || \
        { warn "Could not install $pkg — skipping related tests"; return 1; }
    fi
    return 0
}

ensure_epel() {
    if ! rpm -q epel-release &>/dev/null; then
        info "Enabling EPEL..."
        dnf install -y -q epel-release 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
header "1 · SYSTEM & INTERFACE INVENTORY"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
info "Hostname   : $(hostname -f 2>/dev/null || hostname)"
info "OS         : $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
info "Kernel     : $(uname -r)"
info "Date (UTC) : $(date -u)"

echo ""
info "Network interfaces:"
ip -o link show | awk '{print $2,$9}' | while read iface state; do
    iface="${iface%:}"
    [[ "$iface" == "lo" ]] && continue
    ip_addr=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)
    mac=$(ip link show "$iface" 2>/dev/null | awk '/ether/{print $2}')
    speed_file="/sys/class/net/${iface}/speed"
    speed=$( [[ -r "$speed_file" ]] && cat "$speed_file" 2>/dev/null && echo " Mb/s" || echo "n/a")
    printf "    %-12s  state=%-4s  ip=%-18s  mac=%s  link=%s Mb/s\n" \
        "$iface" "$state" "${ip_addr:-none}" "${mac:-n/a}" "$speed"
done

echo ""
info "Routing table (IPv4):"
ip -4 route show | sed 's/^/    /'

GW=$(ip -4 route show default 2>/dev/null | awk '/default/{print $3; exit}')
[[ -n "$GW" ]] && pass "Default gateway: $GW" || fail "No default gateway found"

# ═══════════════════════════════════════════════════════════════════════════════
header "2 · DNS RESOLUTION"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
info "Configured resolvers:"
grep -E '^nameserver' /etc/resolv.conf | sed 's/^/    /' || warn "/etc/resolv.conf has no nameserver entries"

DNS_HOSTS=("google.com" "cloudflare.com" "github.com")
for host in "${DNS_HOSTS[@]}"; do
    result=$(dig +short +time=3 +tries=2 "$host" 2>/dev/null | head -1)
    if [[ -n "$result" ]]; then
        pass "Resolved $host → $result"
    else
        fail "Failed to resolve $host"
    fi
done

info "DNS response times (3 queries each):"
for ns in $(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | head -3); do
    avg=$(dig @"$ns" google.com +stats +time=3 +tries=1 2>/dev/null \
          | awk '/Query time/{sum+=$4; n++} END{if(n>0) printf "%.0f ms", sum/n; else print "timeout"}')
    info "  $ns → $avg"
done

# ═══════════════════════════════════════════════════════════════════════════════
header "3 · ICMP LATENCY & PACKET LOSS"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
PING_TARGETS=("8.8.8.8" "1.1.1.1" "8.8.4.4")
[[ -n "$GW" ]] && PING_TARGETS=("$GW" "${PING_TARGETS[@]}")

for target in "${PING_TARGETS[@]}"; do
    result=$(ping -c 10 -W 2 "$target" 2>/dev/null | tail -2)
    loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)' || echo "100")
    rtt=$(echo "$result"  | grep -oP 'rtt.*' | awk -F'/' '{print $5}' || echo "n/a")
    if [[ "$loss" -eq 0 ]]; then
        pass "$target  loss=${loss}%  avg_rtt=${rtt} ms"
    elif [[ "$loss" -lt 5 ]]; then
        warn "$target  loss=${loss}%  avg_rtt=${rtt} ms"
    else
        fail "$target  loss=${loss}%"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
header "4 · TRACEROUTE  (first 15 hops to 8.8.8.8)"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
if command -v traceroute &>/dev/null; then
    traceroute -m 15 -w 2 8.8.8.8 2>/dev/null | sed 's/^/  /' || warn "traceroute failed"
else
    warn "traceroute not installed — install with: dnf install traceroute"
fi

# ═══════════════════════════════════════════════════════════════════════════════
header "5 · TCP CONNECTIVITY TO KEY PORTS"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
declare -A TCP_TARGETS=(
    ["8.8.8.8:53"]="Google DNS/TCP"
    ["1.1.1.1:443"]="Cloudflare HTTPS"
    ["github.com:443"]="GitHub HTTPS"
    ["github.com:22"]="GitHub SSH"
    ["pypi.org:443"]="PyPI HTTPS"
    ["registry-1.docker.io:443"]="Docker Registry"
)

for target in "${!TCP_TARGETS[@]}"; do
    host="${target%:*}"; port="${target##*:}"
    label="${TCP_TARGETS[$target]}"
    if timeout 5 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        pass "$label ($host:$port) — reachable"
    else
        fail "$label ($host:$port) — blocked or unreachable"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
header "6 · LOCAL FIREWALL  (firewalld + nftables/iptables)"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
if systemctl is-active --quiet firewalld 2>/dev/null; then
    pass "firewalld is running"
    info "Active zone: $(firewall-cmd --get-active-zones 2>/dev/null | head -1)"
    info "Allowed services:"
    firewall-cmd --list-services 2>/dev/null | tr ' ' '\n' | sed 's/^/    /'
    info "Allowed ports:"
    firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | sed 's/^/    /' || info "    (none explicitly)"
    info "Rich rules:"
    firewall-cmd --list-rich-rules 2>/dev/null | sed 's/^/    /' || info "    (none)"
else
    warn "firewalld is NOT running"
fi

echo ""
info "nftables ruleset summary:"
if command -v nft &>/dev/null; then
    nft list ruleset 2>/dev/null | grep -E '(table|chain|type|policy|accept|drop|reject)' \
        | head -30 | sed 's/^/    /' || info "    (empty ruleset)"
else
    warn "nft not available"
fi

echo ""
info "iptables rules (filter table):"
if command -v iptables &>/dev/null; then
    iptables -L -n --line-numbers 2>/dev/null | grep -v '^$' | head -40 | sed 's/^/    /' \
        || warn "Could not read iptables (try running as root)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
header "7 · OPEN PORTS & LISTENING SERVICES"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
info "Listening TCP ports:"
ss -tlnp 2>/dev/null | sed 's/^/  /'

echo ""
info "Listening UDP ports:"
ss -ulnp 2>/dev/null | sed 's/^/  /'

echo ""
info "Established connections (top 10):"
ss -tnp state established 2>/dev/null | head -11 | sed 's/^/  /'

# ═══════════════════════════════════════════════════════════════════════════════
header "8 · BANDWIDTH TEST  (iperf3 loopback + curl download)"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""

# ── 8a: iperf3 loopback (CPU/stack throughput) ────────────────────────────────
if install_pkg iperf3 iperf3; then
    info "iperf3 loopback test (10 s, 4 parallel streams)..."
    iperf3 -s -D --one-off 2>/dev/null &
    IPERF_PID=$!
    sleep 0.5
    iperf3 -c 127.0.0.1 -t 10 -P 4 --format m 2>/dev/null | tail -4 | sed 's/^/  /'
    kill $IPERF_PID 2>/dev/null || true
fi

# ── 8b: Download speed via curl ───────────────────────────────────────────────
echo ""
info "Download speed test (100 MB file from Cloudflare)..."
DL_SPEED=$(curl -s -o /dev/null -w "%{speed_download}" --max-time 60 \
    "https://speed.cloudflare.com/__down?bytes=104857600" 2>/dev/null || echo 0)
DL_MBPS=$(awk "BEGIN{printf \"%.1f\", $DL_SPEED/1048576}")
if (( $(echo "$DL_MBPS > 0" | bc -l 2>/dev/null || echo 0) )); then
    pass "Download speed: ${DL_MBPS} MB/s  (~$(awk "BEGIN{printf \"%.0f\", $DL_MBPS*8}") Mbps)"
else
    fail "Download test failed (check egress / DNS)"
fi

# ── 8c: Upload speed via curl PUT ────────────────────────────────────────────
echo ""
info "Upload speed test (10 MB to Cloudflare)..."
UL_SPEED=$(dd if=/dev/urandom bs=1M count=10 2>/dev/null | \
    curl -s -o /dev/null -w "%{speed_upload}" --max-time 30 \
    -X POST "https://speed.cloudflare.com/__up" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @- 2>/dev/null || echo 0)
UL_MBPS=$(awk "BEGIN{printf \"%.1f\", $UL_SPEED/1048576}")
if (( $(echo "$UL_MBPS > 0" | bc -l 2>/dev/null || echo 0) )); then
    pass "Upload speed  : ${UL_MBPS} MB/s  (~$(awk "BEGIN{printf \"%.0f\", $UL_MBPS*8}") Mbps)"
else
    warn "Upload test inconclusive"
fi

# ═══════════════════════════════════════════════════════════════════════════════
header "9 · MTU & FRAGMENTATION"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
PRIMARY_IF=$(ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}')
if [[ -n "$PRIMARY_IF" ]]; then
    MTU=$(ip link show "$PRIMARY_IF" | awk '/mtu/{for(i=1;i<=NF;i++) if ($i=="mtu") print $(i+1)}')
    info "Interface $PRIMARY_IF MTU: $MTU"

    # Test path MTU with progressively larger pings (DF bit set)
    for size in 576 1024 1400 1472 1500; do
        if ping -c 2 -W 2 -M do -s "$size" 8.8.8.8 &>/dev/null; then
            pass "Path MTU ≥ $((size+28)) bytes (payload $size)"
        else
            warn "Fragmentation occurs above $((size+28)) bytes (payload $size)"
            break
        fi
    done
fi

# ═══════════════════════════════════════════════════════════════════════════════
header "10 · IPV6 CONNECTIVITY"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
IPV6_ADDR=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | head -1)
if [[ -n "$IPV6_ADDR" ]]; then
    pass "IPv6 address assigned: $IPV6_ADDR"
    if ping6 -c 4 -W 2 2001:4860:4860::8888 &>/dev/null; then
        pass "IPv6 to Google DNS (2001:4860:4860::8888) — OK"
    else
        fail "IPv6 to Google DNS — unreachable"
    fi
    if curl -s -6 --max-time 5 -o /dev/null -w "%{http_code}" https://ipv6.google.com &>/dev/null | grep -q "200\|301"; then
        pass "IPv6 HTTPS to ipv6.google.com — OK"
    else
        warn "IPv6 HTTPS check inconclusive"
    fi
else
    warn "No global IPv6 address — IPv6 appears disabled or unconfigured"
fi

# ═══════════════════════════════════════════════════════════════════════════════
header "11 · NTP / TIME SYNC"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
if command -v chronyc &>/dev/null; then
    info "chronyc tracking:"
    chronyc tracking 2>/dev/null | grep -E '(Reference ID|System time|Stratum|Leap status)' | sed 's/^/  /'
    info "Top NTP sources:"
    chronyc sources -v 2>/dev/null | head -10 | sed 's/^/  /'
    OFFSET=$(chronyc tracking 2>/dev/null | awk '/System time/{gsub(/[^0-9.]/,"",$4); print $4+0}')
    if (( $(echo "${OFFSET:-999} < 1" | bc -l 2>/dev/null || echo 0) )); then
        pass "Clock offset < 1 second"
    else
        warn "Clock offset may be large: check chrony"
    fi
elif command -v timedatectl &>/dev/null; then
    timedatectl status | sed 's/^/  /'
fi

# ═══════════════════════════════════════════════════════════════════════════════
header "SUMMARY"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "  Full log saved to: ${BOLD}$LOGFILE${RESET}"
echo ""
PASS_COUNT=$(grep -c "✔" "$LOGFILE" 2>/dev/null || echo 0)
FAIL_COUNT=$(grep -c "✗" "$LOGFILE" 2>/dev/null || echo 0)
WARN_COUNT=$(grep -c "⚠" "$LOGFILE" 2>/dev/null || echo 0)
echo -e "  ${GREEN}${BOLD}Passed : $PASS_COUNT${RESET}"
echo -e "  ${RED}${BOLD}Failed : $FAIL_COUNT${RESET}"
echo -e "  ${YELLOW}${BOLD}Warned : $WARN_COUNT${RESET}"
echo ""
[[ "$FAIL_COUNT" -eq 0 ]] \
    && echo -e "  ${GREEN}${BOLD}✔ All critical checks passed.${RESET}" \
    || echo -e "  ${RED}${BOLD}✗ $FAIL_COUNT check(s) failed — review the log above.${RESET}"
echo ""
