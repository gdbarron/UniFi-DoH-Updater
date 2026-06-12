# UniFi DoH Updater

Automatically downloads DNS-over-HTTPS (DoH) IP blocklists and updates a UniFi firewall group via the controller API. Prevents devices from bypassing your local DNS by reaching DoH resolvers directly.

Works with all UniFi OS gateways: UDM, UDM Pro, UDM SE, UCG Ultra, UCG Fiber, UDR, Dream Wall, etc.

## Quick Start (One-Off)

```bash
# Recommended: API key (generate in UniFi OS: Settings > Integrations > API Keys)
export UNIFI_HOST=https://192.168.1.1
export UNIFI_API_KEY=your_api_key_here

./update-doh-blocklist.sh
```

Or with username/password:

```bash
export UNIFI_HOST=https://192.168.1.1
export UNIFI_USER=admin
export UNIFI_PASS=yourpassword

./update-doh-blocklist.sh
```

## Docker (Scheduled)

A pre-built image is published to GitHub Container Registry on every push to `main`. You only need two files on your host:

1. Download [`docker-compose.yml`](docker-compose.yml)
2. Create a `.env` file:
   ```
   UNIFI_API_KEY=your_api_key_here
   ```
3. Edit `docker-compose.yml` — set `UNIFI_HOST` to your gateway IP
4. Run:
   ```bash
   docker compose up -d
   ```

The image is pulled from `ghcr.io/gdbarron/unifi-doh-updater:latest` — no build step, no git required. The container runs the update daily at 4:00 AM by default (change `CRON_SCHEDULE` to adjust).

**To update to latest version**:
```bash
docker compose pull && docker compose up -d
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `UNIFI_HOST` | Yes | - | Controller URL (e.g., `https://192.168.1.1`) |
| `UNIFI_API_KEY` | * | - | API key (recommended, stateless, no login needed) |
| `UNIFI_USER` | * | - | Controller username (if not using API key) |
| `UNIFI_PASS` | * | - | Controller password (if not using API key) |
| `UNIFI_SITE` | No | `default` | Site name |
| `FIREWALL_GROUP` | No | `DoH Servers` | IPv4 firewall group name |
| `FIREWALL_GROUP_V6` | No | `DoH Servers IPv6` | IPv6 firewall group name |
| `DOH_LISTS_V4` | No | dibdot `doh-ipv4.txt` | Space-separated URLs to IPv4 lists |
| `DOH_LISTS_V6` | No | dibdot `doh-ipv6.txt` | Space-separated URLs to IPv6 lists |
| `IPV6_ENABLED` | No | `false` | Also download IPv6 lists and create IPv6 group |
| `CRON_SCHEDULE` | No | `0 4 * * *` | Cron schedule (Docker mode only) |
| `DRY_RUN` | No | `false` | Print actions without making changes |
| `VERIFY_SSL` | No | `false` | Verify controller SSL certificate |

\* Provide either `UNIFI_API_KEY` alone, or both `UNIFI_USER` + `UNIFI_PASS`.

## Custom DoH Lists

By default, uses the [dibdot/DoH-IP-blocklists](https://github.com/dibdot/DoH-IP-blocklists) which is actively maintained and comprehensive. Override with any URL that provides one IP per line (comments with `#` are stripped):

```bash
export DOH_LISTS_V4="https://example.com/my-doh-ips.txt https://example.com/another-list.txt"
export DOH_LISTS_V6="https://example.com/my-v6-list.txt"
```

The script auto-separates downloaded IPs by address family, so mixed lists work fine — IPv4 addresses go to the v4 group and IPv6 to the v6 group.

## Firewall Rule Setup

After the script creates/updates the firewall group, you need a firewall rule to actually block the traffic. In the UniFi controller:

1. Go to **Settings → Firewall & Security → Firewall Rules**
2. Create a new rule:
   - **Type**: LAN Out (or Internet Out depending on your setup)
   - **Action**: Drop
   - **Source**: Any
   - **Destination**: IP Group → "DoH Servers"
   - **Port**: 443, 853
   - **Protocol**: TCP/UDP

This blocks outbound HTTPS (port 443) and DNS-over-TLS (port 853) to known DoH/DoT resolver IPs.

## Synology Container Manager

For Synology NAS running DSM 7.2+ with Container Manager (the successor to the Docker package):

1. **Create a project folder** on the NAS (e.g., `/docker/unifi-doh-updater/`) with just two files:

   **`docker-compose.yml`** — download from this repo or create with:
   ```yaml
   services:
     doh-updater:
       image: ghcr.io/gdbarron/unifi-doh-updater:latest
       container_name: unifi-doh-updater
       restart: unless-stopped
       command: ["--cron"]
       environment:
         - UNIFI_HOST=https://192.168.1.1
         - UNIFI_API_KEY=${UNIFI_API_KEY}
         - UNIFI_SITE=default
         - FIREWALL_GROUP=DoH Servers
         - FIREWALL_GROUP_V6=DoH Servers IPv6
         - CRON_SCHEDULE=0 4 * * *
         - IPV6_ENABLED=true
         - VERIFY_SSL=false
   ```

   **`.env`**:
   ```
   UNIFI_API_KEY=your_api_key_here
   ```

2. **Open Container Manager** → **Project** → **Create**
   - **Project name**: `unifi-doh-updater`
   - **Path**: Select the folder (e.g., `/docker/unifi-doh-updater`)
   - **Source**: Use the existing `docker-compose.yml` in the folder

3. **Review** the compose file in the editor — update `UNIFI_HOST` to your gateway's IP

4. Click **Next** → review the summary → **Done** (check "Start after creation")

Container Manager pulls the pre-built image from GHCR and starts the container. No git or build tools needed on the NAS. It will keep it running and restart after NAS reboots.

**Viewing logs**: Container Manager → select the container → **Log** tab. All output (including scheduled cron runs) goes to stdout/stderr.
```bash
# Or via SSH:
docker logs unifi-doh-updater
docker logs -f unifi-doh-updater  # follow
```

**Manual trigger**: Container Manager → select the container → **Terminal** → run:
```bash
/app/update-doh-blocklist.sh
```

**Updating to latest**: Container Manager → **Project** → select the project → **Action** → **Stop**, then **Pull** the image, then **Start**. Or via SSH:
```bash
cd /docker/unifi-doh-updater && docker compose pull && docker compose up -d
```

## How It Works

1. Downloads IP lists from configured URLs
2. Parses and deduplicates all IPs, separating IPv4 and IPv6
3. Authenticates via API key (stateless) or login session
4. Finds each firewall group by name (creates if missing)
5. Updates group members via PUT to `/proxy/network/api/s/{site}/rest/firewallgroup/{id}`
6. Creates separate `address-group` (IPv4) and `ipv6-address-group` (IPv6) types

## Dependencies

- `bash`, `curl`, `python3` (for JSON handling)
- All included in the Docker image (Alpine-based)

## Testing

Run with `DRY_RUN=true` to see what would happen without touching the controller:

```bash
DRY_RUN=true UNIFI_HOST=https://192.168.1.1 UNIFI_USER=x UNIFI_PASS=x ./update-doh-blocklist.sh
```
