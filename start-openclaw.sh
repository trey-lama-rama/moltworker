#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Detects warm vs cold restart (warm = supervisor loop restart, cold = fresh container)
# 2. On cold start: restores from R2, onboards, patches config, runs doctor
# 3. On warm restart: skips all setup, jumps straight to gateway (~5s vs ~40-60s)
# 4. Starts a supervisor loop that auto-restarts the gateway on crash

set -e

# Log the line number if any command fails (diagnostic aid)
trap 'echo "ERROR: command failed at line $LINENO (exit $?)"' ERR

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

# Disable set -e after the guard check. The setup phase below is best-effort:
# R2 restore, onboard, config patching, and workspace bootstrap should never
# prevent the gateway supervisor from starting. Individual steps log warnings.
set +e

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
LAST_SYNC_FILE="/tmp/.last-sync"
SETUP_MARKER="/tmp/.openclaw-setup-done"

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# SUPERVISOR FUNCTION (used by both warm and cold paths)
# ============================================================
# Extracted into a function to avoid duplication between the warm
# restart fast path and the cold start path.
run_supervisor() {
    echo "Starting OpenClaw Gateway..."
    echo "Gateway will be available on port 18789"
    echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

    # Token auth is handled by Cloudflare Access at the Worker layer.
    # Force-unset so OpenClaw cannot auto-enable token auth from env.
    unset OPENCLAW_GATEWAY_TOKEN

    local MAX_RAPID_CRASHES=5
    local RAPID_CRASH_WINDOW=30
    local rapid_crash_count=0
    local last_start_time=0

    while true; do
        local current_time
        current_time=$(date +%s)

        # Clean up lock files before each start
        rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
        rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

        echo "[supervisor] Starting gateway at $(date)"
        last_start_time=$current_time

        openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
        local exit_code=$?

        echo "[supervisor] Gateway exited with code $exit_code at $(date)"

        # Check if this was a rapid crash (within RAPID_CRASH_WINDOW seconds)
        local elapsed
        elapsed=$(( $(date +%s) - last_start_time ))
        if [ "$elapsed" -lt "$RAPID_CRASH_WINDOW" ]; then
            rapid_crash_count=$((rapid_crash_count + 1))
            echo "[supervisor] Rapid crash #$rapid_crash_count (ran for ${elapsed}s)"
        else
            rapid_crash_count=0
        fi

        # If crashing too fast, back off exponentially
        if [ "$rapid_crash_count" -ge "$MAX_RAPID_CRASHES" ]; then
            local backoff=$((rapid_crash_count * 10))
            [ "$backoff" -gt 120 ] && backoff=120
            echo "[supervisor] Crash loop detected ($rapid_crash_count rapid crashes). Waiting ${backoff}s before restart..."
            sleep "$backoff"
        else
            echo "[supervisor] Restarting gateway in 3s..."
            sleep 3
        fi
    done
}

# ============================================================
# WARM RESTART DETECTION
# ============================================================
# The supervisor loop re-invokes this script when the gateway crashes.
# On these "warm restarts", config/workspace/skills are already on the
# local filesystem -- skip all setup and restart the gateway immediately.
#
# /tmp is ephemeral to the container lifecycle: wiped on container reboot
# (new Durable Object / deploy) but survives supervisor restarts.

if [ -f "$SETUP_MARKER" ] && [ -f "$CONFIG_FILE" ]; then
    echo "[warm-restart] Setup already done, skipping to gateway (fast path)"
    run_supervisor
    # Never reaches here (supervisor loop is infinite)
fi

echo "[cold-start] Running full setup..."

# ============================================================
# HELPER FUNCTIONS
# ============================================================

r2_configured() {
    [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$CF_ACCOUNT_ID" ]
}

R2_BUCKET="${R2_BUCKET_NAME:-moltbot-data}"

setup_rclone() {
    mkdir -p "$(dirname "$RCLONE_CONF")"
    cat > "$RCLONE_CONF" << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    touch /tmp/.rclone-configured
    echo "Rclone configured for bucket: $R2_BUCKET"
}

RCLONE_FLAGS="--transfers=16 --fast-list --s3-no-check-bucket --contimeout 10s --timeout 30s --retries 1"

# ============================================================
# RESTORE FROM R2 (parallel)
# ============================================================

if r2_configured; then
    setup_rclone

    echo "Restoring from R2 (60s hard timeout, parallel)..."
    # Wrap R2 restore in a hard timeout so it can never block gateway startup.
    # All three restores (config, workspace, skills) run in parallel.
    export RCLONE_FLAGS R2_BUCKET CONFIG_DIR CONFIG_FILE WORKSPACE_DIR SKILLS_DIR
    timeout 60 bash -c '
        # --- Config restore (background) ---
        (
            if rclone ls "r2:${R2_BUCKET}/openclaw/openclaw.json" $RCLONE_FLAGS 2>/dev/null | grep -qx ".*openclaw\.json$"; then
                echo "Restoring config from R2..."
                rclone copy "r2:${R2_BUCKET}/openclaw/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: config restore failed"
                echo "Config restored"
            elif rclone ls "r2:${R2_BUCKET}/clawdbot/clawdbot.json" $RCLONE_FLAGS 2>/dev/null | grep -qx ".*clawdbot\.json$"; then
                echo "Restoring from legacy R2 backup..."
                rclone copy "r2:${R2_BUCKET}/clawdbot/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: legacy config restore failed"
                if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
                    mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
                fi
            else
                echo "No config backup found in R2"
            fi
        ) &
        CONFIG_PID=$!

        # --- Workspace restore (background) ---
        (
            REMOTE_WS_COUNT=$(rclone ls "r2:${R2_BUCKET}/workspace/" $RCLONE_FLAGS 2>/dev/null | wc -l)
            if [ "$REMOTE_WS_COUNT" -gt 0 ]; then
                echo "Restoring workspace from R2 ($REMOTE_WS_COUNT files)..."
                mkdir -p "$WORKSPACE_DIR"
                rclone copy "r2:${R2_BUCKET}/workspace/" "$WORKSPACE_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: workspace restore failed"
            fi
        ) &
        WS_PID=$!

        # --- Skills restore (background) ---
        (
            REMOTE_SK_COUNT=$(rclone ls "r2:${R2_BUCKET}/skills/" $RCLONE_FLAGS 2>/dev/null | wc -l)
            if [ "$REMOTE_SK_COUNT" -gt 0 ]; then
                echo "Restoring skills from R2 ($REMOTE_SK_COUNT files)..."
                mkdir -p "$SKILLS_DIR"
                rclone copy "r2:${R2_BUCKET}/skills/" "$SKILLS_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: skills restore failed"
            fi
        ) &
        SK_PID=$!

        echo "Parallel R2 restores started (config=$CONFIG_PID ws=$WS_PID skills=$SK_PID)"
        wait $CONFIG_PID $WS_PID $SK_PID
        echo "All R2 restores completed"
    ' || echo "WARNING: R2 restore timed out or failed (exit $?), continuing without backup"
else
    echo "R2 not configured, starting fresh"
fi

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
            --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID \
            --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID \
            --cloudflare-ai-gateway-api-key $CLOUDFLARE_AI_GATEWAY_API_KEY"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
    fi

    timeout 60 openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health || echo "WARNING: onboard failed or timed out (exit $?)"

    echo "Onboard completed"
else
    echo "Using existing config"
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
node << 'EOFPATCH' || echo "WARNING: config patching failed (exit $?), continuing anyway"
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Fix workspace path to match what the startup script and R2 sync use
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.workspace = '/root/clawd';

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// Set gateway auth for LAN binding (required by OpenClaw for non-loopback).
// Since CVE-2026-25253, auth is mandatory -- mode must be explicit.
config.gateway.auth = {
    mode: 'token',
    token: process.env.SANDBOX_GATEWAY_TOKEN || 'sandbox-internal-fallback',
};

// Disable device signature checks for the Control UI. Cloudflare Access handles
// real authentication at the Worker layer, so device-level crypto is redundant.
config.gateway.controlUi = config.gateway.controlUi || {};
config.gateway.controlUi.allowInsecureAuth = true;
config.gateway.controlUi.dangerouslyDisableDeviceAuth = true;

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        const ids = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
        // dmPolicy="open" requires allowFrom to include "*" (OpenClaw validation).
        if (dmPolicy === 'open' && !ids.includes('*')) {
            ids.push('*');
        }
        config.channels.telegram.allowFrom = ids;
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ============================================================
# BOOTSTRAP WORKSPACE FILES (Chancellor identity)
# ============================================================
BOOTSTRAP_DIR="/root/workspace-bootstrap"
if [ -d "$BOOTSTRAP_DIR" ]; then
    mkdir -p "$WORKSPACE_DIR"
    for f in "$BOOTSTRAP_DIR"/*.md; do
        [ -f "$f" ] || continue
        BASENAME=$(basename "$f")
        TARGET="$WORKSPACE_DIR/$BASENAME"
        if [ ! -f "$TARGET" ]; then
            cp "$f" "$TARGET"
            echo "Bootstrapped workspace file: $BASENAME"
        else
            echo "Workspace file already exists, skipping: $BASENAME"
        fi
    done
fi

# ============================================================
# BACKGROUND SYNC LOOP
# ============================================================
if r2_configured; then
    echo "Starting background R2 sync loop..."
    (
        MARKER=/tmp/.last-sync-marker
        LOGFILE=/tmp/r2-sync.log
        touch "$MARKER"

        while true; do
            sleep 30

            CHANGED=/tmp/.changed-files
            {
                find "$CONFIG_DIR" -newer "$MARKER" -type f -printf '%P\n' 2>/dev/null
                find "$WORKSPACE_DIR" -newer "$MARKER" \
                    -not -path '*/node_modules/*' \
                    -not -path '*/.git/*' \
                    -type f -printf '%P\n' 2>/dev/null
            } > "$CHANGED"

            COUNT=$(wc -l < "$CHANGED" 2>/dev/null || echo 0)

            if [ "$COUNT" -gt 0 ]; then
                echo "[sync] Uploading changes ($COUNT files) at $(date)" >> "$LOGFILE"
                rclone sync "$CONFIG_DIR/" "r2:${R2_BUCKET}/openclaw/" \
                    $RCLONE_FLAGS --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' --exclude='.git/**' 2>> "$LOGFILE"
                if [ -d "$WORKSPACE_DIR" ]; then
                    rclone sync "$WORKSPACE_DIR/" "r2:${R2_BUCKET}/workspace/" \
                        $RCLONE_FLAGS --exclude='skills/**' --exclude='.git/**' --exclude='node_modules/**' 2>> "$LOGFILE"
                fi
                if [ -d "$SKILLS_DIR" ]; then
                    rclone sync "$SKILLS_DIR/" "r2:${R2_BUCKET}/skills/" \
                        $RCLONE_FLAGS 2>> "$LOGFILE"
                fi
                date -Iseconds > "$LAST_SYNC_FILE"
                touch "$MARKER"
                echo "[sync] Complete at $(date)" >> "$LOGFILE"
            fi
        done
    ) &
    echo "Background sync loop started (PID: $!)"
fi

# ============================================================
# DOCTOR CHECK (auto-fix config issues)
# ============================================================
echo "Running openclaw doctor --fix --non-interactive..."
cp "$CONFIG_FILE" "$CONFIG_FILE.pre-doctor" 2>/dev/null || true
timeout 30 openclaw doctor --fix --non-interactive 2>&1 || echo "WARNING: openclaw doctor failed (exit $?)"

# Check if doctor resolved env var references to plaintext (known bug #4654)
if grep -q 'sk-ant-' "$CONFIG_FILE" 2>/dev/null || grep -q 'OPENCLAW_REDACTED' "$CONFIG_FILE" 2>/dev/null; then
    echo "WARNING: doctor exposed secrets in config, restoring backup"
    cp "$CONFIG_FILE.pre-doctor" "$CONFIG_FILE" 2>/dev/null || true
fi

# Clean lock files (stale locks from persistent volumes cause crash loops, issue #1676)
rm -f "$CONFIG_DIR"/*.lock 2>/dev/null || true

# Dump config for diagnostics (redact secrets)
echo "Current config (redacted):"
cat "$CONFIG_FILE" 2>/dev/null | node -e "
  const data=require('fs').readFileSync(0,'utf8');
  try {
    const c=JSON.parse(data);
    const redact = (o,d=0) => {
      if(d>3) return o;
      for(const k in o) {
        if(typeof o[k]==='string' && (k.toLowerCase().includes('key') || k.toLowerCase().includes('token') || k.toLowerCase().includes('secret') || k.toLowerCase().includes('password')))
          o[k]='[REDACTED]';
        else if(typeof o[k]==='object' && o[k]) redact(o[k],d+1);
      }
      return o;
    };
    console.log(JSON.stringify(redact(c),null,2));
  } catch(e) { console.log('INVALID JSON:', data.slice(0,500)); }
" || echo "(could not read config)"

# ============================================================
# MARK SETUP COMPLETE & START GATEWAY
# ============================================================
touch "$SETUP_MARKER"
echo "[cold-start] Setup complete, marker written. Future restarts will use fast path."

run_supervisor
