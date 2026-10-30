import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 信令回调，全部在主线程触发。 */
export interface SignalListener {
  onOpen(): void;

  onMessage(text: string): void;

  onClosed(reason: string): void;
}

/**
 * 与中转服务器的 WebSocket 信令通道。
 * 首帧 {"type":"auth","data":"<JWT>"}，收到 auth_ok 才算真正就绪。
 */
export class Signaling {
  private ws: webSocket.WebSocket | null = null;
  private url: string = '';
  private closedByUser: boolean = false;
  private heartbeatId: number = -1;
  private opened: boolean = false;
  private pending: string[] = [];
  listener: SignalListener | null = null;

  constructor(baseUrl: string) {
    let b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.startsWith('https://')) {
      b = 'wss://' + b.substring('https://'.length);
    } else if (b.startsWith('http://')) {
      b = 'ws://' + b.substring('http://'.length);
    } else if (!b.startsWith('ws://') && !b.startsWith('wss://')) {
      b = 'wss://' + b;
    }
    this.url = b + '/ws';
  }

  connect(token: string): void {
    this.closedByUser = false;
    const ws = webSocket.createWebSocket();
    this.ws = ws;

    ws.on('open', (err: BusinessError, value: Object) => {
      if (err) {
        return;
      }
      this.opened = false;
      const auth: Record<string, string> = { 'type': 'auth', 'data': token };
      ws.send(JSON.stringify(auth), (e: BusinessError) => {
        if (e) {
          this.notifyClosed('发送鉴权帧失败');
        }
      });
    });

    ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (err || typeof value !== 'string') {
        return;
      }
      const text = value as string;
      if (!this.opened) {
        if (text.indexOf('"auth_ok"') >= 0) {
          this.opened = true;
          this.startHeartbeat();
          this.flushPending();
          if (this.listener !== null) {
            this.listener.onOpen();
          }
          return;
        }
        if (text.indexOf('"error"') >= 0) {
          this.notifyClosed(Signaling.extractError(text));
          return;
        }
      }
      if (this.listener !== null) {
        this.listener.onMessage(text);
      }
    });

    ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      this.stopHeartbeat();
      this.opened = false;
      if (!this.closedByUser) {
        this.notifyClosed('信令连接已断开');
      }
    });

    ws.on('error', (err: BusinessError) => {
      this.stopHeartbeat();
      if (!this.closedByUser) {
        this.notifyClosed('信令连接出错');
      }
    });

    ws.connect(this.url, (err: BusinessError) => {
      if (err) {
        this.notifyClosed('无法连接服务器：' + (err.message !== undefined ? err.message : ''));
      }
    });
  }

  sendJson(obj: string): void {
    if (!this.opened || this.ws === null) {
      this.pending.push(obj);
      return;
    }
    this.ws.send(obj, (err: BusinessError) => {
      // 发送失败不致命，交由重连逻辑处理
    });
  }

  private flushPending(): void {
    const list = this.pending;
    this.pending = [];
    for (let i = 0; i < list.length; i++) {
      this.sendJson(list[i]);
    }
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatId = setInterval(() => {
      const hb: Record<string, string> = { 'type': 'heartbeat' };
      this.sendJson(JSON.stringify(hb));
    }, 25000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatId !== -1) {
      clearInterval(this.heartbeatId);
      this.heartbeatId = -1;
    }
  }

  private notifyClosed(reason: string): void {
    this.stopHeartbeat();
    this.opened = false;
    if (this.listener !== null) {
      this.listener.onClosed(reason);
    }
  }

  private static extractError(text: string): string {
    try {
      const o = JSON.parse(text) as Record<string, Object>;
      const d = o['data'];
      if (d !== undefined && d !== null) {
        const d2 = d as Record<string, string>;
        if (d2['message'] !== undefined) {
          return d2['message'];
        }
      }
    } catch (e) {
      // ignore
    }
    return '服务器拒绝连接';
  }

  close(): void {
    this.closedByUser = true;
    this.stopHeartbeat();
    this.opened = false;
    this.pending = [];
    if (this.ws !== null) {
      this.ws.close((err: BusinessError) => {
        // ignore
      });
      this.ws = null;
    }
  }
}