import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

const STORE_NAME: string = 'remotedesk';
const K_SERVER: string = 'server';
const K_TOKEN: string = 'token';
const K_USER: string = 'username';
const K_DEVICE_ID: string = 'device_id';
const K_DEVICE_NAME: string = 'device_name';
const K_QUALITY: string = 'quality';

/** 本地持久化（账号、令牌、稳定设备 ID、画质偏好）。 */
export class Prefs {
  private static store: preferences.Preferences | null = null;

  static init(ctx: common.Context): void {
    if (Prefs.store !== null) {
      return;
    }
    Prefs.store = preferences.getPreferencesSync(ctx, { name: STORE_NAME });
  }

  private static s(): preferences.Preferences {
    if (Prefs.store === null) {
      throw new Error('Prefs 未初始化');
    }
    return Prefs.store;
  }

  private static read(key: string, def: string): string {
    const v = Prefs.s().getSync(key, def);
    if (typeof v === 'string') {
      return v as string;
    }
    return def;
  }

  private static write(key: string, value: string): void {
    Prefs.s().putSync(key, value);
    Prefs.s().flushSync();
  }

  static server(): string {
    return Prefs.read(K_SERVER, '');
  }

  static setServer(v: string): void {
    let s = v.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.length > 0 && !s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://' + s;
    }
    Prefs.write(K_SERVER, s);
  }

  static token(): string {
    return Prefs.read(K_TOKEN, '');
  }

  static username(): string {
    return Prefs.read(K_USER, '');
  }

  static setAuth(token: string, username: string): void {
    Prefs.write(K_TOKEN, token);
    Prefs.write(K_USER, username);
  }

  /** 设备 ID 一旦生成便长期复用，保证“同账号多设备”能区分。 */
  static deviceId(): string {
    let id = Prefs.read(K_DEVICE_ID, '');
    if (id.length === 0) {
      id = util.generateRandomUUID(false);
      Prefs.write(K_DEVICE_ID, id);
    }
    return id;
  }

  static deviceName(): string {
    return Prefs.read(K_DEVICE_NAME, '我的鸿蒙设备');
  }

  static setDeviceName(v: string): void {
    Prefs.write(K_DEVICE_NAME, v.trim().length > 0 ? v.trim() : '我的鸿蒙设备');
  }

  static quality(): string {
    return Prefs.read(K_QUALITY, 'normal');
  }

  static setQuality(v: string): void {
    Prefs.write(K_QUALITY, v);
  }

  static clearAuth(): void {
    Prefs.write(K_TOKEN, '');
    Prefs.write(K_USER, '');
  }
}