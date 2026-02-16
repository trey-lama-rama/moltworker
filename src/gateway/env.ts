import type { MoltbotEnv } from '../types';

/**
 * Build environment variables to pass to the OpenClaw container process
 *
 * @param env - Worker environment bindings
 * @returns Environment variables record
 */
export function buildEnvVars(env: MoltbotEnv): Record<string, string> {
  const envVars: Record<string, string> = {};

  // Cloudflare AI Gateway configuration (new native provider)
  if (env.CLOUDFLARE_AI_GATEWAY_API_KEY) {
    envVars.CLOUDFLARE_AI_GATEWAY_API_KEY = env.CLOUDFLARE_AI_GATEWAY_API_KEY;
  }
  if (env.CF_AI_GATEWAY_ACCOUNT_ID) {
    envVars.CF_AI_GATEWAY_ACCOUNT_ID = env.CF_AI_GATEWAY_ACCOUNT_ID;
  }
  if (env.CF_AI_GATEWAY_GATEWAY_ID) {
    envVars.CF_AI_GATEWAY_GATEWAY_ID = env.CF_AI_GATEWAY_GATEWAY_ID;
  }

  // Direct provider keys
  if (env.ANTHROPIC_API_KEY) envVars.ANTHROPIC_API_KEY = env.ANTHROPIC_API_KEY;
  if (env.OPENAI_API_KEY) envVars.OPENAI_API_KEY = env.OPENAI_API_KEY;

  // Legacy AI Gateway support: AI_GATEWAY_BASE_URL + AI_GATEWAY_API_KEY
  // When set, these override direct keys for backward compatibility
  if (env.AI_GATEWAY_API_KEY && env.AI_GATEWAY_BASE_URL) {
    const normalizedBaseUrl = env.AI_GATEWAY_BASE_URL.replace(/\/+$/, '');
    envVars.AI_GATEWAY_BASE_URL = normalizedBaseUrl;
    // Legacy path routes through Anthropic base URL
    envVars.ANTHROPIC_BASE_URL = normalizedBaseUrl;
    envVars.ANTHROPIC_API_KEY = env.AI_GATEWAY_API_KEY;
  } else if (env.ANTHROPIC_BASE_URL) {
    envVars.ANTHROPIC_BASE_URL = env.ANTHROPIC_BASE_URL;
  }

  // Pass gateway token under a custom env var name so the startup script can
  // set gateway.auth.token in the config. We use SANDBOX_GATEWAY_TOKEN instead
  // of OPENCLAW_GATEWAY_TOKEN to prevent OpenClaw from auto-enabling token auth
  // via env var detection. The Worker proxy injects this token into WebSocket
  // connect messages, so the browser never needs to know it.
  if (env.MOLTBOT_GATEWAY_TOKEN) envVars.SANDBOX_GATEWAY_TOKEN = env.MOLTBOT_GATEWAY_TOKEN;
  if (env.DEV_MODE) envVars.OPENCLAW_DEV_MODE = env.DEV_MODE;
  if (env.TELEGRAM_BOT_TOKEN) envVars.TELEGRAM_BOT_TOKEN = env.TELEGRAM_BOT_TOKEN;
  if (env.TELEGRAM_DM_POLICY) envVars.TELEGRAM_DM_POLICY = env.TELEGRAM_DM_POLICY;
  if (env.TELEGRAM_DM_ALLOW_FROM) envVars.TELEGRAM_DM_ALLOW_FROM = env.TELEGRAM_DM_ALLOW_FROM;
  if (env.DISCORD_BOT_TOKEN) envVars.DISCORD_BOT_TOKEN = env.DISCORD_BOT_TOKEN;
  if (env.DISCORD_DM_POLICY) envVars.DISCORD_DM_POLICY = env.DISCORD_DM_POLICY;
  if (env.SLACK_BOT_TOKEN) envVars.SLACK_BOT_TOKEN = env.SLACK_BOT_TOKEN;
  if (env.SLACK_APP_TOKEN) envVars.SLACK_APP_TOKEN = env.SLACK_APP_TOKEN;
  if (env.CF_AI_GATEWAY_MODEL) envVars.CF_AI_GATEWAY_MODEL = env.CF_AI_GATEWAY_MODEL;
  if (env.CF_ACCOUNT_ID) envVars.CF_ACCOUNT_ID = env.CF_ACCOUNT_ID;
  if (env.CDP_SECRET) envVars.CDP_SECRET = env.CDP_SECRET;
  if (env.WORKER_URL) envVars.WORKER_URL = env.WORKER_URL;

  // Google OAuth credentials (for Gmail/Calendar integration)
  if (env.GOOGLE_CLIENT_ID) envVars.GOOGLE_CLIENT_ID = env.GOOGLE_CLIENT_ID;
  if (env.GOOGLE_CLIENT_SECRET) envVars.GOOGLE_CLIENT_SECRET = env.GOOGLE_CLIENT_SECRET;
  if (env.GOOGLE_REFRESH_TOKEN) envVars.GOOGLE_REFRESH_TOKEN = env.GOOGLE_REFRESH_TOKEN;
  if (env.GOOGLE_CALENDAR_REFRESH_TOKEN) envVars.GOOGLE_CALENDAR_REFRESH_TOKEN = env.GOOGLE_CALENDAR_REFRESH_TOKEN;

  // Supermemory API (persistent memory across sessions)
  if (env.SUPERMEMORY_API_KEY) envVars.SUPERMEMORY_API_KEY = env.SUPERMEMORY_API_KEY;

  // Twilio (voice calls via OpenClaw voice-call plugin)
  if (env.TWILIO_ACCOUNT_SID) envVars.TWILIO_ACCOUNT_SID = env.TWILIO_ACCOUNT_SID;
  if (env.TWILIO_AUTH_TOKEN) envVars.TWILIO_AUTH_TOKEN = env.TWILIO_AUTH_TOKEN;
  if (env.TWILIO_PHONE_NUMBER) envVars.TWILIO_PHONE_NUMBER = env.TWILIO_PHONE_NUMBER;

  // R2 persistence credentials (used by rclone in start-openclaw.sh)
  if (env.R2_ACCESS_KEY_ID) envVars.R2_ACCESS_KEY_ID = env.R2_ACCESS_KEY_ID;
  if (env.R2_SECRET_ACCESS_KEY) envVars.R2_SECRET_ACCESS_KEY = env.R2_SECRET_ACCESS_KEY;
  if (env.R2_BUCKET_NAME) envVars.R2_BUCKET_NAME = env.R2_BUCKET_NAME;

  return envVars;
}
