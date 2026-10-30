// UI 主控逻辑
import { invoke } from "@tauri-apps/api/core";
import { Api } from "./api.js";
import { Signaling } from "./signaling.js";
import { PeerSession } from "./session.js";

const $ = (id) => document.getElementById(id);

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
  server: localStorage.getItem("rd_server") || "http://127.0.0.1:8443",
  mode: null, // controller | controlled
  linkTimer: null,
};
localStorage.setItem("rd_device_id", state.deviceId);

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
  try {
    const info = await invoke("device_info");
    state.deviceName = info.name || state.deviceName;
  } catch {
    /* 非 Tauri 环境忽略 */
  }
  $("device-hint").textContent = `本机设备：${state.deviceName}（ID ${state.deviceId.slice(0, 8)}）`;

  $("btn-login").onclick = () => doAuth("login");
  $("btn-register").onclick = () => doAuth("register");
  $("btn-logout").onclick = logout;
  $("btn-refresh").onclick = refreshDevices;
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

  // 回车提交
  $("password").addEventListener("keydown", (e) => {
    if (e.key === "Enter") doAuth("login");
  });
}

// ---------------- 登录 / 注册 ----------------
async function doAuth(kind) {
  err("auth-error", "");
  const server = $("server-url").value.trim();
  if (!server) return err("auth-error", "请填写服务器地址");
  state.server = server;
  localStorage.setItem("rd_server", server);
  state.api.setServer(server);

  const payload = {
    username: $("username").value.trim(),
    password: $("password").value,
    device_name: state.deviceName,
    os: "windows",
    device_id: state.deviceId,
  };
  try {
    const res = kind === "login" ? await state.api.login(payload) : await state.api.register(payload);
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
  } catch (e) {
    err("auth-error", e.message || "登录失败");
  }
}

function logout() {
  if (state.session) endControl();
  if (state.signaling) state.signaling.close();
  state.signaling = null;
  state.api.token = null;
  state.user = null;
  show("auth");
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
    li.innerHTML = `
      <span class="dot ${online ? "online" : "offline"}"></span>
      <div class="meta">
        <div class="name">${escapeHtml(d.name)}${d.id === state.deviceId ? "（本机）" : ""}</div>
        <div class="os">${osName} · ${online ? "在线" : "离线"}</div>
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
}

async function connectSameAccount(dev) {
  try {
    const res = await state.api.requestSession({
      target_device_id: dev.id,
      auth: { mode: "same_account" },
    });
    state.pendingSessionId = res.session_id;
    state.peerDeviceId = dev.id;
    if (res.status === "active") {
      await startController(res.session_id, dev.id, res.turn, dev.name);
    } else {
      toast(`已向「${dev.name}」发送控制请求，等待对方同意…`);
    }
  } catch (e) {
    alert("连接失败：" + e.message);
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
      await startController(res.session_id, res.session_id, res.turn, "远程设备");
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
  $("req-modal").classList.remove("hidden");
}

async function respondRequest(accept) {
  $("req-modal").classList.add("hidden");
  if (!pendingReq) return;
  const sessionId = pendingReq.session_id;
  state.pendingSessionId = sessionId;
  pendingReq = null;
  try {
    const res = await state.api.acceptSession(sessionId, accept);
    if (accept && res.turn) {
      // 服务端还会推 control_start，这里也可直接启动
      await startControlled(sessionId, res.turn, "远程控制方", false);
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
  await startController(sid, peer, turn, "远程设备");
}

async function onControlStart(m) {
  const turn = m.data && m.data.turn;
  const name = (m.data && m.data.controller_name) || "远程设备";
  await startControlled(m.session_id, turn, name, true);
}

// ---------------- 启动会话 ----------------
async function startController(sessionId, peerDeviceId, turn, peerName) {
  if (state.session) await state.session.close();
  state.mode = "controller";
  state.sessionId = sessionId;
  state.peerDeviceId = peerDeviceId;
  toast(`正在控制「${peerName}」`);
  show("remote");
  $("remote-title").textContent = `控制中：${peerName}`;
  $("remote-stage").focus();

  state.session = new PeerSession({
    role: "controller",
    sessionId,
    peerDeviceId,
    turn,
    signaling: state.signaling,
    handlers: {
      remoteStream: (stream) => {
        $("remote-video").srcObject = stream;
        $("remote-video").play().catch(() => {});
      },
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
}

async function startControlled(sessionId, turn, controllerName, notifyServer) {
  if (state.session) await state.session.close();
  state.mode = "controlled";
  state.sessionId = sessionId;
  hideToast();
  toast(`「${controllerName}」正在控制本机`);

  state.session = new PeerSession({
    role: "controlled",
    sessionId,
    peerDeviceId: state.peerDeviceId || "",
    turn,
    signaling: state.signaling,
    handlers: {
      state: (st) => {
        if (st === "connected") toast(`「${controllerName}」正在控制本机`);
      },
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
  show("home");
  if (!silent) refreshDevices();
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
    $("settings-modal").classList.add("hidden");
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
