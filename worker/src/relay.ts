/**
 * Relay: Railway deployment webhook -> GitHub `workflow_dispatch` of `verify.yml`.
 *
 * Railway webhooks are unsigned and carry a fixed JSON body, so this Worker authenticates them
 * with a shared header secret, drops everything that is not a final deployment event of the
 * watched project, validates the fields it forwards and starts the monitor's workflow.
 * Railway gets a 2xx only once GitHub accepted the dispatch; otherwise 502 makes it retry.
 *
 * Never log secrets or the request body.
 */

export interface Env {
	/** Secret: value Railway sends in the `X-Monitor-Secret` header. */
	WEBHOOK_SECRET: string;
	/** Secret: fine-grained PAT, only the monitor repo, Actions: write. */
	GITHUB_DISPATCH_TOKEN: string;
	/** Var: the only Railway project whose events are forwarded. */
	RAILWAY_PROJECT_ID: string;
	/** Var: `<owner>/<repo>` of the monitor. */
	GITHUB_REPO: string;
}

/** Railway event types that end a deployment and are forwarded; anything else is ignored. */
export const FORWARDED_EVENT_TYPES = [
	"Deployment.deployed",
	"Deployment.redeployed",
	"Deployment.failed",
	"Deployment.crashed",
	"Deployment.oom_killed",
] as const;

export type ForwardedEventType = (typeof FORWARDED_EVENT_TYPES)[number];

export const ROUTE_PATH = "/railway";
export const SECRET_HEADER = "X-Monitor-Secret";
export const WORKFLOW_FILE = "verify.yml";
export const WORKFLOW_REF = "main";
export const GITHUB_API_VERSION = "2022-11-28";
export const USER_AGENT = "szczur-radar-monitor-worker";
const DISPATCH_TIMEOUT_MS = 10_000;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const NAME = /^[a-z0-9-]{1,64}$/;
const GITHUB_REPO = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

/** Inputs of `verify.yml`, all strings (workflow_dispatch inputs are strings). */
export interface DispatchInputs {
	event_type: ForwardedEventType;
	environment_id: string;
	environment_name: string;
	service_name: string;
	deployment_id: string;
}

export async function handle(request: Request, env: Env): Promise<Response> {
	const url = new URL(request.url);
	if (request.method !== "POST" || url.pathname !== ROUTE_PATH) {
		return text(404, "not found");
	}
	if (!isConfigured(env)) {
		console.error("worker misconfigured: WEBHOOK_SECRET, RAILWAY_PROJECT_ID or GITHUB_REPO missing or invalid");
		return text(500, "misconfigured");
	}
	if (!(await secretMatches(request.headers.get(SECRET_HEADER), env.WEBHOOK_SECRET))) {
		return text(401, "unauthorized");
	}

	let payload: unknown;
	try {
		payload = await request.json();
	} catch {
		return text(400, "invalid json");
	}

	if (str(path(payload, "resource", "project", "id")) !== env.RAILWAY_PROJECT_ID) {
		return text(204);
	}
	const type = str(path(payload, "type"));
	if (!isForwardedEventType(type)) {
		return text(204);
	}

	const inputs = toInputs(type, payload);
	if (inputs === null) {
		console.warn(`rejected ${type}: invalid environment/service/deployment fields`);
		return text(400, "invalid fields");
	}

	const dispatched = await dispatch(inputs, env);
	if (!dispatched) {
		return text(502, "dispatch failed");
	}
	console.log(
		`dispatched ${inputs.event_type} ${inputs.environment_name}/${inputs.service_name} deployment ${inputs.deployment_id}`,
	);
	return text(202, "dispatched");
}

export function isForwardedEventType(value: string | undefined): value is ForwardedEventType {
	return value !== undefined && (FORWARDED_EVENT_TYPES as readonly string[]).includes(value);
}

function isConfigured(env: Env): boolean {
	return (
		nonEmpty(env.WEBHOOK_SECRET) && nonEmpty(env.RAILWAY_PROJECT_ID) && GITHUB_REPO.test(env.GITHUB_REPO ?? "")
	);
}

/** Constant-time comparison over SHA-256 digests, so lengths never leak either. */
async function secretMatches(provided: string | null, expected: string): Promise<boolean> {
	if (provided === null) {
		return false;
	}
	const [a, b] = await Promise.all([sha256(provided), sha256(expected)]);
	return crypto.subtle.timingSafeEqual(a, b);
}

async function sha256(value: string): Promise<ArrayBuffer> {
	return crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
}

function toInputs(type: ForwardedEventType, payload: unknown): DispatchInputs | null {
	const environmentId = str(path(payload, "resource", "environment", "id"))?.toLowerCase();
	const environmentName = str(path(payload, "resource", "environment", "name"));
	const serviceName = str(path(payload, "resource", "service", "name"));
	const deploymentId = str(path(payload, "resource", "deployment", "id"))?.toLowerCase();
	const serviceId = str(path(payload, "resource", "service", "id"))?.toLowerCase();
	if (
		!matches(UUID, environmentId) ||
		!matches(UUID, serviceId) ||
		!matches(UUID, deploymentId) ||
		!matches(NAME, environmentName) ||
		!matches(NAME, serviceName)
	) {
		return null;
	}
	return {
		event_type: type,
		environment_id: environmentId,
		environment_name: environmentName,
		service_name: serviceName,
		deployment_id: deploymentId,
	};
}

async function dispatch(inputs: DispatchInputs, env: Env): Promise<boolean> {
	if (!nonEmpty(env.GITHUB_DISPATCH_TOKEN)) {
		console.error("dispatch skipped: GITHUB_DISPATCH_TOKEN not configured");
		return false;
	}
	const endpoint = `https://api.github.com/repos/${env.GITHUB_REPO}/actions/workflows/${WORKFLOW_FILE}/dispatches`;
	try {
		const response = await fetch(endpoint, {
			method: "POST",
			headers: {
				Authorization: `Bearer ${env.GITHUB_DISPATCH_TOKEN}`,
				Accept: "application/vnd.github+json",
				"X-GitHub-Api-Version": GITHUB_API_VERSION,
				"User-Agent": USER_AGENT,
				"Content-Type": "application/json",
			},
			body: JSON.stringify({ ref: WORKFLOW_REF, inputs }),
			signal: AbortSignal.timeout(DISPATCH_TIMEOUT_MS),
		});
		if (!response.ok) {
			console.error(`dispatch rejected by GitHub: HTTP ${response.status}`);
			return false;
		}
		return true;
	} catch (error) {
		console.error(`dispatch failed: ${error instanceof Error ? error.name : "unknown error"}`);
		return false;
	}
}

function path(value: unknown, ...keys: string[]): unknown {
	let current = value;
	for (const key of keys) {
		if (typeof current !== "object" || current === null) {
			return undefined;
		}
		current = (current as Record<string, unknown>)[key];
	}
	return current;
}

function str(value: unknown): string | undefined {
	return typeof value === "string" ? value : undefined;
}

function matches(pattern: RegExp, value: string | undefined): value is string {
	return value !== undefined && pattern.test(value);
}

function nonEmpty(value: string | undefined): value is string {
	return typeof value === "string" && value.length > 0;
}

function text(status: number, body?: string): Response {
	return new Response(status === 204 ? null : (body ?? null), {
		status,
		headers: { "Content-Type": "text/plain; charset=utf-8" },
	});
}
