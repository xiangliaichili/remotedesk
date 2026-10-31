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

  // ---------- 登录方式（v1.03） ----------

  /** 服务端支持哪些登录方式，未配置的入口前端就不显示。 */
  async authMethods() {
    return this.request("/api/auth/methods", { auth: false });
  }

  /** 发送短信验证码。dev 模式下响应里带 dev_code。 */
  async sendSmsCode(phone) {
    return this.request("/api/auth/sms/send", { method: "POST", body: { phone }, auth: false });
  }

  /** 手机号 + 验证码登录（首次自动建号）。 */
  async smsLogin(payload) {
    return this.request("/api/auth/sms/login", { method: "POST", body: payload, auth: false });
  }

  /** 拿微信扫码授权地址（一次性 state）。 */
  async wechatAuthUrl(device) {
    return this.request("/api/auth/wechat/url", { method: "POST", body: device, auth: false });
  }

  /** 轮询扫码结果：pending / ok / error / expired / consumed。 */
  async wechatPoll(state) {
    return this.request("/api/auth/wechat/poll", { method: "POST", body: { state }, auth: false });
  }

  /** 本地联调：模拟"已经扫码"。 */
  async wechatDevSimulate(state, openid, unionid) {
    return this.request("/api/auth/wechat/dev", {
      method: "POST",
      body: { state, openid, unionid },
      auth: false,
    });
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
