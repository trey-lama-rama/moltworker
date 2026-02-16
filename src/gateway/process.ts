import type { Sandbox, Process } from '@cloudflare/sandbox';
import type { MoltbotEnv } from '../types';
import { MOLTBOT_PORT, STARTUP_TIMEOUT_MS } from '../config';
import { buildEnvVars } from './env';
import { ensureRcloneConfig } from './r2';

/** Short timeout for checking if an existing process is reachable.
 *  If a process is truly running and ready, the port responds in seconds.
 *  This prevents hanging for 3 minutes on stale processes after DO resets. */
const EXISTING_PROCESS_TIMEOUT_MS = 15_000;

/** Delay between retries when the DO is resetting */
const DO_RESET_RETRY_DELAY_MS = 5_000;

/** Max retries when hitting DO reset errors */
const DO_RESET_MAX_RETRIES = 3;

/** Cache for findExistingMoltbotProcess to avoid hitting sandbox.listProcesses() on every request */
let cachedProcess: Process | null = null;
let cacheTimestamp = 0;
const PROCESS_CACHE_TTL_MS = 2_000;

/** Invalidate the process cache (call after killing/starting a process) */
export function invalidateProcessCache(): void {
  cachedProcess = null;
  cacheTimestamp = 0;
}

/**
 * Check if an error is a Durable Object reset error
 */
function isDurableObjectReset(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return msg.includes('Durable Object reset') || msg.includes('Network connection lost');
}

/**
 * Find an existing OpenClaw gateway process
 *
 * @param sandbox - The sandbox instance
 * @returns The process if found and running/starting, null otherwise
 */
export async function findExistingMoltbotProcess(sandbox: Sandbox): Promise<Process | null> {
  // Return cached result if still fresh
  const now = Date.now();
  if (cachedProcess && now - cacheTimestamp < PROCESS_CACHE_TTL_MS) {
    if (cachedProcess.status === 'running' || cachedProcess.status === 'starting') {
      return cachedProcess;
    }
    invalidateProcessCache();
  }

  try {
    const processes = await sandbox.listProcesses();
    for (const proc of processes) {
      // Match gateway process (openclaw gateway or legacy clawdbot gateway)
      // Don't match CLI commands like "openclaw devices list"
      const isGatewayProcess =
        proc.command.includes('start-openclaw.sh') ||
        proc.command.includes('openclaw gateway') ||
        // Legacy: match old startup script during transition
        proc.command.includes('start-moltbot.sh') ||
        proc.command.includes('clawdbot gateway');
      const isCliCommand =
        proc.command.includes('openclaw devices') ||
        proc.command.includes('openclaw --version') ||
        proc.command.includes('openclaw onboard') ||
        proc.command.includes('clawdbot devices') ||
        proc.command.includes('clawdbot --version');

      if (isGatewayProcess && !isCliCommand) {
        if (proc.status === 'starting' || proc.status === 'running') {
          cachedProcess = proc;
          cacheTimestamp = Date.now();
          return proc;
        }
      }
    }
  } catch (e) {
    console.log('Could not list processes:', e);
    // If this is a DO reset, propagate so caller can handle it
    if (isDurableObjectReset(e)) throw e;
  }

  // Cache the null result too
  cachedProcess = null;
  cacheTimestamp = Date.now();
  return null;
}

/**
 * Ensure the OpenClaw gateway is running
 *
 * This will:
 * 1. Mount R2 storage if configured
 * 2. Check for an existing gateway process
 * 3. Wait for it to be ready, or start a new one
 * 4. Retry on Durable Object reset errors (deploy transitions)
 *
 * @param sandbox - The sandbox instance
 * @param env - Worker environment bindings
 * @returns The running gateway process
 */
export async function ensureMoltbotGateway(sandbox: Sandbox, env: MoltbotEnv): Promise<Process> {
  for (let attempt = 0; attempt <= DO_RESET_MAX_RETRIES; attempt++) {
    try {
      return await _ensureMoltbotGatewayOnce(sandbox, env);
    } catch (e) {
      if (isDurableObjectReset(e) && attempt < DO_RESET_MAX_RETRIES) {
        console.log(
          `[Gateway] DO reset detected (attempt ${attempt + 1}/${DO_RESET_MAX_RETRIES}), ` +
            `retrying in ${DO_RESET_RETRY_DELAY_MS / 1000}s...`,
        );
        await new Promise((r) => setTimeout(r, DO_RESET_RETRY_DELAY_MS));
        continue;
      }
      throw e;
    }
  }

  // Should never reach here, but TypeScript needs it
  throw new Error('Exhausted DO reset retries');
}

async function _ensureMoltbotGatewayOnce(sandbox: Sandbox, env: MoltbotEnv): Promise<Process> {
  // Configure rclone for R2 persistence (non-blocking if not configured).
  // The startup script uses rclone to restore data from R2 on boot.
  await ensureRcloneConfig(sandbox, env);

  // Check if gateway is already running or starting
  const existingProcess = await findExistingMoltbotProcess(sandbox);
  if (existingProcess) {
    console.log(
      'Found existing gateway process:',
      existingProcess.id,
      'status:',
      existingProcess.status,
    );

    // Use a SHORT timeout for existing processes. If the gateway is truly
    // running and ready, the port responds in seconds. A 3-minute wait here
    // causes the UI to hang on stale processes after deploys/DO resets.
    try {
      console.log(
        'Checking existing gateway on port',
        MOLTBOT_PORT,
        'timeout:',
        EXISTING_PROCESS_TIMEOUT_MS,
      );
      await existingProcess.waitForPort(MOLTBOT_PORT, {
        mode: 'tcp',
        timeout: EXISTING_PROCESS_TIMEOUT_MS,
      });
      console.log('Gateway is reachable');
      return existingProcess;
    } catch (_e) {
      // Timeout waiting for port - process is likely dead or stuck, kill and restart
      console.log(
        `Existing process not reachable after ${EXISTING_PROCESS_TIMEOUT_MS / 1000}s, killing and restarting...`,
      );
      try {
        await existingProcess.kill();
        invalidateProcessCache();
      } catch (killError) {
        console.log('Failed to kill process:', killError);
        if (isDurableObjectReset(killError)) throw killError;
      }
    }
  }

  // Start a new OpenClaw gateway
  console.log('Starting new OpenClaw gateway...');
  const envVars = buildEnvVars(env);
  const command = '/usr/local/bin/start-openclaw.sh';

  console.log('Starting process with command:', command);
  console.log('Environment vars being passed:', Object.keys(envVars));

  let process: Process;
  try {
    process = await sandbox.startProcess(command, {
      env: Object.keys(envVars).length > 0 ? envVars : undefined,
    });
    invalidateProcessCache();
    console.log('Process started with id:', process.id, 'status:', process.status);
  } catch (startErr) {
    console.error('Failed to start process:', startErr);
    throw startErr;
  }

  // Wait for the gateway to be ready (full timeout for cold starts)
  try {
    console.log('[Gateway] Waiting for OpenClaw gateway to be ready on port', MOLTBOT_PORT);

    // Dump early logs after 20s so we can diagnose startup issues via wrangler tail
    const earlyLogTimer = setTimeout(async () => {
      try {
        const earlyLogs = await process.getLogs();
        if (earlyLogs.stdout) console.log('[Gateway] early stdout:', earlyLogs.stdout);
        if (earlyLogs.stderr) console.log('[Gateway] early stderr:', earlyLogs.stderr);
      } catch {
        // ignore - process may have already exited
      }
    }, 20_000);

    await process.waitForPort(MOLTBOT_PORT, { mode: 'tcp', timeout: STARTUP_TIMEOUT_MS });
    clearTimeout(earlyLogTimer);
    console.log('[Gateway] OpenClaw gateway is ready!');

    const logs = await process.getLogs();
    if (logs.stdout) console.log('[Gateway] stdout:', logs.stdout);
    if (logs.stderr) console.log('[Gateway] stderr:', logs.stderr);
  } catch (e) {
    console.error('[Gateway] waitForPort failed:', e);
    if (isDurableObjectReset(e)) throw e;
    try {
      const logs = await process.getLogs();
      console.error('[Gateway] startup failed. Stderr:', logs.stderr);
      console.error('[Gateway] startup failed. Stdout:', logs.stdout);
      throw new Error(`OpenClaw gateway failed to start. Stderr: ${logs.stderr || '(empty)'}`, {
        cause: e,
      });
    } catch (logErr) {
      if (isDurableObjectReset(logErr)) throw logErr;
      console.error('[Gateway] Failed to get logs:', logErr);
      throw e;
    }
  }

  // Verify gateway is actually responding
  console.log('[Gateway] Verifying gateway health...');

  return process;
}
