/**
 * Worker entry: only the default handler. workerd treats every named export of the main module as
 * an entrypoint and refuses a constant there, so the relay and its constants live in relay.ts.
 */
import { type Env, handle } from "./relay";

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		return handle(request, env);
	},
};
