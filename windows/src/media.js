// 语音 / 摄像头协商的纯逻辑层。
//
// 这里刻意不引入 DOM、Tauri、WebRTC 任何依赖：所有函数都是「输入对象 → 输出对象」，
// 这样可以在 Node 里直接跑单测（scripts/media-policy.test.mjs），
// 也方便三端（Windows / Android / HarmonyOS）对照同一套语义。

/** 失败原因 → 用户可读文案。与 README 9.5.3 节保持一致。 */
export const MEDIA_REASONS = {
  policy_off: "被控端已在设置里关闭该权限",
  permission_denied: "系统权限未授予",
  no_device: "没有可用设备",
  busy: "设备被其他程序占用",
  unsupported: "该端不支持音视频",
};

/**
 * 把服务端下发的 media 政策归一化成 `{mic, camera}`。
 * 兼容两种写法：`{mic,camera}`（会话下发）与 `{mic_enabled,camera_enabled}`（设备列表）。
 */
export function normalizeMediaPolicy(raw) {
  const o = raw && typeof raw === "object" ? raw : {};
  return {
    mic: o.mic === true || o.mic_enabled === true,
    camera: o.camera === true || o.camera_enabled === true,
  };
}

/** 初始媒体状态：政策位已知，实际轨道都还没开。 */
export function emptyMediaState(policy) {
  const p = normalizeMediaPolicy(policy);
  return { mic: p.mic, camera: p.camera, micOn: false, camOn: false, reason: "" };
}

/**
 * 解析被控端发来的 `media_state`。字段缺失时保留上一次的已知值（服务端/旧版本可能不带）。
 */
export function parseMediaState(msg, prev) {
  const base = prev
    ? { ...prev }
    : { mic: false, camera: false, micOn: false, camOn: false, reason: "" };
  if (!msg || msg.t !== "media_state") return base;
  return {
    mic: msg.mic === true,
    camera: msg.camera === true,
    micOn: msg.mic_on === true,
    camOn: msg.cam_on === true,
    reason: typeof msg.reason === "string" ? msg.reason : "",
  };
}

/** 控制端的期望状态 → `media_req` 帧。 */
export function makeMediaReq(desired) {
  const d = desired && typeof desired === "object" ? desired : {};
  return { t: "media_req", mic: d.mic === true, camera: d.camera === true };
}

/** 被控端的本地状态 → `media_state` 帧。 */
export function makeMediaState(state) {
  const s = state && typeof state === "object" ? state : {};
  return {
    t: "media_state",
    mic: s.mic === true,
    camera: s.camera === true,
    mic_on: s.micOn === true,
    cam_on: s.camOn === true,
    reason: typeof s.reason === "string" ? s.reason : "",
  };
}

/** 轨道刚创建时通告对端「这个 track id 是麦克风还是摄像头」。 */
export function makeTrackAnnounce(kind, trackId) {
  return { t: "media_track", kind: kind === "camera" ? "camera" : "mic", id: String(trackId || "") };
}

/** 把 getUserMedia / 原生采集抛出的错误映射成协议里的 reason。 */
export function mediaErrorReason(err) {
  const name = (err && (err.name || err.code)) || "";
  switch (String(name)) {
    case "NotAllowedError":
    case "PermissionDeniedError":
    case "SecurityError":
      return "permission_denied";
    case "NotFoundError":
    case "DevicesNotFoundError":
    case "OverconstrainedError":
      return "no_device";
    case "NotReadableError":
    case "TrackStartError":
    case "AbortError":
      return "busy";
    default:
      return "unsupported";
  }
}

/**
 * 权限失败 → 可操作的提示。
 * `canOpenSettings` 为 true 时，UI 应显示「打开隐私设置」按钮。
 */
export function permissionHint(kind, err) {
  const reason = mediaErrorReason(err);
  const what = kind === "mic" ? "麦克风" : "摄像头";
  const detail = (err && err.message) || "未知错误";
  if (reason === "permission_denied") {
    return {
      reason,
      kind,
      what,
      canOpenSettings: true,
      text:
        `系统未允许使用${what}。点「打开${what}设置」，把「让桌面应用访问你的${what}」打开后重试。`,
    };
  }
  if (reason === "no_device") {
    return { reason, kind, what, canOpenSettings: false, text: `没有检测到可用的${what}。` };
  }
  if (reason === "busy") {
    return {
      reason,
      kind,
      what,
      canOpenSettings: false,
      text: `${what}正被其他程序占用（会议 / 直播软件常见），请关闭后重试。`,
    };
  }
  return {
    reason,
    kind,
    what,
    canOpenSettings: false,
    text: `${what}打开失败：${detail}`,
  };
}

/** reason → 提示文案（空串返回空串，方便直接 setText）。 */
export function reasonText(reason) {
  if (!reason) return "";
  return MEDIA_REASONS[reason] || `音视频不可用：${reason}`;
}

/**
 * 媒体状态 → 工具栏/横幅上的一行摘要。
 * 例：「麦克风 已开 · 摄像头 未开（关闭该权限）」
 */
export function describeMediaState(state) {
  const s = state || {};
  const fmt = (allowed, on, label) => {
    if (on) return `${label} 已开`;
    if (!allowed) return `${label} 已关闭权限`;
    return `${label} 未开`;
  };
  const parts = [fmt(s.mic, s.micOn, "麦克风"), fmt(s.camera, s.camOn, "摄像头")];
  const tail = reasonText(s.reason);
  return parts.join(" · ") + (tail ? ` · ${tail}` : "");
}

/**
 * 把轨道并入已有 MediaStream（去重），返回同一个 stream 方便持续使用。
 * 远端音频/摄像头可能分属不同 stream，这里统一收敛到一个播放用 stream。
 */
export function mergeTrack(stream, track) {
  if (!track) return stream;
  const list = stream ? stream.getTracks() : [];
  if (list.some((t) => t.id === track.id)) return stream;
  stream.addTrack(track);
  return stream;
}

/** 由 `media_track` 通告维护 trackId → kind 的映射。 */
export function trackKindMap(prev, msg) {
  const map = prev && typeof prev === "object" ? { ...prev } : {};
  if (msg && msg.t === "media_track" && msg.id) {
    map[String(msg.id)] = msg.kind === "camera" ? "camera" : "mic";
  }
  return map;
}

/**
 * 兜底判断：没有收到通告时，按 track id 前缀猜测（HarmonyOS/Android 侧用 `camera0` 命名）。
 */
export function guessTrackKind(trackId, kind) {
  if (kind === "audio") return "mic";
  const id = String(trackId || "");
  if (id.startsWith("camera")) return "camera";
  return "screen";
}
