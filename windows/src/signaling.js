// WebSocket 信令客户端，含心跳与自动重连
export class Signaling {
  constructor(baseUrl) {
    const u = new URL(baseUrl);
    const wsProto = u.protocol === "https:" ? "wss:" : "ws:";
    this.url = `${wsProto}//${u.host}/ws`;
    this.token = null;
    this.ws = null;
    this.handlers = new Map();
    this.authed = false;
    this.closedByUser = false;
    this._hb = null;
    this._retry = 0;
  }

  on(type, cb) {
    if (!this.handlers.has(type)) this.handlers.set(type, []);
    this.handlers.get(type).push(cb);
  }

  emit(type, msg) {
    (this.handlers.get(type) || []).forEach((cb) => {
      try {
        cb(msg);
      } catch (e) {
        console.error("handler error", type, e);
      }
    });
  }

  /** 建立连接并在 auth_ok 后 resolve */
  connect(token) {
    this.token = token;
    this.closedByUser = false;
    return new Promise((resolve, reject) => {
      let settled = false;
      try {
        this.ws = new WebSocket(this.url);
      } catch (e) {
        reject(e);
        return;
      }

      this.ws.onopen = () => {
        this.send({ type: "auth", data: this.token });
      };

      this.ws.onmessage = (ev) => {
        let msg;
        try {
          msg = JSON.parse(ev.data);
        } catch {
          return;
        }
        if (msg.type === "auth_ok") {
          this.authed = true;
          this._retry = 0;
          this.startHeartbeat();
          if (!settled) {
            settled = true;
            resolve(msg);
          }
          return;
        }
        if (msg.type === "error" && !settled) {
          settled = true;
          reject(new Error((msg.data && msg.data.message) || "信令鉴权失败"));
          return;
        }
        this.emit(msg.type, msg);
      };

      this.ws.onclose = () => {
        this.authed = false;
        this.stopHeartbeat();
        this.emit("disconnected", {});
        if (!settled) {
          settled = true;
          reject(new Error("信令连接失败"));
        }
        if (!this.closedByUser) this.scheduleReconnect();
      };

      this.ws.onerror = () => {
        if (!settled) {
          settled = true;
          reject(new Error("信令连接错误"));
        }
      };
    });
  }

  scheduleReconnect() {
    const delay = Math.min(15000, 800 * Math.pow(2, this._retry++));
    setTimeout(async () => {
      if (this.closedByUser || !this.token) return;
      try {
        await this.connect(this.token);
        this.emit("reconnected", {});
      } catch {
        /* 继续重试由 onclose 触发 */
      }
    }, delay);
  }

  startHeartbeat() {
    this.stopHeartbeat();
    this._hb = setInterval(() => this.send({ type: "heartbeat" }), 25000);
  }

  stopHeartbeat() {
    if (this._hb) clearInterval(this._hb);
    this._hb = null;
  }

  send(obj) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(obj));
      return true;
    }
    return false;
  }

  close() {
    this.closedByUser = true;
    this.stopHeartbeat();
    if (this.ws) this.ws.close();
    this.ws = null;
  }
}
