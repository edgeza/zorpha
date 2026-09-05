import { rpcCall, hexToBigInt, type RpcOptions } from './rpc.js';

/**
 * Four checks that run before your first write, against configuration you do
 * not yet trust.
 *
 * The organising idea is that a misconfiguration and an outage are different
 * failures and deserve different answers:
 *
 *   MISCONFIGURATION - the config contradicts the chain. Refuse to start. The
 *   process would otherwise do confident, wrong work: index another chain's
 *   data, scan an empty range forever, or serve one chain's addresses beside
 *   another chain's balances.
 *
 *   OUTAGE - the chain did not answer. Report it and let the caller decide.
 *   Treating an unreachable node as a misconfiguration means the guard fires on
 *   every hiccup, and a guard that fires on hiccups gets disabled by the third
 *   person who is paged.
 *
 * A JSON-RPC error object, an HTTP 502, an HTML gateway page and a timeout all
 * land in the second bucket. None of them tells you which chain answered, so
 * none is evidence that the config is wrong.
 */

export type Severity = 'fatal' | 'warning';

export interface Finding {
  severity: Severity;
  /** Stable machine-readable code, for tests and log filters. */
  code:
    | 'chain-id-mismatch'
    | 'start-block-beyond-head'
    | 'address-has-no-code'
    | 'rpc-cannot-serve-archive'
    | 'rpc-unreachable'
    | 'no-rpc-reachable';
  message: string;
  url?: string;
}

export interface RpcStatus {
  url: string;
  /** null when the endpoint did not answer with a usable chain id. */
  chainId: number | null;
  /** null when not probed. */
  servesArchive: boolean | null;
  head: bigint | null;
  error?: string;
}

export interface PreflightReport {
  /** False when any fatal finding was raised. */
  ok: boolean;
  findings: Finding[];
  rpcs: RpcStatus[];
  /** Highest head seen across reachable endpoints, or null if none answered. */
  head: bigint | null;
}

export interface PreflightConfig {
  /** The chain id this deployment believes it is talking to. */
  chainId: number;
  /**
   * EVERY endpoint the application may use, including fallbacks.
   *
   * Checking only the primary is how a fallback pointed at the other network
   * survives review: it is never consulted until the primary blips, and by
   * then nobody is watching.
   */
  rpcUrls: string[];
  /** Where indexing will begin. Checked against the live head. */
  startBlock?: bigint;
  /** Contract addresses the application will read. Each must have bytecode. */
  addresses?: string[];
  /**
   * Probe whether each endpoint can serve a historic `eth_getLogs`.
   *
   * Default true. An indexer is nothing but historic getLogs, and an endpoint
   * can answer `eth_chainId` correctly and still refuse the only query you
   * actually make.
   */
  requireArchive?: boolean;
}

const ZERO_TOPIC = '0x0000000000000000000000000000000000000000000000000000000000000000';

/** Ask one endpoint who it is and how far along it is. */
async function probeIdentity(url: string, opts: RpcOptions): Promise<RpcStatus> {
  const status: RpcStatus = { url, chainId: null, servesArchive: null, head: null };

  const id = await rpcCall(url, 'eth_chainId', [], opts);
  if (!id.ok) {
    status.error = id.error;
    return status;
  }
  const parsed = hexToBigInt(id.result);
  if (parsed === null) {
    status.error = `expected a hex chain id, got ${JSON.stringify(id.result)}`;
    return status;
  }
  status.chainId = Number(parsed);

  const head = await rpcCall(url, 'eth_blockNumber', [], opts);
  if (head.ok) status.head = hexToBigInt(head.result);

  return status;
}

/**
 * Ask one endpoint to serve a historic log query.
 *
 * The range is deliberately ancient and narrow: it costs the node almost
 * nothing to answer, and an endpoint that prunes history will decline it. We
 * are testing capability, not looking for results — an empty array is a pass.
 */
async function probeArchive(url: string, opts: RpcOptions): Promise<boolean> {
  const res = await rpcCall(url, 'eth_getLogs', [
    { fromBlock: '0x1', toBlock: '0x2', topics: [ZERO_TOPIC] },
  ], opts);
  return res.ok;
}

export async function preflight(
  config: PreflightConfig,
  opts: RpcOptions = {},
): Promise<PreflightReport> {
  const findings: Finding[] = [];
  const urls = config.rpcUrls.filter((u) => u && u.trim().length > 0);
  const requireArchive = config.requireArchive ?? true;

  const rpcs: RpcStatus[] = [];
  for (const url of urls) {
    const status = await probeIdentity(url, opts);

    if (status.chainId === null) {
      findings.push({
        severity: 'warning',
        code: 'rpc-unreachable',
        url,
        message:
          `${url} did not return a usable chain id (${status.error}). This is an ` +
          `outage, not a misconfiguration: nothing was learned about which chain ` +
          `is on the other end, so it is not evidence the config is wrong.`,
      });
    } else if (status.chainId !== config.chainId) {
      findings.push({
        severity: 'fatal',
        code: 'chain-id-mismatch',
        url,
        message:
          `${url} serves chain ${status.chainId}, but this deployment is ` +
          `configured for ${config.chainId}. Every address in your config comes ` +
          `from the configured chain and every balance beside it from this RPC; ` +
          `while they disagree the application does confident, wrong work.`,
      });
    } else if (requireArchive) {
      status.servesArchive = await probeArchive(url, opts);
      if (!status.servesArchive) {
        findings.push({
          severity: 'fatal',
          code: 'rpc-cannot-serve-archive',
          url,
          message:
            `${url} answers eth_chainId with ${status.chainId} but will not serve ` +
            `a historic eth_getLogs. It passes every identity check and refuses ` +
            `the only workload an indexer has. Listed as a fallback it is worse ` +
            `than no fallback: it turns a transient blip on the primary into a ` +
            `hard failure on a range the primary serves.`,
        });
      }
    }

    rpcs.push(status);
  }

  const heads = rpcs.map((r) => r.head).filter((h): h is bigint => h !== null);
  const head = heads.length > 0 ? heads.reduce((a, b) => (a > b ? a : b)) : null;

  const usable = rpcs.find((r) => r.chainId === config.chainId);
  if (urls.length > 0 && !usable) {
    findings.push({
      severity: 'warning',
      code: 'no-rpc-reachable',
      message:
        `None of the ${urls.length} configured endpoint(s) confirmed chain ` +
        `${config.chainId}. Startup cannot be verified either way.`,
    });
  }

  // --- start block against the live head ---------------------------------
  //
  // The quiet one. A start block from another network is not rejected by
  // anything: getLogs over a range beyond the head returns [], so the process
  // scans nothing, advances nothing, and logs a healthy cycle forever.
  if (config.startBlock !== undefined && head !== null && config.startBlock > head) {
    findings.push({
      severity: 'fatal',
      code: 'start-block-beyond-head',
      message:
        `startBlock ${config.startBlock} is beyond the head of chain ` +
        `${config.chainId}, currently ${head}. Nothing would ever be scanned and ` +
        `every cycle would report success. A block height from the other network ` +
        `looks exactly like this.`,
    });
  }

  // --- addresses must exist on THIS chain --------------------------------
  //
  // getLogs against an address with no bytecode is not an error, it is an
  // empty array. Three addresses from the other network look exactly like
  // three quiet contracts.
  if (config.addresses?.length && usable) {
    for (const address of config.addresses) {
      const code = await rpcCall<string>(usable.url, 'eth_getCode', [address, 'latest'], opts);
      if (!code.ok) {
        findings.push({
          severity: 'warning',
          code: 'rpc-unreachable',
          url: usable.url,
          message: `could not read code at ${address}: ${code.error}`,
        });
        continue;
      }
      if (code.result === '0x' || code.result === '0x0') {
        findings.push({
          severity: 'fatal',
          code: 'address-has-no-code',
          message:
            `${address} has no bytecode on chain ${config.chainId}. Log queries ` +
            `against it will return an empty array rather than an error, so it ` +
            `would be scanned forever and never yield anything. This is what an ` +
            `address copied from the other network looks like.`,
        });
      }
    }
  }

  return { ok: !findings.some((f) => f.severity === 'fatal'), findings, rpcs, head };
}

export class PreflightError extends Error {
  readonly report: PreflightReport;
  constructor(report: PreflightReport) {
    const fatal = report.findings.filter((f) => f.severity === 'fatal');
    super(
      `Refusing to start. ${fatal.length} fatal preflight finding(s):\n` +
        fatal.map((f) => `  [${f.code}] ${f.message}`).join('\n'),
    );
    this.name = 'PreflightError';
    this.report = report;
  }
}

/**
 * Run the checks and throw on any fatal finding.
 *
 * Warnings are returned, not thrown. Call this once at startup, before the
 * first write.
 */
export async function assertPreflight(
  config: PreflightConfig,
  opts: RpcOptions = {},
): Promise<PreflightReport> {
  const report = await preflight(config, opts);
  if (!report.ok) throw new PreflightError(report);
  return report;
}
