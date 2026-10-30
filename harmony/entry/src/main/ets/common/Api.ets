import { http } from '@kit.NetworkKit';
import {
  AuthResult,
  DeviceItem,
  DeviceListResult,
  ErrorBody,
  LinkResult,
  SessionResult,
  SettingsResult,
  TurnInfo
} from './Types';

/** 服务端返回非 2xx 时抛出，携带 HTTP 状态码与服务端 error 文案。 */
export class ApiError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
    this.name = 'ApiError';
  }
}

export class Api {
  base: string = '';
  token: string = '';

  constructor(base: string, token: string) {
    this.setServer(base);
    this.token = token;
  }

  setServer(base: string): void {
    let b = base.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.length > 0 && !b.startsWith('http://') && !b.startsWith('https://')) {
      b = 'https://' + b;
    }
    this.base = b;
  }

  private async request(path: string, method: http.RequestMethod, body: string, auth: boolean): Promise<string> {
    if (this.base.length === 0) {
      throw new ApiError(0, '请先填写服务器地址');
    }
    const req = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      };
      if (auth && this.token.length > 0) {
        header['Authorization'] = 'Bearer ' + this.token;
      }
      const options: http.HttpRequestOptions = {
        method: method,
        header: header,
        connectTimeout: 15000,
        readTimeout: 20000,
        expectDataType: http.HttpDataType.STRING
      };
      if (body.length > 0) {
        options.extraData = body;
      }
      const res = await req.request(this.base + path, options);
      const text: string = typeof res.result === 'string' ? (res.result as string) : '';
      const code: number = res.responseCode;
      if (code < 200 || code >= 300) {
        let msg = 'HTTP ' + code;
        if (text.length > 0) {
          try {
            const err = JSON.parse(text) as ErrorBody;
            if (err !== null && err.error !== undefined && err.error.length > 0) {
              msg = err.error;
            }
          } catch (e) {
            // 非 JSON 错误体，保留默认文案
          }
        }
        throw new ApiError(code, msg);
      }
      return text;
    } finally {
      req.destroy();
    }
  }

  private static authBody(username: string, password: string, deviceName: string, deviceId: string): string {
    const body: Record<string, string> = {
      'username': username,
      'password': password,
      'device_name': deviceName,
      'os': 'harmonyos',
      'device_id': deviceId
    };
    return JSON.stringify(body);
  }

  async register(username: string, password: string, deviceName: string, deviceId: string): Promise<AuthResult> {
    const text = await this.request('/api/register', http.RequestMethod.POST,
      Api.authBody(username, password, deviceName, deviceId), false);
    const r = JSON.parse(text) as AuthResult;
    this.token = r.token;
    return r;
  }

  async login(username: string, password: string, deviceName: string, deviceId: string): Promise<AuthResult> {
    const text = await this.request('/api/login', http.RequestMethod.POST,
      Api.authBody(username, password, deviceName, deviceId), false);
    const r = JSON.parse(text) as AuthResult;
    this.token = r.token;
    return r;
  }

  async devices(): Promise<DeviceItem[]> {
    const text = await this.request('/api/devices', http.RequestMethod.GET, '', true);
    const r = JSON.parse(text) as DeviceListResult;
    return r.devices !== undefined ? r.devices : [];
  }

  /** 用对方账号密码查询其名下设备。 */
  async lookup(username: string, password: string): Promise<DeviceItem[]> {
    const body: Record<string, string> = { 'username': username, 'password': password };
    const text = await this.request('/api/session/lookup', http.RequestMethod.POST, JSON.stringify(body), true);
    const r = JSON.parse(text) as DeviceListResult;
    return r.devices !== undefined ? r.devices : [];
  }

  /** mode: same_account | account | link */
  async requestSession(payload: string): Promise<SessionResult> {
    const text = await this.request('/api/session/request', http.RequestMethod.POST, payload, true);
    return JSON.parse(text) as SessionResult;
  }

  async acceptSession(sessionId: string, accept: boolean): Promise<SessionResult> {
    const body: Record<string, string | boolean> = { 'session_id': sessionId, 'accept': accept };
    const text = await this.request('/api/session/accept', http.RequestMethod.POST, JSON.stringify(body), true);
    return JSON.parse(text) as SessionResult;
  }

  async cancelSession(sessionId: string): Promise<void> {
    const body: Record<string, string> = { 'session_id': sessionId };
    await this.request('/api/session/cancel', http.RequestMethod.POST, JSON.stringify(body), true);
  }

  async createLink(): Promise<LinkResult> {
    const text = await this.request('/api/link/create', http.RequestMethod.POST, '', true);
    return JSON.parse(text) as LinkResult;
  }

  async getSettings(): Promise<SettingsResult> {
    const text = await this.request('/api/settings', http.RequestMethod.GET, '', true);
    return JSON.parse(text) as SettingsResult;
  }

  async putSettings(autoAccept: boolean, mic: boolean, camera: boolean): Promise<void> {
    const body: Record<string, boolean> = {
      'auto_accept_same_account': autoAccept,
      'mic_enabled': mic,
      'camera_enabled': camera
    };
    await this.request('/api/settings', http.RequestMethod.PUT, JSON.stringify(body), true);
  }

  static turnFrom(obj: object | undefined): TurnInfo {
    const empty: TurnInfo = { urls: [], username: '', credential: '' };
    if (obj === undefined || obj === null) {
      return empty;
    }
    const t = obj as TurnInfo;
    if (t.urls === undefined || t.urls === null) {
      return empty;
    }
    return t;
  }
}