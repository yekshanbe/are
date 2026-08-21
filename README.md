

  <div align="center">
  
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:0f2027,50:203a43,100:2c5364&height=180&section=header&text=X-UI%20Multi-Country%20Gateway&fontSize=38&fontColor=ffffff&animation=fad...
  
  <br/>
  
  ![Status](https://img.shields.io/badge/status-production--ready-brightgreen?style=for-the-badge)
  ![Port](https://img.shields.io/badge/public%20port-3000%20only-blue?style=for-the-badge)
  ![Countries](https://img.shields.io/badge/countries-10%20configurable-orange?style=for-the-badge)
  ![Panel](https://img.shields.io/badge/panel-3x--ui%20v3.5.0-purple?style=for-the-badge)
  
  <img src="https://readme-typing-svg.demolab.com?font=Fira+Code&size=18&duration=2600&pause=900&color=39D353&center=true&vCenter=true&width=700&lines=Single+public+port+%E2%80%94+everything+behind+ngin...
  
  </div>
  
  <br/>
  
  > **This revision fixes the root cause of the `address already in use` crash loop**: the "direct" (non-Tor) inbound and nginx were both trying to bind **8080** while nginx *also* listened on 3000 — on...
  
  ---
  
  ## 📐 Architecture
  
  ```mermaid
  flowchart LR
      subgraph Public["🌍 Public internet"]
          C[Client]
      end
  
      subgraph Container["Container — only port 3000 is exposed"]
          N["nginx :3000\n(the ONLY public bind)"]
          D["xray direct inbound\n127.0.0.1:8080"]
          P["3x-ui panel\n127.0.0.1:2053"]
  
          subgraph Countries["Per-country isolated stacks (verified only)"]
              direction TB
              I1["xray inbound /in1\n127.0.0.1:8081"] --> T1["Tor instance: de\nSOCKS 127.0.0.1:9052"]
              I2["xray inbound /in2\n127.0.0.1:8082"] --> T2["Tor instance: fr\nSOCKS 127.0.0.1:9053"]
          end
  
          N -->|"/"  "/direct"| D
          N -->|"/managepanel/"| P
          N -->|"/in1"| I1
          N -->|"/in2"| I2
      end
  
      C --> N
  ```
  
  <details>
  <summary><b>Why this fixes the "direct config doesn't work" problem</b> (click to expand)</summary>
  <br/>
  
  Before: `nginx` listened on `3000` **and** the xray direct inbound also tried to `listen 0.0.0.0:8080`. On a platform that only forwards **one** external port to your container, that second bind eithe...
  
  ```
  ERROR - XRAY: Failed to start: ... failed to listen on address: 0.0.0.0:8080
         ... bind: address already in use
  ```
  
  After: `nginx` is the **only** process bound to `0.0.0.0`, on port `3000`. The direct inbound binds `127.0.0.1:8080` (loopback-only) and nginx's `/` and `/direct` locations reverse-proxy to it. Every ...
  
  </details>
  
  ---
  
  ## ✨ What changed in this revision
  
  | Area | Before | After |
  |---|---|---|
  | **Public ports** | nginx on 3000 *and* direct xray inbound trying 8080 → crash loop | **Only port 3000** is public; direct inbound is `127.0.0.1:8080`, proxied by nginx |
  | **Country discovery** | Sequential, 1 provider timeout path, up to 15 retries × (10s + 15s) sleeps ≈ minutes per country | **Parallel across all countries**, 4 geo-IP providers + 5 IP-echo services ...
  | **Failed countries** | Mostly already excluded, but inconsistently | **Single source of truth** (`is_location_verified()`): a failed country gets **no** inbound, **no** client, **no** outbound, **no...
  | **Naming in panel** | Inbound tags/remarks were `Tor-Germany`, outbound tag `tor-de` | Tags/remarks use **only the country** — `Germany` / `de`. The word "Tor" never appears in any inbound, client, ...
  | **IP rotation** | Rotator existed but was a single hardcoded loop | Same rotator, now clearly documented as **automatic IP switching per verified country**, tunable interval, wrong-country self-heal...
  | **nginx config** | 10 country blocks hardcoded, always present even for failed/removed countries | Country location blocks are **generated dynamically** from the verified-country list at container s...
  
  ---
  
  ## 🚀 Deployment
  
  1. Deploy this repository to Railway (or any single-port container host).
  2. Optional environment variables:
  
  | Variable | Purpose | Default |
  |---|---|---|
  | `XUI_USERNAME` | Panel username | `admin` |
  | `XUI_PASSWORD` | Panel password | `admin` |
  | `XUI_API_TOKEN` | Bearer token, skips form login if set | *(unset)* |
  | `PUBLIC_DOMAIN` | Override auto-detected public domain | auto-detected |
  
  3. Everything else — the public port, rotation interval, retry/timeout tuning, and the country list itself — lives in **`config.json`**.
  
  ---
  
  ## 📡 Endpoints
  
  All endpoints are served on the **single public port (`3000`)** through nginx.
  
  | Path | Type | Notes |
  |---|---|---|
  | `/` | 🌐 Direct | Default — server's own IP, no Tor |
  | `/direct` | 🌐 Direct | Same as `/`, explicit path |
  | `/in1` … `/in10` | 🔒 Country exit | Present **only if that country passed discovery** — see `config.json` for which path maps to which country |
  | `/managepanel/` | — | 3x-ui admin panel |
  | `/tor-status/all.json` | — | Live status for every configured country |
  | `/tor-status/<code>.json` | — | Live status for one country (`exit_ip`, `verified`, `checked_at`, …) |
  | `/health`, `/ping` | — | Liveness checks |
  
  <details>
  <summary>Default country list (10 configured in <code>config.json</code>)</summary>
  <br/>
  
  | Path | Country |
  |---|---|
  | `/in1` | 🇨🇦 Canada |
  | `/in2` | 🇹🇷 Turkey |
  | `/in3` | 🇩🇪 Germany |
  | `/in4` | 🇫🇷 France |
  | `/in5` | 🇸🇪 Sweden |
  | `/in6` | 🇨🇭 Switzerland |
  | `/in7` | 🇫🇮 Finland |
  | `/in8` | 🇬🇧 United Kingdom |
  | `/in9` | 🇪🇸 Spain |
  | `/in10` | 🇷🇴 Romania |
  
  Add, remove, or reassign any of these by editing the `tor.countries` array in `config.json` — nothing in the scripts is hardcoded to a specific list length or path.
  
  </details>
  
  ---
  
  ## 🔎 How country discovery works now
  
  ```mermaid
  sequenceDiagram
      participant S as start.sh
      participant T as Tor instance (per country)
      participant G as Geo-IP providers (×4)
  
      par all countries in parallel
          S->>T: launch + wait for Bootstrapped 100%
          loop up to verify_max_retries
              S->>T: fetch exit IP (×5 echo services, first valid wins)
              S->>G: resolve IP → country (first provider to answer wins)
              alt country matches
                  S-->>S: ✅ verified, write status JSON
              else mismatch or lookup failed
                  S->>T: SIGNAL NEWNYM (force new circuit)
                  S-->>S: short bounded sleep, retry
              end
          end
      end
      S->>S: build VERIFIED_CODES[] from all status files
      S->>S: render nginx locations + hand off to panel-bootstrap.sh
  ```
  
  Everything under `tor.*` in `config.json` is tunable without touching a script:
  
  ```jsonc
  "tor": {
    "bootstrap_timeout": 240,     // max wait for Tor to reach 100%
    "verify_max_retries": 15,     // attempts to find a matching-country exit
    "verify_retry_sleep": 4,      // seconds between attempts
    "circuit_settle_sleep": 6,    // settle time after a fresh circuit
    "parallel_bootstrap": true,   // bootstrap + verify all countries at once
    "parallel_verify": true
  }
  ```
  
  ---
  
  ## 🔁 Automatic IP switching
  
  Every **verified** country gets its own background rotation cycle (`tor.rotate_seconds`, default `300`s):
  
  1. `SIGNAL NEWNYM` is sent to that country's own `ControlPort` — a fresh Tor circuit, and therefore a fresh exit IP, is requested.
  2. The new exit IP is re-resolved through the same multi-provider geo-IP lookup used during discovery.
  3. If the new IP is still in the correct country, the status file is updated and the client keeps working uninterrupted.
  4. If the first rotation lands in the wrong country, one more attempt is made immediately; if that also fails, the country is marked unreachable until the *next* scheduled rotation (it is **not** torn...
  
  This runs entirely inside `start.sh` (`rotate_and_verify()`) — no external cron, no extra process.
  
  ---
  
  ## 🔒 Security & naming
  
  - **Direct connection** is the default on `/` and `/direct` — no Tor involved.
  - **Country connections** are available on their `/inN` paths, but **only for countries that passed discovery**.
  - **Strict exit-node enforcement** — each Tor instance is pinned with `ExitNodes {cc}` + `StrictNodes 1`; it is architecturally unable to exit anywhere else.
  - **Excluded regions** — `tor.exclude_countries` in `config.json` (oppressive-regime and high-risk jurisdictions) are excluded from every instance's possible exit set, not just the target country's ow...
  - **No "Tor" in the panel** — inbound tags, remarks, outbound tags, and routing rules use only the country code/label. Panel screenshots, exported client links, and the xray JSON config never contain ...
  - **Nothing but nginx is public** — the panel, the direct inbound, every country inbound, and every Tor SOCKS/Control port bind to `127.0.0.1` only.
  
  ---
  
  ## 📋 Logs
  
  | File | Contents |
  |---|---|
  | `/var/log/panel-bootstrap.log` | Panel bootstrap: inbound/client/routing creation and teardown |
  | `/var/log/tor/rotate.log` | Automatic IP-switching cycles |
  | `/var/log/tor/<code>-stdout.log` | Raw stdout/stderr for that country's Tor process |
  | `/var/log/tor/<code>/notices.log` | Tor notice-level log (bootstrap progress, circuit events) |
  | `/var/log/tor/<code>/warnings.log` | Tor warning-level log |
  | `/var/www/tor-status/<code>.json` | Live machine-readable status for that country |
  | `/var/www/tor-status/all.json` | All countries combined |
  | `/var/www/tor-status/setup-progress.json` | Overall `{total, verified, complete}` progress |
  
  ---
  
  ## 🗂️ File map
  
  ```
  .
  ├── Dockerfile               # Image build; only EXPOSEs port 3000 + healthcheck
  ├── config.json              # Single source of truth for ports, countries, tuning
  ├── nginx.conf.template      # Rendered at container start (envsubst + dynamic locations)
  ├── start.sh                 # Entrypoint: launches Tor, discovery, rotation, renders nginx, execs nginx
  ├── panel-bootstrap.sh       # Talks to the 3x-ui API: inbounds/clients/routing for verified countries
  └── torrc.reference          # Documentation-only; NOT read by any script
  ```
  
  <div align="center">
  <br/>
  
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:2c5364,50:203a43,100:0f2027&height=100&section=footer" width="100%"/>
  
  </div>
