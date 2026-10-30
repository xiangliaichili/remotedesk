// REST 客户端：账号、设备、会话、链接、设置
export class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

export class Api {
  constructor(baseUrl) {
    this.base = (baseUrl || "").replace(/\/+$/, "");
    this.token = null;
  }

  setServer(baseUrl) {
    this.base = (baseUrl || "").replace(/\/+$/, "");
  }

  async request(path, { method = "GET", body, auth = true } = {}) {
    const headers = { "Content-Type": "application/json" };
    if (auth && this.token) headers["Authorization"] = `Bearer ${this.token}`;
    const res = await fetch(this.base + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = { raw: text };
    }
    if (!res.ok) {
      throw new ApiError((data && data.error) || `HTTP ${res.status}`, res.status);
    }
    return data;
  }

  async register(payload) {
    return this.request("/api/register", { method: "POST", body: payload, auth: false });
  }

  async login(payload) {
    return this.request("/api/login", { method: "POST", body: payload, auth: false });
  }

  async devices() {
    return this.request("/api/devices");
  }

  async lookup(username, password) {
    return this.request("/api/session/lookup", { method: "POST", body: { username, password } });
  }

  async requestSession(payload) {
    return this.request("/api/session/request", { method: "POST", body: payload });
  }

  async acceptSession(sessionId, accept) {
    return this.request("/api/session/accept", {
      method: "POST",
      body: { session_id: sessionId, accept },
    });
  }

  async cancelSession(sessionId) {
    return this.request("/api/session/cancel", { method: "POST", body: { session_id: sessionId } });
  }

  async createLink() {
    return this.request("/api/link/create", { method: "POST", body: {} });
  }

  async getSettings() {
    return this.request("/api/settings");
  }

  async putSettings(patch) {
    return this.request("/api/settings", { method: "PUT", body: patch });
  }
}
