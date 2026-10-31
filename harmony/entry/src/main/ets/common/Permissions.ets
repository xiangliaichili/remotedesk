/**
 * 麦克风 / 摄像头运行时权限。
 *
 * HarmonyOS 的权限分两步：
 *  1. `module.json5` 的 `requestPermissions` 声明（已声明 MICROPHONE / CAMERA）；
 *  2. 首次使用前调用 `requestPermissionsFromUser` 弹系统授权框，用户点允许才真正可用。
 * 只做第 1 步的话 ArkWeb 里的 getUserMedia 会直接失败，且没有任何提示。
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

export interface MediaPermissionResult {
  mic: boolean;
  camera: boolean;
}

const MIC: Permissions = 'ohos.permission.MICROPHONE';
const CAMERA: Permissions = 'ohos.permission.CAMERA';

/** 0 = 已授权；-1 = 未授权（与 abilityAccessCtrl 的返回值一致）。 */
const GRANTED: number = 0;

function toResult(micCode: number, camCode: number): MediaPermissionResult {
  return { mic: micCode === GRANTED, camera: camCode === GRANTED };
}

/** 查询当前状态，不弹窗。 */
export async function checkMediaPermissions(ctx: common.UIAbilityContext): Promise<MediaPermissionResult> {
  try {
    const mgr = abilityAccessCtrl.createAtManager();
    const tokenId: number = ctx.applicationInfo.accessTokenId;
    const mic: number = await mgr.checkAccessToken(tokenId, MIC);
    const cam: number = await mgr.checkAccessToken(tokenId, CAMERA);
    return toResult(mic, cam);
  } catch (e) {
    const err = e as BusinessError;
    console.error('checkMediaPermissions failed: ' + err.message);
    return { mic: false, camera: false };
  }
}

/**
 * 申请（未授权时才弹窗）。只申请需要的那几项，避免无意义的系统弹窗。
 * 返回申请后的真实状态 —— 用户可能点「禁止」。
 */
export async function ensureMediaPermissions(
  ctx: common.UIAbilityContext,
  needMic: boolean,
  needCamera: boolean
): Promise<MediaPermissionResult> {
  const current = await checkMediaPermissions(ctx);
  const want: Permissions[] = [];
  if (needMic && !current.mic) {
    want.push(MIC);
  }
  if (needCamera && !current.camera) {
    want.push(CAMERA);
  }
  if (want.length === 0) {
    return current;
  }
  try {
    const mgr = abilityAccessCtrl.createAtManager();
    const res = await mgr.requestPermissionsFromUser(ctx, want);
    let mic = current.mic;
    let cam = current.camera;
    for (let i = 0; i < res.permissions.length; i++) {
      const p = res.permissions[i];
      const ok = res.authResults[i] === GRANTED;
      if (p === MIC) {
        mic = ok;
      } else if (p === CAMERA) {
        cam = ok;
      }
    }
    return { mic, camera: cam };
  } catch (e) {
    const err = e as BusinessError;
    console.error('requestPermissionsFromUser failed: ' + err.message);
    return current;
  }
}

/** 权限被拒时的可读提示。 */
export function deniedHint(r: MediaPermissionResult, needMic: boolean, needCamera: boolean): string {
  const parts: string[] = [];
  if (needMic && !r.mic) {
    parts.push('麦克风');
  }
  if (needCamera && !r.camera) {
    parts.push('摄像头');
  }
  if (parts.length === 0) {
    return '';
  }
  return '未获得' + parts.join('、') + '权限，可在「设置 → 应用 → 权限」中开启。';
}
