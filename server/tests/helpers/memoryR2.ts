// Minimal in-memory R2Bucket for unit tests (supports put, get, head, delete, list with prefix + cursor).

interface StoredEntry {
  bytes: Uint8Array;
  httpMetadata: R2HTTPMetadata;
  etag: string;
}

async function toBytes(
  value: ReadableStream | ArrayBuffer | ArrayBufferView | string | Blob | null,
): Promise<Uint8Array> {
  if (value === null) return new Uint8Array(0);
  if (typeof value === 'string') return new TextEncoder().encode(value);
  if (value instanceof ArrayBuffer) return new Uint8Array(value.slice(0));
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
  }
  if (value instanceof Blob) {
    return new Uint8Array(await value.arrayBuffer());
  }
  const reader = value.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value: chunk } = await reader.read();
    if (done) break;
    const u8 = chunk instanceof Uint8Array ? chunk : new Uint8Array(chunk);
    chunks.push(u8);
    total += u8.byteLength;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}

function makeObjectMeta(key: string, entry: StoredEntry): R2Object {
  const copy = entry.httpMetadata;
  return {
    key,
    version: '1',
    size: entry.bytes.byteLength,
    etag: entry.etag,
    httpEtag: `"${entry.etag}"`,
    checksums: { toJSON: () => ({}) } as R2Checksums,
    uploaded: new Date(0),
    httpMetadata: copy,
    customMetadata: {},
    storageClass: 'Standard',
    writeHttpMetadata(headers: Headers) {
      if (copy.contentType) headers.set('content-type', copy.contentType);
    },
  };
}

export interface MemoryR2Bucket extends R2Bucket {
  keys(): string[];
  rawBytes(key: string): Uint8Array | undefined;
}

export function createMemoryR2(): MemoryR2Bucket {
  const store = new Map<string, StoredEntry>();
  let versionCounter = 0;

  const bucket: MemoryR2Bucket = {
    keys: () => Array.from(store.keys()).sort(),
    rawBytes: (key: string) => store.get(key)?.bytes,

    async head(key: string) {
      const entry = store.get(key);
      return entry ? makeObjectMeta(key, entry) : null;
    },

    async get(key: string) {
      const entry = store.get(key);
      if (!entry) return null;
      const bytes = new Uint8Array(entry.bytes);
      const body = new ReadableStream<Uint8Array>({
        start(controller) {
          if (bytes.byteLength > 0) controller.enqueue(bytes);
          controller.close();
        },
      });
      const meta = makeObjectMeta(key, entry);
      return {
        ...meta,
        body,
        bodyUsed: false,
        arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
        bytes: async () => new Uint8Array(bytes),
        text: async () => new TextDecoder().decode(bytes),
        json: async <T>() => JSON.parse(new TextDecoder().decode(bytes)) as T,
        blob: async () => new Blob([bytes]),
      } as unknown as R2ObjectBody;
    },

    async put(
      key: string,
      value: ReadableStream | ArrayBuffer | ArrayBufferView | string | Blob | null,
      options?: R2PutOptions,
    ) {
      const bytes = await toBytes(value);
      const httpMetadata: R2HTTPMetadata =
        options?.httpMetadata && !(options.httpMetadata instanceof Headers)
          ? { ...options.httpMetadata }
          : {};
      versionCounter += 1;
      const entry: StoredEntry = {
        bytes,
        httpMetadata,
        etag: `etag-${versionCounter}`,
      };
      store.set(key, entry);
      return makeObjectMeta(key, entry);
    },

    async delete(keys: string | string[]) {
      const list = Array.isArray(keys) ? keys : [keys];
      for (const k of list) {
        store.delete(k);
      }
    },

    async list(options?: R2ListOptions) {
      const prefix = options?.prefix ?? '';
      const limit = options?.limit ?? 1000;
      const startAfter = options?.cursor ? Number(options.cursor) : 0;
      const matched = Array.from(store.entries())
        .filter(([k]) => k.startsWith(prefix))
        .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
      const slice = matched.slice(startAfter, startAfter + limit);
      const nextOffset = startAfter + slice.length;
      const truncated = nextOffset < matched.length;
      return {
        objects: slice.map(([k, entry]) => makeObjectMeta(k, entry)),
        truncated,
        ...(truncated ? { cursor: String(nextOffset) } : {}),
        delimitedPrefixes: [],
      } as R2Objects;
    },

    createMultipartUpload() {
      throw new Error('Not implemented in memory R2');
    },
    resumeMultipartUpload() {
      throw new Error('Not implemented in memory R2');
    },
  };

  return bucket;
}
