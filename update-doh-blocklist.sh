#!/bin/bash
# =============================================================================
# UniFi DoH Updater
#
# Downloads DNS-over-HTTPS (DoH) IP lists from configurable sources and updates
# a UniFi firewall group via the controller API. Works with all UniFi OS
# gateways (UDM, UDM Pro, UDM SE, UCG Ultra, UCG Fiber, etc.)
#
# Usage:
#   ./update-doh-blocklist.sh              # one-off run
#   CRON_SCHEDULE="0 4 * * *" ./update-doh-blocklist.sh --cron  # schedule mode
#
# Required environment variables:
#   UNIFI_HOST       - Controller URL (e.g., https://192.168.1.1)
#
# Authentication (choose one):
#   UNIFI_API_KEY    - API key (recommended, stateless, no login needed)
#   --- OR ---
#   UNIFI_USER       - Controller username
#   UNIFI_PASS       - Controller password
#
# Optional environment variables:
#   UNIFI_SITE       - Site name (default: "default")
#   FIREWALL_GROUP   - Name of the IPv4 firewall group (default: "DoH Servers")
#   FIREWALL_GROUP_V6- Name of the IPv6 firewall group (default: "DoH Servers IPv6")
#   DOH_LISTS_V4     - Space-separated URLs to IPv4 DoH lists
#   DOH_LISTS_V6     - Space-separated URLs to IPv6 DoH lists
#   IPV6_ENABLED     - Include IPv6 addresses (default: "false")
#   DRY_RUN          - Print what would be done without making changes (default: "false")
#   VERIFY_SSL       - Verify SSL certificates (default: "false")
# =============================================================================

set -euo pipefail

# --- Configuration ---
UNIFI_HOST="${UNIFI_HOST:-}"
UNIFI_API_KEY="${UNIFI_API_KEY:-}"
UNIFI_USER="${UNIFI_USER:-}"
UNIFI_PASS="${UNIFI_PASS:-}"
UNIFI_SITE="${UNIFI_SITE:-default}"
AUTH_MODE=""  # set during validate_config: "apikey" or "credentials"
FIREWALL_GROUP="${FIREWALL_GROUP:-DoH Servers}"
FIREWALL_GROUP_V6="${FIREWALL_GROUP_V6:-DoH Servers IPv6}"
IPV6_ENABLED="${IPV6_ENABLED:-false}"
DRY_RUN="${DRY_RUN:-false}"
VERIFY_SSL="${VERIFY_SSL:-false}"

# Default DoH IP lists (dibdot is the most comprehensive maintained list)
DEFAULT_IPV4_LIST="https://raw.githubusercontent.com/dibdot/DoH-IP-blocklists/master/doh-ipv4.txt"
DEFAULT_IPV6_LIST="https://raw.githubusercontent.com/dibdot/DoH-IP-blocklists/master/doh-ipv6.txt"

DOH_LISTS_V4="${DOH_LISTS_V4:-$DEFAULT_IPV4_LIST}"
DOH_LISTS_V6="${DOH_LISTS_V6:-$DEFAULT_IPV6_LIST}"

if [ "$IPV6_ENABLED" = "true" ]; then
    DOH_LISTS="$DOH_LISTS_V4 $DOH_LISTS_V6"
else
    DOH_LISTS="$DOH_LISTS_V4"
fi

# --- Globals ---
COOKIE_FILE=$(mktemp)
CSRF_TOKEN=""

# Curl options
CURL_OPTS=("-s" "-S" "-b" "$COOKIE_FILE" "-c" "$COOKIE_FILE")
if [ "$VERIFY_SSL" = "false" ]; then
    CURL_OPTS+=("-k")
fi

# --- Functions ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

cleanup() {
    rm -f "$COOKIE_FILE"
}
trap cleanup EXIT

validate_config() {
    if [ -z "$UNIFI_HOST" ]; then
        log "ERROR: UNIFI_HOST is required"
        exit 1
    fi

    if [ -n "$UNIFI_API_KEY" ]; then
        AUTH_MODE="apikey"
        log "Using API key authentication (stateless)"
    elif [ -n "$UNIFI_USER" ] && [ -n "$UNIFI_PASS" ]; then
        AUTH_MODE="credentials"
        log "Using username/password authentication"
    else
        log "ERROR: Set UNIFI_API_KEY or both UNIFI_USER and UNIFI_PASS"
        exit 1
    fi
}

unifi_login() {
    log "Logging in to UniFi controller at $UNIFI_HOST..."

    local response
    response=$(curl "${CURL_OPTS[@]}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"$UNIFI_USER\", \"password\": \"$UNIFI_PASS\"}" \
        -w "\n%{http_code}" \
        "$UNIFI_HOST/api/auth/login" 2>&1)

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" != "200" ]; then
        log "ERROR: Login failed (HTTP $http_code)"
        log "Response: $body"
        exit 1
    fi

    # Extract CSRF token from cookie file (x-csrf-token or TOKEN)
    CSRF_TOKEN=$(grep -i "csrf" "$COOKIE_FILE" 2>/dev/null | awk '{print $NF}' || true)
    # Also try to get from response headers
    if [ -z "$CSRF_TOKEN" ]; then
        CSRF_TOKEN=$(curl "${CURL_OPTS[@]}" -s -D - -o /dev/null "$UNIFI_HOST/api/auth/login" 2>/dev/null | grep -i "x-csrf-token" | awk '{print $2}' | tr -d '\r' || true)
    fi

    log "Login successful"
}

unifi_logout() {
    curl "${CURL_OPTS[@]}" -X POST "$UNIFI_HOST/api/auth/logout" >/dev/null 2>&1 || true
    log "Logged out"
}

api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local headers=(-H "Content-Type: application/json")

    if [ "$AUTH_MODE" = "apikey" ]; then
        headers+=(-H "X-API-KEY: $UNIFI_API_KEY")
    elif [ -n "$CSRF_TOKEN" ]; then
        headers+=(-H "X-CSRF-Token: $CSRF_TOKEN")
    fi

    local url="$UNIFI_HOST/proxy/network/api/s/$UNIFI_SITE/$endpoint"

    if [ "$AUTH_MODE" = "apikey" ]; then
        # API key mode: no cookies needed
        local ssl_opt=""
        if [ "$VERIFY_SSL" = "false" ]; then ssl_opt="-k"; fi
        if [ -n "$data" ]; then
            curl -s -S $ssl_opt "${headers[@]}" -X "$method" -d "$data" "$url" 2>/dev/null
        else
            curl -s -S $ssl_opt "${headers[@]}" -X "$method" "$url" 2>/dev/null
        fi
    else
        # Cookie-based session mode
        if [ -n "$data" ]; then
            curl "${CURL_OPTS[@]}" "${headers[@]}" -X "$method" -d "$data" "$url" 2>/dev/null
        else
            curl "${CURL_OPTS[@]}" "${headers[@]}" -X "$method" "$url" 2>/dev/null
        fi
    fi
}

download_and_parse_lists() {
    log "Downloading DoH IP lists..."
    local all_ips=""

    for list_url in $DOH_LISTS; do
        log "  Fetching: $list_url"
        local list_content
        list_content=$(curl -s -S -L "$list_url" 2>/dev/null || true)

        if [ -z "$list_content" ]; then
            log "  WARNING: Failed to download $list_url, skipping"
            continue
        fi

        # Parse IPs: strip comments, whitespace, and empty lines
        # The dibdot format is: IP_ADDRESS  # comment
        local parsed
        parsed=$(echo "$list_content" | \
            sed 's/#.*//' | \
            awk '{print $1}' | \
            grep -v '^$' | \
            grep -E '^[0-9a-fA-F.:]+$' || true)

        local count
        count=$(echo "$parsed" | grep -c . || echo 0)
        log "  Parsed $count IPs from $list_url"

        if [ -n "$parsed" ]; then
            all_ips="$all_ips"$'\n'"$parsed"
        fi
    done

    # Deduplicate and sort
    echo "$all_ips" | grep -v '^$' | sort -u
}

get_firewall_groups() {
    api_call GET "rest/firewallgroup"
}

find_group_id() {
    local groups_json="$1"
    local group_name="$2"

    echo "$groups_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for group in data.get('data', []):
    if group.get('name') == '$group_name':
        print(group['_id'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null || echo ""
}

get_current_members() {
    local groups_json="$1"
    local group_name="$2"

    echo "$groups_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for group in data.get('data', []):
    if group.get('name') == '$group_name':
        for member in group.get('group_members', []):
            print(member)
        sys.exit(0)
" 2>/dev/null || echo ""
}

create_firewall_group() {
    local group_name="$1"
    local members_json="$2"
    local group_type="${3:-address-group}"

    log "Creating firewall group '$group_name' (type: $group_type)..."

    local payload
    payload=$(python3 -c "
import json
members = json.loads('$members_json')
print(json.dumps({
    'name': '$group_name',
    'group_type': '$group_type',
    'group_members': members
}))
")

    local response
    response=$(api_call POST "rest/firewallgroup" "$payload")

    if echo "$response" | grep -q '"rc":"ok"' 2>/dev/null || echo "$response" | grep -q '"_id"' 2>/dev/null; then
        log "Firewall group '$group_name' created successfully"
    else
        log "ERROR: Failed to create firewall group"
        log "Response: $response"
        exit 1
    fi
}

update_firewall_group() {
    local group_id="$1"
    local members_json="$2"

    log "Updating firewall group (ID: $group_id)..."

    local payload
    payload=$(python3 -c "
import json
members = json.loads('$members_json')
print(json.dumps({
    'group_members': members
}))
")

    local response
    response=$(api_call PUT "rest/firewallgroup/$group_id" "$payload")

    if echo "$response" | grep -q '"rc":"ok"' 2>/dev/null || echo "$response" | grep -q '"_id"' 2>/dev/null; then
        log "Firewall group updated successfully"
    else
        log "ERROR: Failed to update firewall group"
        log "Response: $response"
        exit 1
    fi
}

run_update() {
    validate_config

    # Download and parse IP lists
    local ip_list
    ip_list=$(download_and_parse_lists)

    local total_ips
    total_ips=$(echo "$ip_list" | grep -c . 2>/dev/null || echo "0")
    total_ips="${total_ips//[[:space:]]/}"
    log "Total unique IPs to block: $total_ips"

    if [ "$total_ips" -eq 0 ]; then
        log "ERROR: No IPs downloaded, aborting to avoid clearing existing rules"
        exit 1
    fi

    # Separate IPv4 and IPv6 addresses
    local ipv4_list ipv6_list
    ipv4_list=$(echo "$ip_list" | grep -E '^[0-9]+\.' || true)
    ipv6_list=$(echo "$ip_list" | grep -E '^[0-9a-fA-F]*:' || true)

    local ipv4_count ipv6_count
    ipv4_count=$(echo "$ipv4_list" | grep -c . 2>/dev/null || echo "0")
    ipv6_count=$(echo "$ipv6_list" | grep -c . 2>/dev/null || echo "0")
    # Trim whitespace for safe integer comparison
    ipv4_count="${ipv4_count//[[:space:]]/}"
    ipv6_count="${ipv6_count//[[:space:]]/}"
    log "IPv4 addresses: $ipv4_count, IPv6 addresses: $ipv6_count"

    # Convert to JSON arrays
    local members_json_v4="[]"
    if [ "$ipv4_count" -gt 0 ]; then
        members_json_v4=$(echo "$ipv4_list" | python3 -c "
import sys, json
ips = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(ips))
")
    fi

    local members_json_v6="[]"
    if [ "$ipv6_count" -gt 0 ]; then
        members_json_v6=$(echo "$ipv6_list" | python3 -c "
import sys, json
ips = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(ips))
")
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log "DRY RUN: Would update group '$FIREWALL_GROUP' with $ipv4_count IPv4 IPs"
        if [ "$IPV6_ENABLED" = "true" ]; then
            log "DRY RUN: Would update group '$FIREWALL_GROUP_V6' with $ipv6_count IPv6 IPs"
        fi
        log "First 10 IPv4 IPs:"
        echo "$ipv4_list" | head -10
        return 0
    fi

    # Authenticate (API key mode skips login)
    if [ "$AUTH_MODE" = "credentials" ]; then
        unifi_login
    fi

    # Get existing firewall groups
    local groups_json
    groups_json=$(get_firewall_groups)

    # --- Update/create IPv4 group ---
    if [ "$ipv4_count" -gt 0 ]; then
        local group_id
        group_id=$(find_group_id "$groups_json" "$FIREWALL_GROUP")

        if [ -n "$group_id" ]; then
            local current_members
            current_members=$(get_current_members "$groups_json" "$FIREWALL_GROUP")
            local current_count
            current_count=$(echo "$current_members" | grep -c . || echo 0)
            log "IPv4 group: current $current_count IPs -> new $ipv4_count IPs"
            update_firewall_group "$group_id" "$members_json_v4"
        else
            log "Firewall group '$FIREWALL_GROUP' not found, creating it..."
            create_firewall_group "$FIREWALL_GROUP" "$members_json_v4" "address-group"
        fi
    fi

    # --- Update/create IPv6 group ---
    if [ "$IPV6_ENABLED" = "true" ] && [ "$ipv6_count" -gt 0 ]; then
        local group_id_v6
        group_id_v6=$(find_group_id "$groups_json" "$FIREWALL_GROUP_V6")

        if [ -n "$group_id_v6" ]; then
            local current_members_v6
            current_members_v6=$(get_current_members "$groups_json" "$FIREWALL_GROUP_V6")
            local current_count_v6
            current_count_v6=$(echo "$current_members_v6" | grep -c . || echo 0)
            log "IPv6 group: current $current_count_v6 IPs -> new $ipv6_count IPs"
            update_firewall_group "$group_id_v6" "$members_json_v6"
        else
            log "Firewall group '$FIREWALL_GROUP_V6' not found, creating it..."
            create_firewall_group "$FIREWALL_GROUP_V6" "$members_json_v6" "ipv6-address-group"
        fi
    fi

    if [ "$AUTH_MODE" = "credentials" ]; then
        unifi_logout
    fi
    log "Done! Updated $ipv4_count IPv4 IPs in '$FIREWALL_GROUP'"
    if [ "$IPV6_ENABLED" = "true" ] && [ "$ipv6_count" -gt 0 ]; then
        log "Updated $ipv6_count IPv6 IPs in '$FIREWALL_GROUP_V6'"
    fi
    log ""
    log "REMINDER: Ensure you have firewall rules that use these groups"
    log "  to DROP/REJECT traffic on ports 443 and 853 (DoH and DoT)"
}

# --- Main ---
if [ "${1:-}" = "--cron" ]; then
    CRON_SCHEDULE="${CRON_SCHEDULE:-0 4 * * *}"
    log "Running in cron mode with schedule: $CRON_SCHEDULE"
    log "Writing crontab..."

    # Write env vars to file for cron to source
    env | grep -E '^(UNIFI_|FIREWALL_|DOH_|IPV6_|DRY_|VERIFY_)' > /etc/environment 2>/dev/null || true

    echo "$CRON_SCHEDULE /app/update-doh-blocklist.sh >> /proc/1/fd/1 2>&1" | crontab -
    log "Cron scheduled. Running initial update..."
    run_update
    log "Entering cron loop..."
    exec crond -f -l 2
else
    run_update
fi
