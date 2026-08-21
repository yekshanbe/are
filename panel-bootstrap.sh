#!/bin/bash
set -u

CONFIG_FILE="${CONFIG_FILE:-/opt/app/config.json}"
LOG() { echo "[panel-bootstrap] $*"; }

PANEL_BASE_PATH=$(jq -r '.xui.web_base_path' "$CONFIG_FILE")
PANEL_INTERNAL="http://127.0.0.1:$(jq -r '.xui.internal_port' "$CONFIG_FILE")${PANEL_BASE_PATH}"
PANEL_USER="${XUI_USERNAME:-$(jq -r '.xui.default_username' "$CONFIG_FILE")}"
PANEL_PASS="${XUI_PASSWORD:-$(jq -r '.xui.default_password' "$CONFIG_FILE")}"
API_TOKEN="${XUI_API_TOKEN:-}"


DIRECT_ENABLED=$(jq -r '.direct.enabled // true' "$CONFIG_FILE")
DIRECT_PORT=$(jq -r '.direct.port // 8080' "$CONFIG_FILE")
DIRECT_PATH=$(jq -r '.direct.path // "/direct"' "$CONFIG_FILE")
DIRECT_TAG=$(jq -r '.direct.tag // "direct-inbound"' "$CONFIG_FILE")

COOKIE_JAR="/tmp/xui-cookies.txt"
CSRF_TOKEN=""

XUI_BIN="/usr/local/x-ui/x-ui"

detect_domain() {
    if [ -n "${PUBLIC_DOMAIN:-}" ]; then
        echo "$PUBLIC_DOMAIN"
    elif [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
        echo "$RAILWAY_PUBLIC_DOMAIN"
    elif [ -n "${RAILWAY_STATIC_URL:-}" ]; then
        echo "$RAILWAY_STATIC_URL" | sed -E 's~^https?://~~'
    else
        NGINX_PUBLIC_PORT=$(jq -r '.server.public_port // 3000' "$CONFIG_FILE")
        echo "localhost:${NGINX_PUBLIC_PORT}"
    fi
}

DOMAIN="$(detect_domain)"
LOG "Detected public domain: $DOMAIN"

wait_for_panel() {
    for i in $(seq 1 30); do
        code=$(curl -s -o /dev/null -w "%{http_code}" "${PANEL_INTERNAL}/login")
        if [ "$code" != "000" ]; then
            LOG "Panel is responding (http $code)."
            return 0
        fi
        sleep 2
    done
    LOG "❌ Panel never responded. Aborting."
    return 1
}

login() {
    if [ -n "$API_TOKEN" ]; then
        LOG "✅ Using XUI_API_TOKEN (Bearer auth)."
        return 0
    fi

    csrf_resp=$(curl -s -c "$COOKIE_JAR" "${PANEL_INTERNAL}/csrf-token")
    CSRF_TOKEN=$(echo "$csrf_resp" | jq -r '.obj // .token // empty' 2>/dev/null)

    json_data=$(jq -n --arg u "$PANEL_USER" --arg p "$PANEL_PASS" '{username:$u,password:$p}')
    if [ -n "$CSRF_TOKEN" ]; then
        resp=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
            -H "Content-Type: application/json" -H "X-CSRF-Token: ${CSRF_TOKEN}" \
            -X POST "${PANEL_INTERNAL}/login" -d "$json_data")
    else
        resp=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
            -H "Content-Type: application/json" \
            -X POST "${PANEL_INTERNAL}/login" -d "$json_data")
    fi

    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" != "true" ]; then
        LOG "❌ Login failed. Response: '${resp}'"
        return 1
    fi
    LOG "✅ Logged into panel API."
    return 0
}

api_post() {
    local path="$1" data="$2"
    if [ -n "$API_TOKEN" ]; then
        curl -s -H "Content-Type: application/json" -H "Authorization: Bearer ${API_TOKEN}" \
            -X POST "${PANEL_INTERNAL}${path}" -d "$data"
    elif [ -n "$CSRF_TOKEN" ]; then
        curl -s -b "$COOKIE_JAR" -H "Content-Type: application/json" \
            -H "X-CSRF-Token: ${CSRF_TOKEN}" -X POST "${PANEL_INTERNAL}${path}" -d "$data"
    else
        curl -s -b "$COOKIE_JAR" -H "Content-Type: application/json" \
            -X POST "${PANEL_INTERNAL}${path}" -d "$data"
    fi
}

api_post_form() {
    local path="$1"; shift
    if [ -n "$API_TOKEN" ]; then
        curl -s -H "Authorization: Bearer ${API_TOKEN}" \
            -X POST "${PANEL_INTERNAL}${path}" "$@"
    elif [ -n "$CSRF_TOKEN" ]; then
        curl -s -b "$COOKIE_JAR" -H "X-CSRF-Token: ${CSRF_TOKEN}" \
            -X POST "${PANEL_INTERNAL}${path}" "$@"
    else
        curl -s -b "$COOKIE_JAR" \
            -X POST "${PANEL_INTERNAL}${path}" "$@"
    fi
}

api_get() {
    if [ -n "$API_TOKEN" ]; then
        curl -s -H "Authorization: Bearer ${API_TOKEN}" "${PANEL_INTERNAL}$1"
    else
        curl -s -b "$COOKIE_JAR" "${PANEL_INTERNAL}$1"
    fi
}

existing_inbound_tags() {
    api_get "/panel/api/inbounds/list/slim" | jq -r '.obj[]?.tag // empty' 2>/dev/null
}

inbound_id_by_tag() {
    local tag="$1"
    api_get "/panel/api/inbounds/list/slim" | jq -r --arg t "$tag" '.obj[]? | select(.tag==$t) | .id' 2>/dev/null | head -n1
}

client_exists() {
    local email="$1"
    resp=$(api_get "/panel/api/clients/get/${email}")
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    [ "$ok" = "true" ]
}

delete_inbound() {
    local tag="$1"
    local id
    id=$(inbound_id_by_tag "$tag")
    if [ -n "$id" ] && [ "$id" != "null" ]; then
        LOG "🗑️ Deleting inbound: ${tag} (ID: ${id})"
        resp=$(api_post "/panel/api/inbounds/del/$id" "{}")
        ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
        if [ "$ok" = "true" ]; then
            LOG "✅ Inbound ${tag} deleted."
            return 0
        else
            LOG "❌ Failed to delete inbound ${tag}: $resp"
            return 1
        fi
    fi
    return 0
}

delete_client() {
    local email="$1"
    if client_exists "$email"; then
        LOG "🗑️ Deleting client: ${email}"
        resp=$(api_post "/panel/api/clients/del/${email}" "{}")
        ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
        if [ "$ok" = "true" ]; then
            LOG "✅ Client ${email} deleted."
            return 0
        else
            LOG "❌ Failed to delete client ${email}: $resp"
            return 1
        fi
    fi
    return 0
}

create_inbound() {
    local tag="$1" label="$2" port="$3" path="$4" protocol="$5"

    local settings streamSettings sniffing
    settings=$(jq -n '{clients: [], decryption: "none", fallbacks: []}')
    streamSettings=$(jq -n --arg path "$path" '{network: "ws", security: "none", wsSettings: {path: $path, headers: {}}}')
    sniffing='{"enabled":true,"destOverride":["http","tls"],"metadataOnly":false,"routeOnly":false}'

    local body
    body=$(jq -n \
        --arg remark "${label}" \
        --arg tag "$tag" \
        --argjson port "$port" \
        --argjson settings "$settings" \
        --argjson streamSettings "$streamSettings" \
        --argjson sniffing "$sniffing" \
        --arg protocol "$protocol" '{
            up: 0, down: 0, total: 0, remark: $remark, enable: true, expiryTime: 0,
            listen: "127.0.0.1", port: $port, protocol: $protocol,
            settings: $settings, streamSettings: $streamSettings, sniffing: $sniffing, tag: $tag
        }')

    resp=$(api_post "/panel/api/inbounds/add" "$body")
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" = "true" ]; then
        LOG "✅ Inbound created: ${label} (port ${port}, path ${path})"
        return 0
    else
        LOG "❌ Inbound for ${label} failed: $resp"
        return 1
    fi
}

create_client() {
    local tag="$1" label="$2" inbound_id="$3"
    local email="${tag}-client"

    if client_exists "$email"; then
        LOG "Client '${email}' already exists, skipping."
        return 0
    fi

    local client_body body
    client_body=$(jq -n --arg email "$email" '{email: $email, totalGB: 0, expiryTime: 0, tgId: 0, limitIp: 0, enable: true}')
    body=$(jq -n --argjson client "$client_body" --argjson id "$inbound_id" '{client: $client, inboundIds: [$id]}')

    resp=$(api_post "/panel/api/clients/add" "$body")
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" = "true" ]; then
        LOG "✅ Client created: ${email}"
        return 0
    else
        LOG "❌ Client creation for ${email} failed: $resp"
        return 1
    fi
}

log_client_link() {
    local email="$1" label="$2"
    resp=$(api_get "/panel/api/clients/links/${email}")
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" = "true" ]; then
        link=$(echo "$resp" | jq -r '.obj[0] // empty')
        if [ -n "$link" ] && [ "$link" != "null" ]; then
            LOG "🔗 ${label}: ${link}"
        else
            LOG "⚠️ ${label}: panel returned no link yet."
        fi
    fi
}

# is_location_verified <code>
# Single source of truth for "did discovery succeed for this country?".
# Reads the status file written by start.sh's verify_tor_exit()/write_status_json().
is_location_verified() {
    local code="$1"
    local status_file="/var/www/tor-status/${code}.json"
    [ -f "$status_file" ] || return 1
    [ "$(jq -r '.verified // false' "$status_file" 2>/dev/null)" = "true" ]
}

get_failed_locations() {
    local failed=""
    local count
    count=$(jq '.tor.countries | length' "$CONFIG_FILE")
    for i in $(seq 0 $((count - 1))); do
        local code
        code=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
        is_location_verified "$code" || failed="$failed $code"
    done
    echo "$failed"
}


setup_outbounds_and_routing() {
    LOG "Setting up SOCKS5 outbounds and routing rules..."

    local verified_locations=""
    local count
    count=$(jq '.tor.countries | length' "$CONFIG_FILE")
    for i in $(seq 0 $((count - 1))); do
        local code
        code=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
        is_location_verified "$code" && verified_locations="$verified_locations $code"
    done
    LOG "✅ Verified locations: ${verified_locations:-none}"

    local tpl_resp obj_type current_json
    tpl_resp=$(api_post "/panel/api/xray/" "{}")

    local top_ok
    top_ok=$(echo "$tpl_resp" | jq -e '.obj' >/dev/null 2>&1; echo $?)
    if [ "$top_ok" != "0" ]; then
        LOG "❌ Could not fetch Xray config template. Raw: ${tpl_resp:0:200}"
        return 1
    fi

    obj_type=$(echo "$tpl_resp" | jq -r '.obj | type' 2>/dev/null)

    if [ "$obj_type" = "object" ]; then
        current_json=$(echo "$tpl_resp" | jq -c '.obj')
    elif [ "$obj_type" = "string" ]; then
        current_json=$(echo "$tpl_resp" | jq -r '.obj')
    else
        LOG "❌ Unexpected .obj type '${obj_type}' from /panel/api/xray/."
        return 1
    fi

    if ! echo "$current_json" | jq -e . >/dev/null 2>&1; then
        LOG "❌ xraySetting wasn't valid JSON. Raw: ${current_json:0:200}"
        return 1
    fi

    new_config="$current_json"


    jq_transform() {
        local desc="$1" filter="$2"; shift 2
        local result
        result=$(printf '%s' "$new_config" | jq "$@" "$filter" 2>>/var/log/panel-bootstrap.log)
        if [ $? -ne 0 ] || [ -z "$result" ] || ! printf '%s' "$result" | jq -e . >/dev/null 2>&1; then
            LOG "❌ jq transform failed (${desc}) — aborting outbound/routing update to avoid corrupting config"
            return 1
        fi
        new_config="$result"
        return 0
    }

    # ---- گارد اول: مطمئن شو واقعاً config خام Xray گرفتیم، نه یک شیء پوششی ----
    if ! printf '%s' "$new_config" | jq -e 'has("outbounds") and has("routing")' >/dev/null 2>&1; then
        LOG "❌ /panel/api/xray/ did not return a raw xray config."
        LOG "❌ top-level keys were: $(printf '%s' "$new_config" | jq -r 'keys | join(",")')"
        # اگر پوششی بود، لایه رو باز کن
        if printf '%s' "$new_config" | jq -e 'has("xraySetting")' >/dev/null 2>&1; then
            LOG "↩️ Unwrapping .xraySetting ..."
            inner=$(printf '%s' "$new_config" | jq -c '.xraySetting')
            # ممکنه خودش رشته‌ی JSON باشه
            if ! printf '%s' "$inner" | jq -e 'type == "object"' >/dev/null 2>&1; then
                inner=$(printf '%s' "$new_config" | jq -r '.xraySetting')
            fi
            new_config="$inner"
            current_json="$inner"
        else
            return 1
        fi
    fi

    # ---- گارد دوم: بلوک‌های شمارش ترافیک همیشه باید باشن ----
    jq_transform "ensure stats"  '.stats = (.stats // {})' || return 1

    jq_transform "ensure api service" '
        .api = ((.api // {}) + {
            tag: "api",
            listen: "127.0.0.1:62789",
            services: ["HandlerService","LoggerService","StatsService"]
        })' || return 1

    jq_transform "ensure policy" '
        .policy = ((.policy // {}) + {
            levels: (((.policy.levels) // {}) + {
                "0": ((((.policy.levels)["0"]) // {}) + {
                    statsUserUplink: true,
                    statsUserDownlink: true,
                    statsUserOnline: true,
                    handshake: 4, connIdle: 300, uplinkOnly: 2, downlinkOnly: 5
                })
            }),
            system: {
                statsInboundUplink: true,  statsInboundDownlink: true,
                statsOutboundUplink: true, statsOutboundDownlink: true
            }
        })' || return 1

    jq_transform "ensure api inbound" '
        if (([.inbounds[]? | select(.tag == "api")] | length) == 0)
        then .inbounds = ([{
                tag: "api", listen: "127.0.0.1", port: 62789,
                protocol: "dokodemo-door", settings: { address: "127.0.0.1" }
            }] + (.inbounds // []))
        else . end' || return 1

    # rule مربوط به api همیشه باید *اولین* rule باشه
    jq_transform "ensure api routing rule first" '
        .routing = ((.routing // {}) + {
            rules: ([{ type: "field", inboundTag: ["api"], outboundTag: "api" }]
                    + [ (.routing.rules[]? | select(((.inboundTag // []) | index("api")) == null)) ])
        })' || return 1


    for i in $(seq 0 $((count - 1))); do
        local code
        code=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
        if ! is_location_verified "$code"; then
            LOG "🗑️ Removing outbound/routing for failed location: ${code}"
            jq_transform "remove outbound ${code}" \
                '.outbounds = [.outbounds[]? | select(.tag != $t)]' --arg t "$code" || return 1
            jq_transform "remove routing rule ${code}" '
                .routing.rules = [ .routing.rules[]?
                    | select( ((.inboundTag // []) | index("api")) != null
                            or ((.inboundTag // []) | index($t)) == null ) ]' --arg t "$code" || return 1
        fi
    done

    # ---- Add outbound/routing for every VERIFIED country -----------------------
    for i in $(seq 0 $((count - 1))); do
        local code
        code=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
        if is_location_verified "$code"; then
            local tor_port outbound_tag
            tor_port=$(jq -r ".tor.countries[$i].port" "$CONFIG_FILE")
            outbound_tag="$code"   # bare country code — no "tor-" prefix, no "Tor" label

            local already
            already=$(printf '%s' "$new_config" | jq --arg t "$outbound_tag" '[.outbounds[]? | select(.tag==$t)] | length')
            if [ "$already" = "0" ]; then
                LOG "Adding outbound: ${outbound_tag} -> 127.0.0.1:${tor_port}"
                jq_transform "add outbound ${outbound_tag}" '
                    .outbounds += [{
                        tag: $t,
                        protocol: "socks",
                        settings: { servers: [{ address: "127.0.0.1", port: $p, users: [] }] },
                        streamSettings: { sockopt: { tcpFastOpen: true, tcpKeepAlive: true } }
                    }]' --arg t "$outbound_tag" --argjson p "$tor_port" || return 1
            fi

            local rule_exists
            rule_exists=$(printf '%s' "$new_config" | jq --arg t "$code" '
                [.routing.rules[]? | select(.inboundTag != null and (.inboundTag | index($t)) != null)] | length')
            if [ "$rule_exists" = "0" ]; then
                LOG "Adding routing rule: ${code} -> ${outbound_tag}"
                jq_transform "add routing rule ${code}" '
                    .routing.rules = ((.routing.rules // []) + [{
                        type: "field",
                        enabled: true,
                        inboundTag: [$t],
                        outboundTag: $ot
                    }])' --arg t "$code" --arg ot "$outbound_tag" || return 1
            fi
        fi
    done

    # ---- Direct (non-Tor) outbound — always present -----------------------------
    DIRECT_OUTBOUND_TAG="direct-outbound"
    already_direct=$(printf '%s' "$new_config" | jq --arg t "$DIRECT_OUTBOUND_TAG" '[.outbounds[]? | select(.tag==$t)] | length')
    if [ "$already_direct" = "0" ]; then
        LOG "Adding direct (non-Tor) outbound: ${DIRECT_OUTBOUND_TAG}"
        jq_transform "add direct outbound" '
            .outbounds += [{
                tag: $t,
                protocol: "freedom",
                settings: {}
            }]' --arg t "$DIRECT_OUTBOUND_TAG" || return 1
    fi

    DIRECT_INBOUND_TAG="direct-inbound"
    direct_rule_exists=$(printf '%s' "$new_config" | jq --arg t "$DIRECT_INBOUND_TAG" '
        [.routing.rules[]? | select(.inboundTag != null and (.inboundTag | index($t)) != null)] | length')
    if [ "$direct_rule_exists" = "0" ]; then
        LOG "Adding routing rule: ${DIRECT_INBOUND_TAG} -> ${DIRECT_OUTBOUND_TAG}"
        jq_transform "add direct routing rule" '
            .routing.rules = ((.routing.rules // []) + [{
                type: "field",
                enabled: true,
                inboundTag: [$t],
                outboundTag: $ot
            }])' --arg t "$DIRECT_INBOUND_TAG" --arg ot "$DIRECT_OUTBOUND_TAG" || return 1
    fi

    if [ "$new_config" != "$current_json" ]; then
        local tmp_config
        tmp_config=$(mktemp /tmp/xray-setting.XXXXXX.json)
        printf '%s' "$new_config" > "$tmp_config"

        resp=$(api_post_form "/panel/api/xray/update" --data-urlencode "xraySetting@${tmp_config}")
        rm -f "$tmp_config"

        ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
        if [ "$ok" = "true" ]; then
            LOG "✅ Outbounds + routing saved successfully."
            LOG "Restarting Xray via x-ui CLI..."
            if ! $XUI_BIN restart; then
                LOG "⚠️ x-ui restart command failed, trying stop/start..."
                $XUI_BIN stop
                sleep 5
                $XUI_BIN start
            fi
            sleep 8
            return 0
        else
            LOG "❌ Failed to save outbounds/routing. Response: $resp"
            return 1
        fi
    fi
    LOG "Outbounds + routing already up to date. Skipping restart."
    return 0
}

LOG "============================================================"
LOG "Panel bootstrap starting..."
wait_for_panel || exit 0
login || exit 0

existing=$(existing_inbound_tags)
LOG "Existing inbound tags: ${existing:-none}"

# ---- Direct (non-Tor) inbound -------------------------------------------------
if [ "$DIRECT_ENABLED" = "true" ]; then
    if ! echo "$existing" | grep -qx "$DIRECT_TAG"; then
        LOG "Creating Direct (Non-Tor) inbound on port ${DIRECT_PORT} (internal only)..."
        create_inbound "$DIRECT_TAG" "Direct" "$DIRECT_PORT" "$DIRECT_PATH" "vless"
        id=$(inbound_id_by_tag "$DIRECT_TAG")
        [ -n "$id" ] && [ "$id" != "null" ] && create_client "$DIRECT_TAG" "Direct" "$id"
    else
        LOG "Direct inbound already exists."
        id=$(inbound_id_by_tag "$DIRECT_TAG")
        [ -n "$id" ] && [ "$id" != "null" ] && create_client "$DIRECT_TAG" "Direct" "$id"
    fi
fi

FAILED_LOCATIONS=$(get_failed_locations)
LOG "Failed locations (will not be created / will be removed): ${FAILED_LOCATIONS:-none}"

for CODE in $FAILED_LOCATIONS; do
    if echo "$existing" | grep -qx "$CODE"; then
        LOG "🗑️ Tearing down failed location: ${CODE}"
        delete_inbound "$CODE"
        delete_client "${CODE}-client"
    fi
done

COUNTRY_COUNT=$(jq '.tor.countries | length' "$CONFIG_FILE")
for i in $(seq 0 $((COUNTRY_COUNT - 1))); do
    CODE=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
    LABEL=$(jq -r ".tor.countries[$i].label" "$CONFIG_FILE")
    PORT=$(jq -r ".tor.countries[$i].inbound_port" "$CONFIG_FILE")
    PATH_WS=$(jq -r ".tor.countries[$i].path" "$CONFIG_FILE")

    if is_location_verified "$CODE"; then
        if ! echo "$existing" | grep -qx "$CODE"; then
            create_inbound "$CODE" "$LABEL" "$PORT" "$PATH_WS" "vless"
        fi
    else
        LOG "⚠️ Skipping ${CODE} — discovery did not verify this exit country"
    fi
done

sleep 2

# ---- Create clients for VERIFIED countries only -------------------------------
for i in $(seq 0 $((COUNTRY_COUNT - 1))); do
    CODE=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
    LABEL=$(jq -r ".tor.countries[$i].label" "$CONFIG_FILE")

    if is_location_verified "$CODE"; then
        id=$(inbound_id_by_tag "$CODE")
        [ -n "$id" ] && [ "$id" != "null" ] && create_client "$CODE" "$LABEL" "$id"
    fi
done

# ---- Outbounds + routing -------------------------------------------------------
if ! setup_outbounds_and_routing; then
    LOG "⚠️ Outbound/routing cleanup did not complete successfully — check the log above."
    LOG "⚠️ Panel may still show stale outbounds for failed countries until the next run."
fi

LOG "============================================================"
LOG "Fetching panel-generated client links..."

if [ "$DIRECT_ENABLED" = "true" ]; then
    log_client_link "${DIRECT_TAG}-client" "🌐 Direct"
fi

for i in $(seq 0 $((COUNTRY_COUNT - 1))); do
    CODE=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
    LABEL=$(jq -r ".tor.countries[$i].label" "$CONFIG_FILE")
    is_location_verified "$CODE" && log_client_link "${CODE}-client" "🔒 ${LABEL}"
done

LOG "============================================================"
VERIFIED_COUNT=$(find /var/www/tor-status -maxdepth 1 -name "*.json" ! -name "all.json" ! -name "setup-progress.json" -exec jq -r '.verified // false' {} \; 2>/dev/null | grep -c "true" || echo "0")
LOG "✅ Panel bootstrap completed!"
LOG "✅ ${VERIFIED_COUNT}/${COUNTRY_COUNT} country exits verified and active"
LOG "🌐 Direct (Non-Tor) available at path ${DIRECT_PATH} (behind nginx, single public port)"
LOG "🔒 Verified countries are available at their configured /inN paths"
LOG "📊 Panel: https://${DOMAIN}/managepanel/"
LOG "============================================================"