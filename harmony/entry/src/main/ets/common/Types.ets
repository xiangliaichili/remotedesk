/**
 * 与中转服务器交互的通用数据结构。
 * 字段名与 README《协议规范》一致（snake_case）。
 */

export interface DeviceItem {
  id: string;
  name: string;
  os: string;
  online: boolean;
  mic_enabled?: boolean;
  camera_enabled?: boolean;
}

export interface TurnInfo {
  urls: string[];
  username: string;
  credential: string;
}

/** 会话下发的媒体权限位（协议 4.2 节）。 */
export interface MediaPolicy {
  mic: boolean;
  camera: boolean;
}

export interface AuthResult {
  token: string;
  user_id: number;
  device_id: string;
  username: string;
}

export interface SessionResult {
  session_id: string;
  status: string;
  turn?: TurnInfo;
  media?: MediaPolicy;
}

export interface LinkResult {
  code: string;
  expires_at: string;
  ttl_minutes: number;
}

export interface SettingsResult {
  auto_accept_same_account: boolean;
  mic_enabled: boolean;
  camera_enabled: boolean;
}

/** 服务端支持的登录方式（v1.03）。 */
export interface AuthMethods {
  smsEnabled: boolean;
  smsDev: boolean;
  smsProvider: string;
  wechatEnabled: boolean;
  wechatDev: boolean;
}

/** 微信扫码会话。 */
export interface WechatSession {
  state: string;
  url: string;
  expiresIn: number;
}

/** 微信轮询结果：pending / ok / error / expired / consumed。 */
export interface WechatPollResult {
  status: string;
  message: string;
  token: string;
  userId: number;
  deviceId: string;
  username: string;
}

export interface DeviceListResult {
  devices: DeviceItem[];
}

export interface ErrorBody {
  error: string;
}

/** 三端统一的输入事件（坐标 0..1 归一化）。 */
export interface InputEvent {
  type: string;
  x?: number;
  y?: number;
  button?: number;
  dx?: number;
  dy?: number;
  action?: string;
  code?: string;
  key?: string;
  mods?: string;
  text?: string;
}

/** 从信令通道收到的消息（只解析用得到的字段）。 */
export interface SignalMessage {
  type: string;
  from?: string;
  to?: string;
  session_id?: string;
  sdp?: string;
  candidate?: string;
  data?: object;
  turn?: TurnInfo;
}

export interface SessionReqData {
  controller_name: string;
  auth_mode: string;
  media?: MediaPolicy;
}

export interface ControlStartData {
  controller_name: string;
  turn: TurnInfo;
  media?: MediaPolicy;
}

export interface SessionOkData {
  turn: TurnInfo;
  media?: MediaPolicy;
}

export interface ErrorData {
  message: string;
}