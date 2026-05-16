// Thin API wrapper — fetch with bearer token + JSON.

const TOKEN_KEY = "titan-token";

export const getToken = () => localStorage.getItem(TOKEN_KEY);
export const setToken = (t) => localStorage.setItem(TOKEN_KEY, t);
export const clearToken = () => localStorage.removeItem(TOKEN_KEY);

async function request(method, path, body, extraHeaders = {}) {
  const headers = {
    "Content-Type": "application/json",
    ...extraHeaders,
  };
  const token = getToken();
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await fetch(path, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });

  if (res.status === 401) {
    clearToken();
    if (!path.includes("/auth/login")) {
      window.location.href = "/login";
    }
    throw new Error("Unauthorized");
  }

  if (!res.ok) {
    let detail = res.statusText;
    try {
      const data = await res.json();
      detail = data.detail || JSON.stringify(data);
    } catch {
      // noop
    }
    throw new Error(detail);
  }

  if (res.status === 204) return null;
  return res.json();
}

export const api = {
  get: (p) => request("GET", p),
  post: (p, b) => request("POST", p, b),
  patch: (p, b) => request("PATCH", p, b),
  delete: (p) => request("DELETE", p),
};

// --- Multipart S3 upload ---
//
// Uploads a file directly to S3 using presigned URLs from our backend.
// onProgress receives fractions 0..1.
export async function uploadFileMultipart(file, onProgress) {
  // 1. Init
  const init = await api.post("/api/uploads/init", {
    filename: file.name,
    size_bytes: file.size,
  });

  const { upload_id, part_urls, part_size_bytes } = init;

  // 2. Upload parts in parallel (limit concurrency to 8)
  const completedParts = new Array(part_urls.length);
  let done = 0;
  const concurrency = 8;
  let cursor = 0;

  async function uploadOne(index) {
    const { part_number, url } = part_urls[index];
    const start = (part_number - 1) * part_size_bytes;
    const end = Math.min(start + part_size_bytes, file.size);
    const blob = file.slice(start, end);

    const res = await fetch(url, { method: "PUT", body: blob });
    if (!res.ok) throw new Error(`part ${part_number} failed: ${res.status}`);
    const etag = res.headers.get("ETag");
    if (!etag) throw new Error(`part ${part_number} returned no ETag`);

    completedParts[index] = { PartNumber: part_number, ETag: etag.replace(/"/g, "") };
    done += 1;
    if (onProgress) onProgress(done / part_urls.length);
  }

  async function worker() {
    while (cursor < part_urls.length) {
      const i = cursor++;
      await uploadOne(i);
    }
  }

  await Promise.all(Array.from({ length: concurrency }, worker));

  // 3. Complete
  await api.post(`/api/uploads/${upload_id}/complete`, {
    parts: completedParts,
  });

  return { upload_id, filename: file.name, size_bytes: file.size };
}
