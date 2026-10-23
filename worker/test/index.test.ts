import { beforeEach, describe, expect, it, vi } from "vitest";

import worker from "../src/index";
import { type Env, FORWARDED_EVENT_TYPES } from "../src/relay";

const PROJECT_ID = "11111111-1111-4111-8111-111111111111";
const ENVIRONMENT_ID = "22222222-2222-4222-8222-222222222222";
const SERVICE_ID = "33333333-3333-4333-8333-333333333333";
const DEPLOYMENT_ID = "44444444-4444-4444-8444-444444444444";
const SECRET = "test-webhook-secret";
const TOKEN = "test-dispatch-token";

const env: Env = {
	WEBHOOK_SECRET: SECRET,
	GITHUB_DISPATCH_TOKEN: TOKEN,
	RAILWAY_PROJECT_ID: PROJECT_ID,
	GITHUB_REPO: "kwmacioszek/szczur-radar-monitor",
};

const DISPATCH_URL =
	"https://api.github.com/repos/kwmacioszek/szczur-radar-monitor/actions/workflows/verify.yml/dispatches";

/** Shape of a Railway deployment webhook (fields the Worker reads plus a few it ignores). */
function payload(overrides: Record<string, unknown> = {}) {
	return {
		type: "Deployment.deployed",
		details: { commitHash: "abc123", source: "GitHub" },
		resource: {
			workspace: { id: "55555555-5555-4555-8555-555555555555", name: "ws" },
			project: { id: PROJECT_ID, name: "szczur-radar" },
			environment: { id: ENVIRONMENT_ID, name: "szczur-radar-pr-91", isEphemeral: true },
			service: { id: SERVICE_ID, name: "szczur-radar-api" },
			deployment: { id: DEPLOYMENT_ID },
		},
		...overrides,
	};
}

function withResource(patch: Record<string, unknown>) {
	const base = payload();
	return { ...base, resource: { ...base.resource, ...patch } };
}

function request(
	body: unknown,
	{ secret = SECRET as string | null, method = "POST", path = "/railway" } = {},
): Request {
	const headers = new Headers({ "Content-Type": "application/json" });
	if (secret !== null) {
		headers.set("X-Monitor-Secret", secret);
	}
	return new Request(`https://monitor.example.workers.dev${path}`, {
		method,
		headers,
		body: method === "GET" || method === "HEAD" ? undefined : typeof body === "string" ? body : JSON.stringify(body),
	});
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
	fetchMock = vi.fn(async () => new Response(null, { status: 204 }));
	vi.stubGlobal("fetch", fetchMock);
	vi.spyOn(console, "log").mockImplementation(() => {});
	vi.spyOn(console, "warn").mockImplementation(() => {});
	vi.spyOn(console, "error").mockImplementation(() => {});
});

describe("routing", () => {
	it.each([
		["GET", "/railway"],
		["PUT", "/railway"],
		["POST", "/"],
		["POST", "/railway/extra"],
	])("%s %s -> 404", async (method, path) => {
		const response = await worker.fetch(request(payload(), { method, path }), env);
		expect(response.status).toBe(404);
		expect(fetchMock).not.toHaveBeenCalled();
	});
});

describe("secret", () => {
	it.each([
		["missing", null],
		["wrong", "not-the-secret"],
		["empty", ""],
		["prefix of the secret", SECRET.slice(0, -1)],
	])("%s secret -> 401 without dispatch", async (_label, secret) => {
		const response = await worker.fetch(request(payload(), { secret }), env);
		expect(response.status).toBe(401);
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("misconfigured Worker (no WEBHOOK_SECRET) -> 500, never accepts an empty header", async () => {
		const response = await worker.fetch(request(payload(), { secret: "" }), { ...env, WEBHOOK_SECRET: "" });
		expect(response.status).toBe(500);
		expect(fetchMock).not.toHaveBeenCalled();
	});
});

describe("filtering", () => {
	it("foreign project -> 204 without dispatch", async () => {
		const body = withResource({ project: { id: "99999999-9999-4999-8999-999999999999", name: "other" } });
		const response = await worker.fetch(request(body), env);
		expect(response.status).toBe(204);
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("missing project -> 204 without dispatch", async () => {
		const body = withResource({ project: undefined });
		const response = await worker.fetch(request(body), env);
		expect(response.status).toBe(204);
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it.each(["Deployment.building", "Deployment.deploying", "Deployment.removed", "Volume.alert", "", undefined])(
		"type %s -> 204 without dispatch",
		async (type) => {
			const response = await worker.fetch(request(payload({ type })), env);
			expect(response.status).toBe(204);
			expect(fetchMock).not.toHaveBeenCalled();
		},
	);

	it("malformed JSON -> 400", async () => {
		const response = await worker.fetch(request("{not json"), env);
		expect(response.status).toBe(400);
		expect(fetchMock).not.toHaveBeenCalled();
	});
});

describe("field validation", () => {
	it.each([
		["environment id not a UUID", { environment: { id: "prod", name: "production" } }],
		["service id not a UUID", { service: { id: "x; rm -rf", name: "szczur-radar-api" } }],
		["deployment id missing", { deployment: {} }],
		["deployment id not a string", { deployment: { id: 42 } }],
		["environment name with spaces", { environment: { id: ENVIRONMENT_ID, name: "pr 91" } }],
		["environment name upper case", { environment: { id: ENVIRONMENT_ID, name: "Production" } }],
		["service name with shell chars", { service: { id: SERVICE_ID, name: "api$(id)" } }],
		["service name empty", { service: { id: SERVICE_ID, name: "" } }],
		["service name too long", { service: { id: SERVICE_ID, name: "a".repeat(65) } }],
		["service name with newline", { service: { id: SERVICE_ID, name: "api\nx" } }],
	])("%s -> 400 without dispatch", async (_label, patch) => {
		const response = await worker.fetch(request(withResource(patch)), env);
		expect(response.status).toBe(400);
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("name of exactly 64 characters is accepted", async () => {
		const name = "a".repeat(64);
		const response = await worker.fetch(request(withResource({ service: { id: SERVICE_ID, name } })), env);
		expect(response.status).toBe(202);
	});
});

describe("dispatch", () => {
	it.each(FORWARDED_EVENT_TYPES)("%s -> dispatch of verify.yml with sanitized inputs and ref main", async (type) => {
		const response = await worker.fetch(request(payload({ type })), env);

		expect(response.status).toBe(202);
		expect(fetchMock).toHaveBeenCalledTimes(1);
		const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
		expect(url).toBe(DISPATCH_URL);
		expect(init.method).toBe("POST");
		const headers = new Headers(init.headers);
		expect(headers.get("Authorization")).toBe(`Bearer ${TOKEN}`);
		expect(headers.get("Accept")).toBe("application/vnd.github+json");
		expect(headers.get("X-GitHub-Api-Version")).toBe("2022-11-28");
		expect(headers.get("User-Agent")).toBeTruthy();
		expect(JSON.parse(init.body as string)).toEqual({
			ref: "main",
			inputs: {
				event_type: type,
				environment_id: ENVIRONMENT_ID,
				environment_name: "szczur-radar-pr-91",
				service_name: "szczur-radar-api",
				deployment_id: DEPLOYMENT_ID,
			},
		});
	});

	it("forwards only the five inputs, never commit hash or other payload fields", async () => {
		await worker.fetch(request(payload()), env);
		const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
		const body = JSON.parse(init.body as string) as { inputs: Record<string, unknown> };
		expect(Object.keys(body.inputs).sort()).toEqual([
			"deployment_id",
			"environment_id",
			"environment_name",
			"event_type",
			"service_name",
		]);
		expect(Object.values(body.inputs).every((value) => typeof value === "string")).toBe(true);
	});

	it("upper-case UUIDs are normalized to lower case", async () => {
		const body = withResource({
			environment: { id: ENVIRONMENT_ID.toUpperCase(), name: "production" },
			deployment: { id: DEPLOYMENT_ID.toUpperCase() },
		});
		await worker.fetch(request(body), env);
		const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
		const { inputs } = JSON.parse(init.body as string) as { inputs: Record<string, string> };
		expect(inputs.environment_id).toBe(ENVIRONMENT_ID);
		expect(inputs.deployment_id).toBe(DEPLOYMENT_ID);
	});

	it.each([500, 503, 401, 404, 422])("GitHub HTTP %i -> 502 so Railway retries", async (status) => {
		fetchMock.mockResolvedValueOnce(new Response("nope", { status }));
		const response = await worker.fetch(request(payload()), env);
		expect(response.status).toBe(502);
	});

	it("network error -> 502", async () => {
		fetchMock.mockRejectedValueOnce(new TypeError("fetch failed"));
		const response = await worker.fetch(request(payload()), env);
		expect(response.status).toBe(502);
	});

	it("missing GITHUB_DISPATCH_TOKEN -> 502 without calling GitHub", async () => {
		const response = await worker.fetch(request(payload()), { ...env, GITHUB_DISPATCH_TOKEN: "" });
		expect(response.status).toBe(502);
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("never logs secrets or the request body", async () => {
		fetchMock.mockResolvedValueOnce(new Response("nope", { status: 500 }));
		await worker.fetch(request(payload()), env);
		await worker.fetch(request(payload()), env);
		await worker.fetch(request(payload(), { secret: "wrong" }), env);
		const logged = [console.log, console.warn, console.error]
			.flatMap((fn) => vi.mocked(fn).mock.calls.flat())
			.map(String)
			.join("\n");
		expect(logged).not.toContain(SECRET);
		expect(logged).not.toContain(TOKEN);
		expect(logged).not.toContain("abc123");
	});
});
