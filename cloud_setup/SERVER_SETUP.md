# Server Setup

## Security
### Overview
Access to the server instance is locked down to the Tailscale VPN. A Cloud Firewall restricts all inbound traffic to only what Tailscale requires, preventing any direct public access to the server or its services. UFW running on the server instance additionally blocks inbound traffic, providing a layer of defense in depth in case of misconfiguration.

Note that all outbound ports are open, to facilitate cloudflared, tailscale, and updates. See (Further Security Enhancements)

Cloudflare Tunnels are used to access individual services, and must be protected with sufficent Cloudflare Access policies to control access. SSO and MFA is recommended.

NOTE: Open SSH is disabled, tailscale-ssh is only be available over Tailscale. Appropriate user Tailscale ACLs should be implemented there to prevent privelege escalation. Assuming the keys are kept confidential, this presents a very small attack surface to the wide web.

Emergency access is available via the Cloud's VNC to fix any tailscale misconfiguration.

#### Further Security Enhancements (Out of Scope)
To further secure this instance, a layer 7 traffic inspection firewall policy should be implemented to prevent data exfiltration in the event of a compromise on outbound ports. Due to the ability to tunnel outbound traffic over http/https and similar ports that need to be left open, this presents little additional protection, unless a layer 7 firewall is utilized.

### Administering the Server
All server administration is done over the Tailscale network. Install the Tailscale client on any device you want to administer the server from:

- **macOS:** https://tailscale.com/download/macos
- **Android/iOS:** Available in respective app stores (optional; but not recommended)

Services running on the server (e.g. Komodo) are accessed directly over the Tailscale network via MagicDNS hostname. No public ports are exposed for services. UFW restricts the necessary ports on the server instance to the tailscale interface. If additional administrative applications are required, ports should be restricted via UFW to the `tailscale0` interface. No additional ports should be opened on the cloud firewall.

---

## Setup

### 1. Tailscale 
#### 1. Account

1. Sign up at [tailscale.com](https://tailscale.com) (Free tier is sufficient)
2. Install the client on your local machine
3. Enable the Tailscale network extension when prompted
4. Allow the VPN extension when prompted
5. Log in — your device should appear under **Devices** in the Tailscale admin console

#### 2. Tailnet hardening
https://login.tailscale.com/admin/settings/user-management
- Enable User Approval

https://login.tailscale.com/admin/settings/device-management
- Enable Device Approval

Further hardening of the tailnet should be done to prevent accidental access via ACLs to limit which machines/users on the tailnet can access the server; Out of scope.

#### 3. Tailscale Auth Key

The server authenticates to Tailscale automatically on first boot using an auth key.

https://login.tailscale.com/admin/settings/keys
1. Go to the Tailscale admin console → **Settings** → **Keys**
2. Generate an **Auth Key**
3. Copy the key — it goes into the cloud-config as `<tailscale-auth-key>`

##### Key Exiry
Recovery instructions if key expires:
https://tailscale.com/docs/features/access-control/key-expiry

By default, keys will expire after 90 days. 
For less security, but easier administration, this can be disabled.
https://tailscale.com/docs/features/access-control/key-expiry#disabling-key-expiry

This should allow for specifying a new key, and re-authenticating by generating a new `<tailscale-auth-key>`
`tailscale logout && tailscale up --authkey tskey-auth-XXXXXX`

### 2. SSH Key

> Not required — the server has no public SSH access. All access is via Tailscale SSH.
>
> If you want an emergency fallback, use the Hetzner/Oracle rescue console.

### 3. Cloud Config - Oracle (Alternatively, see Hetzner "Alternative Cloud - Hetzner")
https://www.oracle.com/ca-en/cloud/free


#### 1. Cloud Firewall

Create a firewall policy with the following inbound rules before provisioning the server.

| Rule Name | Protocol | Port | Notes |
|---|---|---|---|
| Tailscale | UDP | 41641 | Direct peer connections. Falls back to DERP relay if blocked. |

> **Note:** DERP relay (port 443) and STUN (port 3478) are outbound-only — Hetzner does not need inbound rules for them. There is no public SSH rule; all access is via Tailscale.

**Policy name:** `Tailscale Firewall`

#### 2. Cloud Instance

### 6. Cloud Config

Replace the placeholder values before pasting into the server instance cloud-config field.

| Placeholder | Value |
|---|---|
| `<tailscale-auth-key>` | Auth key from Tailscale admin console (Step 3) |
| `<tailscale-hostname>` | MagicDNS hostname assigned by Tailscale (visible in Tailscale admin after first boot) |
| `<mongo-password>` | Random strong password — `openssl rand -hex 32` |
| `<secret-key>` | Random string — run `openssl rand -hex 32` |
| `<server-name>` | Display name for this server in Komodo (e.g. `agent-0`) — fill in after first boot |
| `<onboarding-key>` | Generated in Komodo UI after first boot — see Step 8 |

> `<tailscale-hostname>` and the Periphery placeholders (`<server-name>`, `<onboarding-key>`) cannot be known before provisioning. Fill them in via Tailscale SSH after the server is online.

```yaml
#cloud-config
users:
  - name: cloud_user
    groups: users, admin, docker
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

packages:
  - ufw
  - curl
  - unattended-upgrades
  - apt-transport-https
  - ca-certificates
  - gnupg
package_update: true
package_upgrade: true

write_files:
  # Uncomment to enable this server as a Tailscale exit node.
  # Also requires approval in the Tailscale admin console after boot:
  # https://login.tailscale.com/admin/machines
  # - path: /etc/sysctl.d/99-tailscale.conf
  #   content: |
  #     net.ipv4.ip_forward=1
  #     net.ipv6.conf.all.forwarding=1

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";

  - path: /opt/komodo/docker-compose.yml
    content: |
      services:
        komodo-mongo:
          image: mongo:latest
          restart: unless-stopped
          volumes:
            - komodo-mongo-data:/data/db
          environment:
            MONGO_INITDB_ROOT_USERNAME: komodo
            MONGO_INITDB_ROOT_PASSWORD: <mongo-password>

        komodo-core:
          image: ghcr.io/mbecker20/komodo:latest
          restart: unless-stopped
          depends_on:
            - komodo-mongo
          ports:
            - "9120:9120"
          environment:
            KOMODO_HOST: http://<tailscale-hostname>:9120
            KOMODO_SECRET_KEY: <secret-key>
            KOMODO_DATABASE_URI: mongodb://komodo:<mongo-password>@komodo-mongo:27017/komodo?authSource=admin
            KOMODO_DATABASE_DB_NAME: komodo
            KOMODO_LOCAL_AUTH: "true"

        komodo-periphery:
          image: ghcr.io/moghtech/komodo-periphery:2
          init: true
          restart: unless-stopped
          depends_on:
            - komodo-core
          environment:
            PERIPHERY_CORE_ADDRESS: http://komodo-core:9120
            PERIPHERY_CONNECT_AS: <server-name>
            PERIPHERY_ONBOARDING_KEY: <onboarding-key>
            PERIPHERY_ROOT_DIRECTORY: /etc/komodo
            PERIPHERY_INCLUDE_DISK_MOUNTS: /etc/hostname
          volumes:
            - periphery-keys:/config/keys
            - /var/run/docker.sock:/var/run/docker.sock
            - /proc:/proc
            - /etc/komodo:/etc/komodo

      volumes:
        komodo-mongo-data:
        periphery-keys:

runcmd:
  # Disable openssh — emergency access via provider VNC console only
  - systemctl disable --now ssh || true
  - systemctl mask ssh

  # Install Tailscale
  - curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
  - curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list

  # Install Docker CE
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  - apt-get update -y
  - apt-get install -y tailscale docker-ce docker-ce-cli containerd.io docker-compose-plugin

  - systemctl enable --now tailscaled
  - systemctl enable --now docker

  # Start Komodo
  - docker compose -f /opt/komodo/docker-compose.yml up -d

  # UFW rules
  # Tailscale direct peer connections (falls back to DERP relay if blocked)
  - ufw allow 41641/udp
  # Tailscale SSH — Tailscale network only
  - ufw allow in on tailscale0 to any port 22
  # Komodo web UI — Tailscale network only
  - ufw allow in on tailscale0 to any port 9120
  - ufw enable

  # Authenticate Tailscale with SSH enabled
  # To also advertise as an exit node, uncomment the two lines below and comment out the one above:
  # - sysctl -p /etc/sysctl.d/99-tailscale.conf
  # - tailscale up --ssh --advertise-exit-node --authkey=<tailscale-auth-key>
  - tailscale up --ssh --authkey=<tailscale-auth-key>
  - reboot
```

### 7. Post-Provisioning

**Verify the node is online** (from your local machine):

```bash
tailscale status
```

The server should appear with a MagicDNS hostname (e.g. `hellscrew`).

**SSH into the server:**

```bash
ssh cloud_user@hellscrew
```

**Fill in the hostname placeholder** — replace `hellscrew` with your actual Tailscale hostname:

```bash
HOSTNAME="hellscrew"
sed -i "s/<tailscale-hostname>/${HOSTNAME}/g" /opt/komodo/docker-compose.yml
docker compose -f /opt/komodo/docker-compose.yml up -d komodo-core
```

**Access Komodo:**

Open `http://hellscrew:9120` in a browser on any device connected to your Tailscale network. Register the first user — they get admin rights automatically.

### 8. Connect the Server to Komodo (Periphery)

Periphery is an agent that lets Komodo manage servers. It connects outbound to Core over the Docker network — no extra firewall rules needed.

**Step 1 — Create an Onboarding Key in Komodo:**

1. Log into Komodo
2. Go to **Settings → Server Onboarding Keys**
3. Create a new key and copy it

**Step 2 — Fill in the Periphery placeholders on the server:**

```bash
SERVER_NAME="agent-0"
ONBOARDING_KEY="tskey-onboard-XXXXX"

sed -i "s/<server-name>/${SERVER_NAME}/g" /opt/komodo/docker-compose.yml
sed -i "s/<onboarding-key>/${ONBOARDING_KEY}/g" /opt/komodo/docker-compose.yml

docker compose -f /opt/komodo/docker-compose.yml up -d komodo-periphery
docker compose -f /opt/komodo/docker-compose.yml logs -f komodo-periphery
```

The server will appear under **Servers** in the Komodo UI within seconds.

> Once registered, `PERIPHERY_ONBOARDING_KEY` can be removed from the compose file — it is only needed for the initial connection.

## Alternative Cloud - Hetzner
In place of Oracle Cloud, create an instance with Hetzner. Ensure the Firewall is setup correctly 
### 5. Hetzner Server (Obsolete; Use Oracle Cloud)

Create the server with these settings:

| Setting | Value |
|---|---|
| Type | Regular Performance (CPX11) |
| Location | US-West |
| Image | Ubuntu 24.04 |
| Volume | 10 GB (US-West), name: `agent-0-vol` |
| Networking | IPv4 + IPv6 |
| SSH Key | Optional — emergency fallback only |
| Firewall | Tailscale Firewall |
| Backups | Enabled |