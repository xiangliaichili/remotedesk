// UI 主控逻辑
import { invoke } from "@tauri-apps/api/core";
import { Api } from "./api.js";
import { Signaling } from "./signaling.js";
import { PeerSession } from "./session.js";
import {
  describeMediaState,
  normalizeMediaPolicy,
} from "./media.js";

const $ = (id) => document.getElementById(id);

const HISTORY_KEY = "rd_history";
const AUDIO_MUTED_KEY = "rd_audio_muted";

const state = {
  api: new Api(""),
  signaling: null,
  session: null,
  sessionId: null,
  peerDeviceId: null,
  deviceId: localStorage.getItem("rd_device_id") || crypto.randomUUID(),
  deviceName: "Windows 电脑",
  user: null,
  devices: [],
  settings: {},
  // 本机允许对方使用的媒体能力（= 设置里的两个开关）
  mediaPolicy: normalizeMediaPolicy(null),
  // 本次会话中对方允许的媒体能力（服务端下发）
  peerMedia: normalizeMediaPolicy(null),
  // 控制端希望收到的媒体（本地 UI 状态，与 session.desired 同步）
  desired: { mic: false, camera: false },
  audioMuted: localStorage.getItem(AUDIO_MUTED_KEY) === "1",
  privacy: null,
  server: localStorage.getItem("rd_server") || "http://127.0.0.1:8443",
  mode: null, // controller | controlled
  linkTimer: null,
  // ---- 登录方式（v1.03） ----
  authMethods: { sms: { enabled: false, dev: false }, wechat: { enabled: false, dev: false } },
  smsTimer: null,
  wxState: null,
  wxUrl: null,
};
localStorage.setItem("rd_device_id", state.deviceId);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------- 视图切换 ----------------
function show(view) {
  for (const id of ["view-auth", "view-home", "view-remote"]) {
    $(id).classList.toggle("hidden", id !== `view-${view}`);
  }
}
function toast(text) {
  const el = $("control-toast");
  el.classList.remove("hidden");
  $("toast-text").textContent = text;
}
function hideToast() {
  $("control-toast").classList.add("hidden");
}
function err(elId, msg) {
  $(elId).textContent = msg || "";
}

// ---------------- 初始化 ----------------
async function boot() {
  $("server-url").value = state.server;
  $("server-hint").textContent = "本地测试：先跑 scripts\\quickstart.ps1，这里填 http://127.0.0.1:8443";
  try {
    const info = await invoke("device_info");
    state.deviceName = info.name || state.deviceName;
  } catch {
    /* 非 Tauri 环境忽略 */
  }
  $("device-hint").textContent = `本机设备：${state.deviceName}（ID ${state.deviceId.slice(0, 8)}）`;

  $("btn-login").onclick = () => doAuth("login");
  $("btn-register").onclick = () => doAuth("register");
  $("btn-logout").onclick = logout;  $("btn-refresh").onclick = refreshDevices;
  $("btn-gen-link").onclick = genLink;
  $("btn-use-link").onclick = useLink;
  $("btn-copy-link").onclick = () => {
    navigator.clipboard.writeText($("link-code").textContent).catch(() => {});
  };
  $("btn-settings").onclick = openSettings;
  $("settings-close").onclick = saveSettings;
  $("btn-end").onclick = endControl;
  $("toast-cancel").onclick = endControl;
  $("btn-send-file").onclick = () => state.session && state.session.pickAndSendFile();
  $("btn-fullscreen").onclick = toggleFullscreen;
  $("btn-quality").onclick = cycleQuality;
  $("req-accept").onclick = () => respondRequest(true);
  $("req-deny").onclick = () => respondRequest(false);

  // ---- 语音 / 摄像头 ----
  $("btn-mic").onclick = () => toggleMedia("mic");
  $("btn-camera").onclick = () => toggleMedia("camera");
  $("btn-audio").onclick = toggleAudioMute;
  $("cam-pip-close").onclick = () => toggleMedia("camera");
  $("toast-mic").onclick = () => stopLocalMedia("mic");
  $("toast-cam").onclick = () => stopLocalMedia("camera");
  $("btn-media-check").onclick = refreshMediaCheck;
  $("btn-open-cam-settings").onclick = () => openPrivacySettings("camera");
  $("btn-open-mic-settings").onclick = () => openPrivacySettings("microphone");
  $("media-modal-close").onclick = () => $("media-modal").classList.add("hidden");
  $("media-modal-settings").onclick = () => {
    openPrivacySettings(state.mediaModalKind || "camera");
    $("media-modal").classList.add("hidden");
  };
  renderAudioButton();
  bindAuthTabs();

  // 回车提交
  $("password").addEventListener("keydown", (e) => {
    if (e.key === "Enter") doAuth("login");
  });
}

// ---------------- 登录 / 注册 ----------------

/** 校验并保存服务器地址，三种登录方式共用。 */
function prepareServer() {
  const server = $("server-url").value.trim();
  if (!server) {
    err("auth-error", "请填写服务器地址");
    return false;
  }
  state.server = server.replace(/\/+$/, "");
  localStorage.setItem("rd_server", state.server);
  state.api.setServer(state.server);
  return true;
}

/** 三种登录方式成功后的统一收尾。 */
async function afterLogin(res) {
  state.api.token = res.token;
  state.api.deviceId = res.device_id;
  state.deviceId = res.device_id;
  localStorage.setItem("rd_device_id", res.device_id);
  state.user = { id: res.user_id, name: res.username };
  await connectSignaling(res.token);
  $("self-name").textContent = `${res.username} · ${state.deviceName}`;
  show("home");
  await refreshDevices();
  await loadSettings();
  refreshMediaCheck();
  renderHistory();
}

async function doAuth(kind) {
  err("auth-error", "");
  if (!prepareServer()) return;

  const payload = {
    username: $("username").value.trim(),
    password: $("password").value,
    device_name: state.deviceName,
    os: "windows",
    device_id: state.deviceId,
  };
  try {
    const res = kind === "login" ? await state.api.login(payload) : await state.api.register(payload);
    await afterLogin(res);
  } catch (e) {
    err("auth-error", e.message || "登录失败");
  }
}

// ---------------- 登录方式：开关与切页 ----------------

function bindAuthTabs() {
  document.querySelectorAll(".tab").forEach((t) => {
    t.onclick = () => switchTab(t.dataset.tab);
  });
  $("btn-sms-send").onclick = sendSms;
  $("btn-sms-login").onclick = smsLogin;
  $("btn-wx-start").onclick = wechatStart;
  $("btn-wx-reopen").onclick = () => {
    if (state.wxUrl) invoke("open_url", { url: state.wxUrl }).catch(() => {});
  };
  $("btn-wx-dev").onclick = wechatSimulate;
  $("server-url").addEventListener("change", loadAuthMethods);
  loadAuthMethods();
}

function switchTab(name) {
  document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("active", t.dataset.tab === name));
  for (const id of ["tab-pwd", "tab-sms", "tab-wx"]) {
    $(id).classList.toggle("hidden", id !== `tab-${name}`);
  }
  err("auth-error", "");
}

/** 问服务端支持哪些登录方式，没配的入口直接隐藏。 */
async function loadAuthMethods() {
  const server = $("server-url").value.trim();
  if (!server) return;
  try {
    state.api.setServer(server.replace(/\/+$/, ""));
    const m = await state.api.authMethods();
    state.authMethods = {
      sms: m.sms || { enabled: false },
      wechat: m.wechat || { enabled: false },
    };
  } catch {
    return; // 服务器没起来时保持默认，不打扰用户
  }
  document.querySelector('.tab[data-tab="sms"]').classList.toggle("hidden", !state.authMethods.sms.enabled);
  document.querySelector('.tab[data-tab="wx"]').classList.toggle("hidden", !state.authMethods.wechat.enabled);
  $("btn-wx-dev").classList.toggle("hidden", !state.authMethods.wechat.dev);
  if (!state.authMethods.sms.enabled) $("sms-hint").textContent = "服务端未开启短信登录";
  if (state.authMethods.sms.dev) $("sms-hint").textContent = "开发模式：验证码会自动填入";
}

// ---------------- 手机验证码登录 ----------------

const PHONE_RE = /^1[3-9]\d{9}$/;

async function sendSms() {
  err("auth-error", "");
  if (!prepareServer()) return;
  const phone = $("sms-phone").value.trim();
  if (!PHONE_RE.test(phone)) {
    err("auth-error", "请输入 11 位手机号");
    return;
  }
  const btn = $("btn-sms-send");
  btn.disabled = true;
  try {
    const r = await state.api.sendSmsCode(phone);
    if (r.dev_code) {
      $("sms-code").value = r.dev_code;
      $("sms-hint").textContent = "开发模式：验证码已自动填入（" + r.dev_code + "）";
    } else {
      $("sms-hint").textContent = "验证码已发送，5 分钟内有效";
    }
    startSmsCountdown(r.resend_after || 60);
  } catch (e) {
    btn.disabled = false;
    err("auth-error", e.message || "发送失败");
  }
}

function startSmsCountdown(seconds) {
  const btn = $("btn-sms-send");
  let left = seconds;
  btn.disabled = true;
  if (state.smsTimer) clearInterval(state.smsTimer);
  const tick = () => {
    if (left <= 0) {
      clearInterval(state.smsTimer);
      state.smsTimer = null;
      btn.disabled = false;
      btn.textContent = "重新获取";
      return;
    }
    btn.textContent = `${left}s`;
    left--;
  };
  tick();
  state.smsTimer = setInterval(tick, 1000);
}

async function smsLogin() {
  err("auth-error", "");
  if (!prepareServer()) return;
  const phone = $("sms-phone").value.trim();
  const code = $("sms-code").value.trim();
  if (!PHONE_RE.test(phone)) return err("auth-error", "请输入 11 位手机号");
  if (!/^\d{6}$/.test(code)) return err("auth-error", "请输入 6 位验证码");
  const btn = $("btn-sms-login");
  btn.disabled = true;
  try {
    const r = await state.api.smsLogin({
      phone,
      code,
      device_name: state.deviceName,
      os: "windows",
      device_id: state.deviceId,
    });
    await afterLogin(r);
  } catch (e) {
    err("auth-error", e.message || "登录失败");
  } finally {
    btn.disabled = false;
  }
}

// ---------------- 微信扫码登录 ----------------

async function wechatStart() {
  err("auth-error", "");
  if (!prepareServer()) return;
  if (!state.authMethods.wechat.enabled) {
    $("wx-hint").textContent = "服务端未配置微信登录（需要 RD_WECHAT_APP_ID / RD_WECHAT_APP_SECRET）";
    return;
  }
  try {
    const r = await state.api.wechatAuthUrl({
      device_name: state.deviceName,
      os: "windows",
      device_id: state.deviceId,
    });
    state.wxState = r.state;
    state.wxUrl = r.url;
    $("btn-wx-reopen").classList.remove("hidden");
    $("wx-hint").textContent = "已打开授权页，用微信扫码后会自动登录…";
    await invoke("open_url", { url: r.url });
    pollWechat();
  } catch (e) {
    err("auth-error", e.message || "发起微信登录失败");
  }
}

async function pollWechat() {
  const st = state.wxState;
  if (!st) return;
  const started = Date.now();
  while (state.wxState === st && Date.now() - started < 10 * 60 * 1000) {
    await sleep(2000);
    if (state.wxState !== st) return;
    try {
      const r = await state.api.wechatPoll(st);
      if (r.status === "ok") {
        state.wxState = null;
        $("wx-hint").textContent = "登录成功";
        await afterLogin(r);
        return;
      }
      if (r.status === "error") {
        state.wxState = null;
        $("wx-hint").textContent = "登录失败：" + (r.message || "授权被拒绝");
        return;
      }
      if (r.status === "expired" || r.status === "consumed") {
        state.wxState = null;
        $("wx-hint").textContent = "二维码已失效，请重新发起";
        return;
      }
      $("wx-hint").textContent = `等待扫码…（${Math.round((Date.now() - started) / 1000)}s）`;
    } catch {
      // 网络抖动继续轮询
    }
  }
}

/** 开发模式下跳过真实微信，直接伪造"已扫码"。 */
async function wechatSimulate() {
  if (!state.wxState) return err("auth-error", "请先点「打开微信扫码登录」");
  try {
    await state.api.wechatDevSimulate(state.wxState, "dev-openid-" + state.deviceId.slice(0, 8), "");
    $("wx-hint").textContent = "已模拟扫码，正在登录…";
  } catch (e) {
    err("auth-error", e.message || "模拟失败");
  }
}

function logout() {
  if (state.session) endControl();
  if (state.signaling) state.signaling.close();
  state.signaling = null;
  state.api.token = null;
  state.user = null;
  state.wxState = null;
  state.wxUrl = null;
  show("auth");
  switchTab("pwd");
  loadAuthMethods();
}

// ---------------- 信令 ----------------
async function connectSignaling(token) {
  if (state.signaling) state.signaling.close();
  const sig = new Signaling(state.server);
  state.signaling = sig;

  sig.on("disconnected", () => setConnState(false));
  sig.on("reconnected", () => {
    setConnState(true);
    refreshDevices();
  });
  sig.on("session_req", onSessionReq);
  sig.on("session_ok", onSessionOk);
  sig.on("session_deny", () => {
    alert("对方拒绝了控制请求");
    state.pendingSessionId = null;
  });
  sig.on("control_start", onControlStart);
  sig.on("control_end", () => {
    if (state.mode === "controlled" || state.mode === "controller") endControl(true);
  });
  sig.on("offer", (m) => state.session && state.session.handleOffer(m.sdp));
  sig.on("answer", (m) => state.session && state.session.handleAnswer(m.sdp));
  sig.on("ice", (m) => state.session && state.session.handleIce(m.candidate));
  sig.on("devices", (m) => renderDevices(m.data || []));

  await sig.connect(token);
  setConnState(true);
}

function setConnState(online) {
  const d = $("conn-state");
  d.classList.toggle("online", online);
  d.classList.toggle("offline", !online);
  d.title = online ? "信令已连接" : "信令断开，重连中…";
}

// ---------------- 设备 ----------------
async function refreshDevices() {
  try {
    const res = await state.api.devices();
    renderDevices(res.devices || []);
  } catch (e) {
    console.warn("refresh devices failed", e);
  }
}

function renderDevices(list) {
  state.devices = list;
  const ul = $("device-list");
  ul.innerHTML = "";
  const others = list.filter((d) => d.id !== state.deviceId);
  $("devices-empty").classList.toggle("hidden", others.length > 0);
  for (const d of list) {
    const li = document.createElement("li");
    li.className = "device-item" + (d.id === state.deviceId ? " self" : "");
    const online = d.id === state.deviceId ? true : d.online;
    const osName = { windows: "Windows", android: "Android", harmonyos: "HarmonyOS", linux: "Linux", macos: "macOS" }[d.os] || d.os;
    const media = [
      d.mic_enabled ? "语音" : "",
      d.camera_enabled ? "摄像头" : "",
    ].filter(Boolean).join("/");
    li.innerHTML = `
      <span class="dot ${online ? "online" : "offline"}"></span>
      <div class="meta">
        <div class="name">${escapeHtml(d.name)}${d.id === state.deviceId ? "（本机）" : ""}</div>
        <div class="os">${osName} · ${online ? "在线" : "离线"}${media ? " · 开放 " + media : ""}</div>
      </div>`;
    if (d.id !== state.deviceId) {
      const btn = document.createElement("button");
      btn.className = "btn small primary";
      btn.textContent = "连接";
      btn.disabled = !d.online;
      btn.onclick = () => connectSameAccount(d);
      li.appendChild(btn);
    }
    ul.appendChild(li);
  }
  renderHistory();
}

async function connectSameAccount(dev) {
  try {
    const res = await state.api.requestSession({
      target_device_id: dev.id,
      auth: { mode: "same_account" },
    });
    state.pendingSessionId = res.session_id;
    state.peerDeviceId = dev.id;
    state.peerMedia = normalizeMediaPolicy(res.media);
    if (res.status === "active") {
      await startController(res.session_id, dev.id, res.turn, dev.name, res.media);
    } else {
      toast(`已向「${dev.name}」发送控制请求，等待对方同意…`);
    }
  } catch (e) {
    alert("连接失败：" + e.message);
  }
}

// ---------------- 最近连接 ----------------
function readHistory() {
  try {
    const list = JSON.parse(localStorage.getItem(HISTORY_KEY) || "[]");
    return Array.isArray(list) ? list.filter((x) => x && x.id && x.id !== state.deviceId) : [];
  } catch {
    return [];
  }
}

function pushHistory(dev) {
  if (!dev || !dev.id || dev.id === state.deviceId) return;
  const list = readHistory().filter((x) => x.id !== dev.id);
  list.unshift({ id: dev.id, name: dev.name || "设备", os: dev.os || "", at: Date.now() });
  localStorage.setItem(HISTORY_KEY, JSON.stringify(list.slice(0, 6)));
}

function renderHistory() {
  const list = readHistory();
  $("history-block").classList.toggle("hidden", list.length === 0);
  const ul = $("history-list");
  ul.innerHTML = "";
  for (const h of list) {
    const online = state.devices.find((d) => d.id === h.id);
    const li = document.createElement("li");
    li.className = "history-item";
    const mins = Math.max(0, Math.round((Date.now() - h.at) / 60000));
    li.innerHTML = `<span class="dot ${online && online.online ? "online" : "offline"}"></span>
      <span class="hist-name">${escapeHtml(h.name)}</span>
      <span class="muted small">${mins < 1 ? "刚刚" : mins + " 分钟前"}</span>`;
    const btn = document.createElement("button");
    btn.className = "btn small";
    btn.textContent = "重连";
    btn.disabled = !(online && online.online);
    btn.onclick = () => connectSameAccount(online);
    li.appendChild(btn);
    ul.appendChild(li);
  }
}

// ---------------- 统一链接 ----------------
async function genLink() {
  try {
    const res = await state.api.createLink();
    $("link-box").classList.remove("hidden");
    $("link-code").textContent = res.code;
    let left = Math.round((new Date(res.expires_at) - Date.now()) / 1000);
    const tick = () => {
      $("link-expire").textContent = left > 0 ? `${left} 秒后失效` : "已失效";
      if (left-- <= 0 && state.linkTimer) clearInterval(state.linkTimer);
    };
    tick();
    if (state.linkTimer) clearInterval(state.linkTimer);
    state.linkTimer = setInterval(tick, 1000);
  } catch (e) {
    alert("生成失败：" + e.message);
  }
}

async function useLink() {
  const code = $("link-input").value.trim().toUpperCase();
  if (code.length < 4) return alert("请输入链接码");
  try {
    const res = await state.api.requestSession({ auth: { mode: "link", link_code: code } });
    if (res.status === "active") {
      await startController(res.session_id, res.session_id, res.turn, "远程设备", res.media);
    } else {
      state.pendingSessionId = res.session_id;
    }
  } catch (e) {
    alert("连接失败：" + e.message);
  }
}

// ---------------- 会话（被控端事件） ----------------
let pendingReq = null;

function onSessionReq(m) {
  if (state.mode) return; // 已在会话中
  pendingReq = m;
  $("req-text").textContent = `「${(m.data && m.data.controller_name) || "某设备"}」请求控制本机`;
  const media = normalizeMediaPolicy(m.data && m.data.media);
  const bits = [];
  if (media.mic) bits.push("麦克风");
  if (media.camera) bits.push("摄像头");
  $("req-media").textContent = bits.length
    ? `本次允许对方使用：${bits.join("、")}（连上后仍可随时关闭）`
    : "本次不开放麦克风 / 摄像头";
  $("req-modal").classList.remove("hidden");
}

async function respondRequest(accept) {
  $("req-modal").classList.add("hidden");
  if (!pendingReq) return;
  const sessionId = pendingReq.session_id;
  state.pendingSessionId = sessionId;
  const media = normalizeMediaPolicy(pendingReq.data && pendingReq.data.media);
  pendingReq = null;
  try {
    const res = await state.api.acceptSession(sessionId, accept);
    if (accept && res.turn) {
      // 服务端还会推 control_start，这里也可直接启动
      await startControlled(sessionId, res.turn, "远程控制方", false, res.media || media);
    }
  } catch (e) {
    alert("处理失败：" + e.message);
  }
}

async function onSessionOk(m) {
  const turn = m.data && m.data.turn;
  const sid = m.session_id;
  const peer = state.peerDeviceId || m.from;
  if (state.mode === "controller") return;
  await startController(sid, peer, turn, "远程设备", m.data && m.data.media);
}

async function onControlStart(m) {
  const turn = m.data && m.data.turn;
  const name = (m.data && m.data.controller_name) || "远程设备";
  await startControlled(m.session_id, turn, name, true, m.data && m.data.media);
}

// ---------------- 启动会话 ----------------
async function startController(sessionId, peerDeviceId, turn, peerName, peerMedia) {
  if (state.session) await state.session.close();
  state.mode = "controller";
  state.sessionId = sessionId;
  state.peerDeviceId = peerDeviceId;
  state.peerMedia = normalizeMediaPolicy(peerMedia || state.peerMedia);
  toast(`正在控制「${peerName}」`);
  show("remote");
  $("remote-title").textContent = `控制中：${peerName}`;
  $("remote-stage").focus();
  resetMediaUi();

  state.session = new PeerSession({
    role: "controller",
    sessionId,
    peerDeviceId,
    turn,
    policy: state.peerMedia,
    signaling: state.signaling,
    handlers: {
      remoteStream: (stream) => {
        $("remote-video").srcObject = stream;
        $("remote-video").play().catch(() => {});
      },
      remoteAudio: ({ track, stream }) => {
        const el = $("remote-audio");
        el.srcObject = stream || new MediaStream([track]);
        el.muted = state.audioMuted;
        el.play().catch((e) => console.warn("audio autoplay blocked", e));
      },
      remoteCamera: ({ track, stream }) => {
        $("remote-camera").srcObject = stream || new MediaStream([track]);
        $("remote-camera").play().catch(() => {});
        $("camera-pip").classList.remove("hidden");
      },
      mediaState: (m) => renderMediaState(m),
      mediaProblem: (h) => showMediaModal(h),
      state: (st) => {
        $("remote-title").textContent = `控制中：${peerName}（${st}）`;
      },
      closed: () => endControl(true),
      fileProgress: onFileProgress,
      fileDone: (f) => toast(`文件已保存：${f.path}`),
      fileIncoming: (f) => {
        $("transfer-bar").classList.remove("hidden");
        $("transfer-name").textContent = "接收：" + f.name;
      },
      error: (e) => toast(String(e)),
    },
  });
  await state.session.start();
  await state.session.createOffer();
  bindRemoteInput();
  if (peerDeviceId && peerDeviceId !== sessionId) pushHistory({ id: peerDeviceId, name: peerName });
}

async function startControlled(sessionId, turn, controllerName, notifyServer, media) {
  if (state.session) await state.session.close();
  state.mode = "controlled";
  state.sessionId = sessionId;
  // 以本机设置为准；服务端下发的 media 由同一份设置推导，作为兜底
  state.mediaPolicy = normalizeMediaPolicy(
    Object.keys(state.settings).length ? state.settings : media
  );
  hideToast();
  toast(`「${controllerName}」正在控制本机`);
  $("toast-media").textContent = "麦克风 / 摄像头：未开启";
  $("toast-mic").disabled = true;
  $("toast-cam").disabled = true;

  state.session = new PeerSession({
    role: "controlled",
    sessionId,
    peerDeviceId: state.peerDeviceId || "",
    turn,
    policy: state.mediaPolicy,
    signaling: state.signaling,
    handlers: {
      state: (st) => {
        if (st === "connected") toast(`「${controllerName}」正在控制本机`);
      },
      mediaState: (m) => renderMediaState(m),
      mediaProblem: (h) => showMediaModal(h),
      closed: () => endControl(true),
      error: (e) => console.warn(e),
    },
  });
  await state.session.start();
  if (notifyServer) $("toast-text").textContent = `「${controllerName}」正在控制本机`;
}

function endControl(silent) {
  const sid = state.sessionId;
  const sig = state.signaling;
  if (sid && sig) {
    state.api.cancelSession(sid).catch(() => {});
    sig.send({ type: "cancel", to: state.peerDeviceId || "", session_id: sid });
  }
  if (state.session) state.session.close();
  state.session = null;
  state.mode = null;
  state.sessionId = null;
  hideToast();
  $("transfer-bar").classList.add("hidden");
  $("remote-video").srcObject = null;
  $("remote-audio").srcObject = null;
  $("remote-camera").srcObject = null;
  $("camera-pip").classList.add("hidden");
  resetMediaUi();
  show("home");
  if (!silent) refreshDevices();
}

// ---------------- 语音 / 摄像头 UI ----------------
function resetMediaUi() {
  for (const id of ["btn-mic", "btn-camera"]) {
    $(id).classList.remove("on");
  }
  $("btn-mic").textContent = "语音";
  $("btn-camera").textContent = "摄像头";
  $("media-state").textContent = "";
  state.desired = { mic: false, camera: false };
  $("camera-pip").classList.add("hidden");
}

function renderMediaState(m) {
  const text = describeMediaState(m);
  $("media-state").textContent = text;
  if (state.mode === "controller") {
    const want = state.desired;
    $("btn-mic").classList.toggle("on", !!want.mic);
    $("btn-camera").classList.toggle("on", !!want.camera);
    $("btn-mic").textContent = m.micOn ? "语音·开" : "语音";
    $("btn-camera").textContent = m.camOn ? "摄像头·开" : "摄像头";
    if (!m.camOn) $("camera-pip").classList.add("hidden");
  } else {
    $("toast-media").textContent = text || "麦克风 / 摄像头：未开启";
    $("toast-mic").disabled = !m.micOn;
    $("toast-cam").disabled = !m.camOn;
    $("toast-mic").textContent = m.micOn ? "关闭麦克风" : "麦克风已关";
    $("toast-cam").textContent = m.camOn ? "关闭摄像头" : "摄像头已关";
  }
}

function toggleMedia(kind) {
  if (!state.session || state.mode !== "controller") return;
  const allowed = kind === "mic" ? state.peerMedia.mic : state.peerMedia.camera;
  if (!allowed) {
    showMediaModal({
      kind,
      what: kind === "mic" ? "麦克风" : "摄像头",
      text: `对方没有开放${kind === "mic" ? "麦克风" : "摄像头"}权限。请对方在「设置 → 允许远程开启${kind === "mic" ? "麦克风" : "摄像头"}」里打开后重连。`,
      canOpenSettings: false,
      reason: "policy_off",
    });
    return;
  }
  const next = { ...state.desired, [kind === "camera" ? "camera" : "mic"]: !state.desired[kind === "camera" ? "camera" : "mic"] };
  state.desired = next;
  state.session.requestMedia(next);
}

function toggleAudioMute() {
  state.audioMuted = !state.audioMuted;
  localStorage.setItem(AUDIO_MUTED_KEY, state.audioMuted ? "1" : "0");
  $("remote-audio").muted = state.audioMuted;
  renderAudioButton();
}

function renderAudioButton() {
  $("btn-audio").textContent = state.audioMuted ? "声音关" : "声音开";
  $("btn-audio").classList.toggle("on", !state.audioMuted);
}

/** 被控端：在被控横幅上一键关掉本机麦克风 / 摄像头。 */
function stopLocalMedia(kind) {
  if (!state.session || state.mode !== "controlled") return;
  state.session.stopLocalMedia(kind === "mic" ? "mic" : "camera");
}

function showMediaModal(hint) {
  if (!hint || !hint.text) return;
  state.mediaModalKind = hint.kind === "mic" ? "microphone" : "camera";
  $("media-modal-title").textContent = `${hint.what || "设备"} 未能开启`;
  $("media-modal-text").textContent = hint.text;
  $("media-modal-settings").classList.toggle("hidden", !hint.canOpenSettings);
  $("media-modal").classList.remove("hidden");
}

async function openPrivacySettings(kind) {
  try {
    await invoke("open_privacy_settings", { kind });
  } catch (e) {
    alert("无法打开系统设置：" + (e.message || e));
  }
}

/** 本机媒体自检：政策开关 + Windows 隐私 + 设备是否存在。 */
async function refreshMediaCheck() {
  const ul = $("media-check");
  ul.innerHTML = `<li><span class="dot offline"></span><span class="check-name">检测中…</span></li>`;
  let privacy = null;
  try {
    privacy = await invoke("media_privacy_status");
  } catch (e) {
    console.warn("privacy status failed", e);
  }
  state.privacy = privacy;

  const devices = await listMediaDevices();
  const rows = [
    {
      ok: !!state.settings.mic_enabled,
      name: "政策：允许对方使用麦克风",
      note: state.settings.mic_enabled ? "已允许" : "已关闭（设置里可开）",
    },
    {
      ok: !!state.settings.camera_enabled,
      name: "政策：允许对方使用摄像头",
      note: state.settings.camera_enabled ? "已允许" : "已关闭（设置里可开）",
    },
    {
      ok: privacy ? privacy.microphone !== false : null,
      name: "Windows 隐私：桌面应用可用麦克风",
      note: privacy && privacy.microphone === false ? "被系统关闭，点下方按钮打开" : "正常",
    },
    {
      ok: privacy ? privacy.webcam !== false : null,
      name: "Windows 隐私：桌面应用可用摄像头",
      note: privacy && privacy.webcam === false ? "被系统关闭，点下方按钮打开" : "正常",
    },
    {
      ok: devices === null ? null : devices.audio > 0,
      name: "检测到麦克风设备",
      note: devices === null ? "无法枚举（需要权限）" : `${devices.audio} 个`,
    },
    {
      ok: devices === null ? null : devices.video > 0,
      name: "检测到摄像头设备",
      note: devices === null ? "无法枚举（需要权限）" : `${devices.video} 个`,
    },
  ];

  ul.innerHTML = "";
  for (const r of rows) {
    const li = document.createElement("li");
    const cls = r.ok === null ? "" : r.ok ? "online" : "offline";
    li.innerHTML = `<span class="dot ${cls}"></span>
      <span class="check-name">${escapeHtml(r.name)}</span>
      <span class="muted small">${escapeHtml(r.note)}</span>`;
    ul.appendChild(li);
  }
}

/** 枚举本机音视频设备数量；拿不到权限时返回 null。 */
async function listMediaDevices() {
  try {
    if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return null;
    const list = await navigator.mediaDevices.enumerateDevices();
    return {
      audio: list.filter((d) => d.kind === "audioinput").length,
      video: list.filter((d) => d.kind === "videoinput").length,
    };
  } catch (e) {
    console.warn("enumerateDevices failed", e);
    return null;
  }
}

// ---------------- 远程输入 ----------------
let mouseThrottle = 0;

function bindRemoteInput() {
  const stage = $("remote-stage");
  if (stage.dataset.bound) return;
  stage.dataset.bound = "1";

  stage.addEventListener("mousemove", (e) => {
    const now = performance.now();
    if (now - mouseThrottle < 16) return;
    mouseThrottle = now;
    const p = mapCoords(e);
    if (p) state.session && state.session.sendInput({ t: "mouse_move", x: p.x, y: p.y });
  });

  stage.addEventListener("mousedown", (e) => {
    stage.focus();
    const p = mapCoords(e);
    if (p) state.session && state.session.sendInput({ t: "mouse_down", x: p.x, y: p.y, button: e.button });
    e.preventDefault();
  });

  stage.addEventListener("mouseup", (e) => {
    const p = mapCoords(e);
    if (p) state.session && state.session.sendInput({ t: "mouse_up", x: p.x, y: p.y, button: e.button });
  });

  stage.addEventListener("contextmenu", (e) => e.preventDefault());

  stage.addEventListener(
    "wheel",
    (e) => {
      state.session && state.session.sendInput({ t: "mouse_wheel", dx: e.deltaX, dy: e.deltaY });
      e.preventDefault();
    },
    { passive: false }
  );

  stage.addEventListener("keydown", (e) => {
    if (!state.session) return;
    if (e.key === "Escape") return;
    state.session.sendInput({
      t: "key",
      action: "down",
      code: e.code,
      key: e.key,
      mods: modsOf(e),
    });
    e.preventDefault();
  });

  stage.addEventListener("keyup", (e) => {
    if (!state.session) return;
    if (e.key === "Escape") return;
    state.session.sendInput({ t: "key", action: "up", code: e.code, key: e.key });
    e.preventDefault();
  });
}

function modsOf(e) {
  const m = [];
  if (e.ctrlKey) m.push("ctrl");
  if (e.altKey) m.push("alt");
  if (e.shiftKey) m.push("shift");
  if (e.metaKey) m.push("meta");
  return m;
}

function mapCoords(e) {
  const v = $("remote-video");
  const vw = v.videoWidth || 1920;
  const vh = v.videoHeight || 1080;
  const r = v.getBoundingClientRect();
  const scale = Math.min(r.width / vw, r.height / vh);
  const dw = vw * scale;
  const dh = vh * scale;
  const ox = r.left + (r.width - dw) / 2;
  const oy = r.top + (r.height - dh) / 2;
  const x = (e.clientX - ox) / dw;
  const y = (e.clientY - oy) / dh;
  if (x < 0 || x > 1 || y < 0 || y > 1) return null;
  return { x, y };
}

// ---------------- 传输进度 ----------------
function onFileProgress(p) {
  $("transfer-bar").classList.remove("hidden");
  const pct = p.total ? Math.round((p.current / p.total) * 100) : 0;
  $("transfer-name").textContent = (p.outgoing ? "发送：" : "接收：") + pct + "%";
  $("transfer-progress").value = pct;
  $("transfer-pct").textContent = pct + "%";
  if (pct >= 100) setTimeout(() => $("transfer-bar").classList.add("hidden"), 1500);
}

// ---------------- 设置 ----------------
async function loadSettings() {
  try {
    state.settings = await state.api.getSettings();
    state.mediaPolicy = normalizeMediaPolicy(state.settings);
    $("set-auto-accept").checked = !!state.settings.auto_accept_same_account;
    $("set-mic").checked = !!state.settings.mic_enabled;
    $("set-camera").checked = !!state.settings.camera_enabled;
  } catch (e) {
    console.warn(e);
  }
}

function openSettings() {
  $("settings-modal").classList.remove("hidden");
}

async function saveSettings() {
  const patch = {
    auto_accept_same_account: $("set-auto-accept").checked,
    mic_enabled: $("set-mic").checked,
    camera_enabled: $("set-camera").checked,
  };
  try {
    await state.api.putSettings(patch);
    state.settings = { ...state.settings, ...patch };
    state.mediaPolicy = normalizeMediaPolicy(state.settings);
    // 会话中改了设置：立刻按新政策重算（控制端下次请求会生效）
    if (state.session && state.mode === "controlled") {
      state.session.policy = state.mediaPolicy;
      if (!state.mediaPolicy.mic) state.session.stopLocalMedia("mic");
      if (!state.mediaPolicy.camera) state.session.stopLocalMedia("camera");
    }
    $("settings-modal").classList.add("hidden");
    refreshMediaCheck();
  } catch (e) {
    alert("保存失败：" + e.message);
  }
}

// ---------------- 工具 ----------------
let qualityIdx = 1;
const qualities = ["low", "normal", "high"];
const qualityNames = { low: "流畅", normal: "均衡", high: "高清" };
function cycleQuality() {
  qualityIdx = (qualityIdx + 1) % qualities.length;
  const q = qualities[qualityIdx];
  $("btn-quality").textContent = `画质：${qualityNames[q]}`;
  if (state.session) state.session.setQuality(q);
}

function toggleFullscreen() {
  if (!document.fullscreenElement) $("view-remote").requestFullscreen().catch(() => {});
  else document.exitFullscreen().catch(() => {});
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

boot();
