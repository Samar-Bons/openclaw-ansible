# Sigil AI — Mac Mini Deployment Ansible Playbook Spec

## Context: Why This Exists

### The Business
**Sigil AI** is a white-glove AI deployment company targeting contractors and small businesses (plumbers, renovators, electricians, solar installers) in the Dallas-Fort Worth metroplex, expanding nationally.

**The product:** A physical "AI-in-a-box" — a Mac Mini running OpenClaw (open-source AI agent framework) with bundled phone answering, iMessage integration, lead capture, and business automation. Clients pay $399-599/mo for an always-on AI employee that answers their phone, responds to texts, captures leads, and never sleeps.

**The client profile:**
- Non-technical contractors and tradespeople
- They will NEVER SSH into anything or edit a config file
- They care that it works, not how it works
- Their customers text them on iMessage (iPhone-dominant market in luxury home services)
- They get 10-50+ calls/day and miss most of them
- They're willing to pay premium ($500+/mo) for something that "just works"

### Why Mac Mini
- **iMessage is the killer feature.** Contractors' customers text them. iMessage requires Apple hardware — there is no Linux/Windows workaround. Period.
- **BlueBubbles** (open-source iMessage bridge) runs on macOS and integrates with OpenClaw via REST API + webhooks.
- **The iPhone SE** paired with each Mac Mini registers a phone number with iMessage. The Mac Mini runs BlueBubbles to bridge messages to OpenClaw.
- **Voice calls** route through Twilio → OpenAI Realtime API → OpenClaw (the Mac Mini handles the AI brain, Twilio handles telephony).
- **No cloud dependency.** The box sits at the client's office or Sigil's operations center. Client data stays local. This is a selling point for privacy-conscious contractors.

### Why Headless
These Mac Minis will:
- Sit in a closet/shelf with just power + ethernet
- Run 24/7/365 with no monitor, keyboard, or mouse attached
- Be managed remotely via Tailscale SSH
- Auto-recover from power outages
- Be deployed by Sigil staff running a single Ansible command, not by the client

### Why Ansible (Not a Shell Script)
- **Idempotency.** Run it twice, get the same result. Critical when debugging a partially-configured machine.
- **Inventory.** As the fleet grows (10, 50, 100 Mac Minis), Ansible can target groups of machines.
- **Variables.** Each client gets different: phone number, business name, SOUL.md personality, API keys. Ansible vars handle this cleanly.
- **Auditability.** Every change is a tracked task with a name. When something breaks at 2 AM, you know exactly what was configured and where to look.
- **Existing foundation.** The official `openclaw/openclaw-ansible` playbook has tested Linux roles. We forked it and are restoring + extending macOS support that was removed 9 days ago.

---

## Current State of the Fork

**Repo:** `github.com/Samar-Bons/openclaw-ansible`  
**Branch:** `feat/restore-macos-support`  
**Base:** Forked from `openclaw/openclaw-ansible` (commit `badcb65`)

### What Was Done
1. **Restored macOS task files** deleted in commit `6a1e762` (Feb 10, 2026):
   - `system-tools-macos.yml` — Homebrew-based tool installation
   - `tailscale-macos.yml` — Tailscale via Homebrew cask
   - `docker-macos.yml` — Docker Desktop (optional, disabled by default)
   - `firewall-macos.yml` — macOS Application Firewall

2. **Merged 9 days of post-deletion enhancements** into macOS paths:
   - `tailscale_enabled` flag (Tailscale now optional)
   - `ci_test` mode (skips systemd/Docker for testing)
   - Idempotent pnpm config
   - `.bash_profile` sourcing `.bashrc` for login shells
   - Interface validation for firewall rules
   - Canonical `authorized_key` FQCN

3. **Added new macOS-specific hardening** (`hardening-macos.yml`):
   - Energy/sleep: prevent sleep, wake on LAN, auto-restart on power failure
   - AirDrop + Bluetooth disabled
   - SSH + Screen Sharing enabled
   - macOS auto-updates disabled (protects BlueBubbles from breaking API changes)
   - Auto-login for headless operation
   - FileVault disk encryption check
   - `poke-messages` LaunchAgent (keeps Messages.app alive for BlueBubbles)

4. **Updated cross-platform files:**
   - `main.yml` — OS-routed task inclusion
   - `user.yml` — macOS user via `sysadminctl`, zsh config, macOS-scoped sudoers
   - `nodejs.yml` — Homebrew Node.js path
   - `openclaw-release.yml` / `openclaw-development.yml` — Homebrew in PATH
   - `playbook.yml` — removed Darwin fail block, Homebrew prerequisite check
   - `defaults/main.yml` — macOS variables

---

## What Needs To Be Built / Verified

### Critical Missing Pieces

#### 1. BlueBubbles Installation & Configuration
**Status:** NOT in the playbook yet.  
**Why it matters:** BlueBubbles is the bridge between iMessage and OpenClaw. Without it, the Mac Mini can't receive or send iMessages.

**Requirements:**
- Install BlueBubbles server (download from bluebubbles.app or Homebrew cask if available)
- Grant macOS permissions: Full Disk Access, Automation (Messages.app), Accessibility
- Enable Private API (for typing indicators, tapbacks, read receipts)
- Configure API password
- Set up webhook URL pointing to OpenClaw gateway
- **Problem:** macOS TCC (Transparency, Consent, and Control) permissions cannot be granted via command line on modern macOS without MDM profiles or manual GUI interaction. This may require a one-time manual step or a TCC profile.

**Suggested approach:**
- Create `bluebubbles-macos.yml` task file
- Install the app
- Generate a TCC configuration profile (`.mobileconfig`) that pre-grants Full Disk Access and Automation permissions to BlueBubbles
- OR: document the manual permission grants as a required post-install step
- Configure the API via BlueBubbles' REST API or config file

#### 2. OpenClaw Configuration Templating
**Status:** NOT in the playbook. The current playbook installs OpenClaw but explicitly does NOT create `openclaw.json` — it defers to `openclaw onboard`.  
**Why it matters:** For fleet deployment, we can't run an interactive wizard on each machine. We need templated configs.

**Requirements:**
- Jinja2 template for `openclaw.json` with variables for:
  - `client_name` — used in SOUL.md and greeting
  - `client_phone` — Tello number registered with iMessage
  - `twilio_number` — public-facing business phone number
  - `twilio_sid`, `twilio_auth` — Twilio credentials
  - `anthropic_api_key` — model provider
  - `openai_api_key` — for Realtime voice API
  - `bluebubbles_password` — API auth
  - `telegram_bot_token` — admin channel (optional)
  - `telegram_admin_id` — Samar's Telegram for alerts
- Template for `SOUL.md` — client-specific personality (business name, services, location, response style)
- Template for `AGENTS.md` — workspace conventions
- Template for `MEMORY.md` — initial long-term memory seed

**Suggested approach:**
- Create `roles/openclaw/templates/openclaw.json.j2`
- Create `roles/openclaw/templates/soul.md.j2`
- Create `roles/openclaw/templates/agents.md.j2`
- New task file: `openclaw-config.yml` that deploys these templates
- Store sensitive variables in Ansible Vault (encrypted)

#### 3. OpenClaw Daemon (launchd) Setup
**Status:** Partially handled. OpenClaw's `openclaw daemon install` creates a LaunchAgent, but we need to verify it works headless and survives reboot.  
**Why it matters:** The gateway must auto-start on boot without user interaction.

**Requirements:**
- Verify `openclaw daemon install` creates a proper LaunchAgent (not LaunchDaemon — LaunchAgents run in user context, which is needed for Messages.app access)
- Verify it starts on login (which is automatic due to auto-login setting)
- Verify it restarts on crash (check for `KeepAlive` key in plist)
- If `openclaw daemon install` doesn't handle all this, create our own LaunchAgent plist

**Suggested approach:**
- Run `openclaw daemon install` via Ansible
- Then verify/patch the generated plist to ensure `KeepAlive`, `RunAtLoad`, and proper environment variables
- Create `openclaw-daemon-macos.yml` task file

#### 4. Tunnel / Public URL for Webhooks
**Status:** NOT in the playbook.  
**Why it matters:** Twilio voice webhooks and BlueBubbles (if remote) need a public URL to reach the Mac Mini.

**Options:**
- **Tailscale Funnel** — stable URL via `*.ts.net`, no third-party dependency. Requires Tailscale account.
- **Cloudflare Tunnel** — custom domain, production-grade. Requires Cloudflare account + domain.
- **ngrok** — quick but unstable for production (free tier URLs change on restart).

**Suggested approach:**
- Default to Tailscale Funnel (already installing Tailscale)
- Create `tunnel-macos.yml` that configures `tailscale funnel <port>` as a LaunchAgent
- Make tunnel provider configurable via variable (`tunnel_provider: tailscale | cloudflare | ngrok`)

#### 5. Cron Jobs / Heartbeat Setup
**Status:** NOT in the playbook.  
**Why it matters:** The AI agent needs scheduled tasks: memory flush before session reset, health monitoring, nightly updates.

**Requirements (minimum for every instance):**
- Pre-reset memory flush (3:50 AM daily) — prevents memory loss on session reset
- Nightly OpenClaw auto-update (3:00 AM daily)
- Health check (every 30 min) — alerts Samar on Telegram if unhealthy
- Morning briefing (optional, for Sigil's own instance)

**Suggested approach:**
- Create `openclaw-cron.yml` task file
- Use OpenClaw's CLI or API to create cron jobs after the gateway starts
- Define cron jobs as Ansible variables (list of objects: name, schedule, payload)
- Wait for gateway to be healthy before creating cron jobs

#### 6. iPhone SE Validation
**Status:** NOT in the playbook (and probably shouldn't be — the iPhone is a separate device).  
**Why it matters:** The iPhone must be correctly configured for iMessage registration and SMS relay.

**Suggested approach:**
- Don't automate iPhone setup (it's a physical device with touch UI)
- Instead, create a verification task that checks:
  - Can BlueBubbles reach Messages.app?
  - Is the phone number registered in iMessage?
  - Is Text Message Forwarding active?
- Create `verify-imessage.yml` that runs these checks post-setup

### Things To Reconsider

#### 7. User Account Strategy
**Current approach:** Create a dedicated `openclaw` user via `sysadminctl`, or use an existing admin account via `openclaw_macos_user` variable.

**Problem:** On a dedicated Mac Mini, creating a separate user adds complexity:
- LaunchAgents only run in the logged-in user's context
- Messages.app and Apple ID are per-user
- Auto-login can only auto-login one user
- If the `openclaw` user is different from the Apple ID user, Messages.app won't have the right conversations

**Better approach for dedicated machines:**
- Default to using the primary admin account (the one created during macOS setup)
- Set `openclaw_macos_user` to that account name
- This simplifies everything: one user, one Apple ID, one Messages.app, one set of LaunchAgents
- The security tradeoff (running as admin) is acceptable because this is a single-purpose appliance

#### 8. macOS Version Pinning
**Current approach:** Disable auto-updates.  
**Problem:** Doesn't prevent manual updates. Doesn't tell us which macOS version is running.

**Better approach:**
- Detect macOS version at playbook start
- Warn if running macOS Tahoe (26) — BlueBubbles edit action is broken on Tahoe
- Recommend macOS Sequoia (15) as the tested/blessed version
- Add a variable `macos_target_version` for documentation purposes

#### 9. Monitoring & Alerting
**Current approach:** Health check cron job inside OpenClaw.  
**Problem:** If OpenClaw itself is down, its cron jobs don't fire.

**Better approach — layered monitoring:**
- **Layer 1:** OpenClaw internal health check cron (catches agent issues)
- **Layer 2:** External LaunchAgent that checks if OpenClaw gateway is responding (catches OpenClaw crashes)
- **Layer 3:** Tailscale heartbeat — if the machine goes offline from the Tailnet, Samar gets notified
- Create `monitoring-macos.yml` with a LaunchAgent that `curl`s the gateway health endpoint every 5 minutes and sends a Telegram alert if it fails

#### 10. Backup & Recovery
**Status:** Not addressed.  
**Why it matters:** If a Mac Mini dies, we need to deploy a replacement fast.

**Requirements:**
- Back up: `~/.openclaw/` (config, sessions, credentials), workspace (SOUL.md, memory/, leads/)
- Restore: new Mac Mini + Ansible playbook + backup = identical instance in <1 hour
- Consider: Time Machine to external drive or network, or rsync to a backup server via Tailscale

**Suggested approach:**
- Create `backup-macos.yml` that sets up a daily rsync cron to a Tailscale-accessible backup destination
- Define `backup_destination` variable (Tailscale IP or hostname)
- Include in the playbook as an optional role

---

## Verification Checklist (Post-Deployment)

The playbook should include a verification phase that runs after all setup is complete. Create `verify-macos.yml`:

```yaml
# All of these must pass for a deployment to be considered successful
checks:
  - name: "OpenClaw gateway is running"
    test: "curl -sf http://localhost:18789/health"
    
  - name: "OpenClaw version is current"
    test: "openclaw --version"
    
  - name: "BlueBubbles server is responding"
    test: "curl -sf http://localhost:1234/api/v1/ping?password=<password>"
    
  - name: "Messages.app is running"
    test: "pgrep -x Messages"
    
  - name: "poke-messages LaunchAgent is loaded"
    test: "launchctl list | grep com.sigil.poke-messages"
    
  - name: "Tailscale is connected"
    test: "tailscale status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"Self\"][\"Online\"]'"
    
  - name: "Firewall is enabled"
    test: "socketfilterfw --getglobalstate | grep enabled"
    
  - name: "SSH is enabled"
    test: "systemsetup -getremotelogin | grep On"
    
  - name: "Auto-restart on power failure"
    test: "pmset -g | grep autorestart | grep 1"
    
  - name: "Sleep is disabled"
    test: "pmset -g | grep '^ sleep' | grep 0"
    
  - name: "macOS auto-updates are disabled"
    test: "defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload | grep 0"
    
  - name: "SOUL.md exists and is non-empty"
    test: "test -s ~/workspace/SOUL.md"
    
  - name: "OpenClaw config exists"
    test: "test -s ~/.openclaw/openclaw.json"
    
  - name: "Reboot resilience"
    manual: "Reboot the Mac Mini, wait 2 minutes, verify all above checks pass again"
```

---

## File Structure (Target)

```
roles/openclaw/
├── defaults/
│   └── main.yml                    # All variables with defaults
├── tasks/
│   ├── main.yml                    # Orchestrator (OS routing)
│   ├── system-tools.yml            # OS router → linux/macos
│   ├── system-tools-linux.yml      # apt-based tools
│   ├── system-tools-macos.yml      # Homebrew-based tools [RESTORED]
│   ├── tailscale-linux.yml         # Tailscale via apt
│   ├── tailscale-macos.yml         # Tailscale via cask [RESTORED]
│   ├── user.yml                    # User creation (OS-aware)
│   ├── docker-linux.yml            # Docker CE via apt
│   ├── docker-macos.yml            # Docker Desktop [RESTORED, optional]
│   ├── firewall-linux.yml          # UFW + fail2ban
│   ├── firewall-macos.yml          # Application Firewall [RESTORED]
│   ├── hardening-macos.yml         # Headless Mac Mini hardening [NEW]
│   ├── nodejs.yml                  # Node.js (OS-aware)
│   ├── openclaw.yml                # OpenClaw install orchestrator
│   ├── openclaw-release.yml        # npm/pnpm install
│   ├── openclaw-development.yml    # git clone + build
│   ├── openclaw-config.yml         # Config templating [TO BUILD]
│   ├── openclaw-daemon-macos.yml   # LaunchAgent setup [TO BUILD]
│   ├── bluebubbles-macos.yml       # BlueBubbles install + config [TO BUILD]
│   ├── tunnel-macos.yml            # Public URL tunnel [TO BUILD]
│   ├── openclaw-cron.yml           # Cron jobs setup [TO BUILD]
│   ├── monitoring-macos.yml        # External health monitoring [TO BUILD]
│   ├── backup-macos.yml            # Backup configuration [TO BUILD]
│   └── verify-macos.yml            # Post-deployment verification [TO BUILD]
├── templates/
│   ├── openclaw.json.j2            # OpenClaw config template [TO BUILD]
│   ├── soul.md.j2                  # Client personality template [TO BUILD]
│   ├── agents.md.j2                # Workspace conventions template [TO BUILD]
│   ├── show-lobster.sh.j2          # ASCII art (existing)
│   └── openclaw-host.service.j2    # systemd service (Linux, existing)
├── files/
│   └── bluebubbles.mobileconfig    # TCC permission profile [TO BUILD, if feasible]
└── handlers/
    └── main.yml                    # Handlers for restarts etc.
```

---

## Variables Reference (Target)

```yaml
# === Required for every deployment ===
client_name: "Luxury Design and Renovations"  # Business name
client_phone: "+12145551234"                   # Tello number (iMessage)
twilio_number: "+12145555678"                  # Public business number (voice)
anthropic_api_key: "sk-ant-..."                # Claude API key
openai_api_key: "sk-proj-..."                  # OpenAI Realtime API key
bluebubbles_password: "strong-random-password"
openclaw_macos_user: "sigil"                   # macOS account to use
openclaw_macos_home: "/Users/sigil"

# === Optional ===
twilio_sid: "AC..."
twilio_auth: "..."
telegram_bot_token: "..."                      # Admin channel (optional)
telegram_admin_id: "1056533531"                # Samar's Telegram ID
tailscale_enabled: true
tailscale_authkey: "tskey-auth-..."            # For unattended Tailscale join
tunnel_provider: "tailscale"                   # tailscale | cloudflare | ngrok
backup_destination: "100.x.x.x:/backups"      # Tailscale IP of backup server
soul_template: "contractor"                    # Which SOUL.md template to use

# === Client SOUL.md variables ===
business_name: "Luxury Design and Renovations"
business_services: ["Custom sauna builds", "Kitchen remodeling", "Floor retiling", "Epoxy flooring"]
business_location: "Dallas-Fort Worth metroplex"
owner_name: "Abbas"
business_style: "professional but approachable"

# === macOS hardening (all have defaults) ===
macos_disable_bluetooth: true
macos_enable_screen_sharing: true
macos_auto_login: true
macos_target_version: "15"                     # Sequoia recommended
```

---

## How To Run (Target)

```bash
# Instance #0 (Sigil's own test instance)
ansible-playbook playbook.yml --ask-become-pass \
  -e @vars/sigil-instance-0.yml \
  -e @vault/sigil-instance-0.vault.yml --ask-vault-pass

# Client deployment (Abbas)
ansible-playbook playbook.yml --ask-become-pass \
  -e @vars/client-abbas.yml \
  -e @vault/client-abbas.vault.yml --ask-vault-pass

# Verify only (no changes)
ansible-playbook playbook.yml --tags verify \
  -e @vars/sigil-instance-0.yml
```

---

## Priority Order for Remaining Work

1. **OpenClaw config templating** (`openclaw-config.yml` + templates) — without this, every machine needs manual config
2. **BlueBubbles installation** (`bluebubbles-macos.yml`) — core product feature
3. **Verification suite** (`verify-macos.yml`) — proves the deployment works
4. **OpenClaw daemon** (`openclaw-daemon-macos.yml`) — survives reboots
5. **Cron jobs** (`openclaw-cron.yml`) — memory safety, health monitoring
6. **Tunnel setup** (`tunnel-macos.yml`) — voice calls need public URL
7. **Monitoring** (`monitoring-macos.yml`) — catch failures OpenClaw can't self-report
8. **Backup** (`backup-macos.yml`) — disaster recovery
