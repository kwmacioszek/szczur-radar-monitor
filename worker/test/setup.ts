// Node's Web Crypto lacks the Cloudflare-only `crypto.subtle.timingSafeEqual`; tests get a
// byte-wise stand-in with the same contract (equal length required) so `src/` keeps the real call.
type Bytes = ArrayBuffer | ArrayBufferView;

function view(value: Bytes): Uint8Array {
	return ArrayBuffer.isView(value)
		? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
		: new Uint8Array(value);
}

const subtle = crypto.subtle as SubtleCrypto & { timingSafeEqual?: (a: Bytes, b: Bytes) => boolean };
if (typeof subtle.timingSafeEqual !== "function") {
	Object.defineProperty(Object.getPrototypeOf(subtle), "timingSafeEqual", {
		configurable: true,
		value(a: Bytes, b: Bytes): boolean {
			const left = view(a);
			const right = view(b);
			if (left.byteLength !== right.byteLength) {
				throw new TypeError("Input buffers must have the same byte length");
			}
			let diff = 0;
			for (let i = 0; i < left.byteLength; i++) {
				diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
			}
			return diff === 0;
		},
	});
}
