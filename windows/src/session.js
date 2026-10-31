// WebRTC 会话：协商、屏幕轨道、语音/摄像头、控制通道、文件传输
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import {
  emptyMediaState,
  guessTrackKind,
  makeMediaState,
  makeTrackAnnounce,
  normalizeMediaPolicy,
  parseMediaState,
  permissionHint,
  reasonText,
  trackKindMap,
} from "./media.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function b64ToBytes(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToB64(bytes) {
  let s = "";
  const CH = 0x8000;
  for (let i = 0; i < bytes.length; i += CH) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + CH));
  }
  return btoa(s);
}

export class PeerSession {
  /**
   * @param {object} o
   * @param {"controller"|"controlled"} o.role
   * @param {string} o.sessionId
   * @param {string} o.peerDeviceId
   * @param {object} o.turn
   * @param {import('./signaling.js').Signaling} o.signaling
   * @param {object} o.handlers
   */
  constructor(o) {
    this.role = o.role;
    this.sessionId = o.sessionId;
    this.peerDeviceId = o.peerDeviceId;
    this.turn = o.turn || {};
    this.signaling = o.signaling;
    this.handlers = o.handlers || {};
    this.pc = null;
    this.channels = {};
    this._candQueue = [];
    this.closed = false;
    this._unlistenFrame = null;
    this._captureStream = null;
    this._pendingSend = null;
    this._recv = null;
    this._fileChain = Promise.resolve();
    this._sentOffer = false;

    // ---- 语音 / 摄像头 ----
    // policy：被控端允许的媒体能力（来自服务端会话响应 / control_start）
    this.policy = normalizeMediaPolicy(o.policy);
    this.media = emptyMediaState(this.policy);
    this._micStream = null;
    this._camStream = null;
    this._micSender = null;
    this._camSender = null;
    this._mediaBusy = false;
    this._trackKinds = {}; // trackId → "camera" | "mic"
    this._offerChain = Promise.resolve();
    this._renegotiating = false;
  }

  _emit(name, payload) {
    const fn = this.handlers[name];
    if (fn) {
      try {
        fn(payload);
      } catch (e) {
        console.error("session handler", name, e);
      }
    }
  }

  _iceServers() {
    const urls = this.turn.urls && this.turn.urls.length ? this.turn.urls : ["stun:stun.l.google.com:19302"];
    const server = { urls };
    if (this.turn.username) server.username = this.turn.username;
    if (this.turn.credential) server.credential = this.turn.credential;
    return [server];
  }

  async start() {
    this.pc = new RTCPeerConnection({
      iceServers: this._iceServers(),
      sdpSemantics: "unified-plan",
    });

    this.pc.onicecandidate = (e) => {
      if (e.candidate && !this.closed) {
        this.signaling.send({
          type: "ice",
          to: this.peerDeviceId,
          session_id: this.sessionId,
          candidate: JSON.stringify(e.candidate),
        });
      }
    };

    this.pc.onconnectionstatechange = () => {
      const st = this.pc.connectionState;
      this._emit("state", st);
      if (st === "failed" || st === "closed") this._emit("closed", st);
    };

    this.pc.ondatachannel = (e) => this._attachChannel(e.channel);

    // 被控端按需追加麦克风/摄像头轨道后需要重新协商（新增轨道无法凭空进入已建立的 SDP）。
    // 只有被控端会主动重协商；控制端只应答，避免 glare。
    this.pc.onnegotiationneeded = () => {
      if (this.role !== "controlled" || this.closed) return;
      if (!this.pc || !this.pc.currentRemoteDescription) return; // 首次协商由控制端发起
      this._renegotiate();
    };

    // 轨道分流：音频 → 独立播放器；摄像头 → 画中画；其余按屏幕处理。
    this.pc.ontrack = (e) => {
      const track = e.track;
      const streamId = (e.streams[0] && e.streams[0].id) || "";
      // 优先用 SDP 里的 stream id（Android 用 rd-camera 命名），再退回 media_track 映射
      const kind =
        streamId === "rd-camera"
          ? "camera"
          : this._trackKinds[track.id] || guessTrackKind(track.id, track.kind);
      if (track.kind === "audio" || kind === "mic") {
        this._emit("remoteAudio", { track, stream: e.streams[0] || null });
        return;
      }
      if (kind === "camera") {
        this._emit("remoteCamera", { track, stream: e.streams[0] || null });
        return;
      }
      this._emit("remoteStream", e.streams[0] || new MediaStream([track]));
    };

    if (this.role === "controller") {
      this._attachChannel(this.pc.createDataChannel("control", { ordered: true }));
      this._attachChannel(this.pc.createDataChannel("file", { ordered: true }));
      this._attachChannel(this.pc.createDataChannel("meta", { ordered: true }));
    } else {
      await this._startCapture();
    }
  }

  /** 被控端：开始屏幕采集并把 canvas 流作为视频轨道 */
  async _startCapture() {
    const canvas = document.createElement("canvas");
    canvas.width = 1280;
    canvas.height = 720;
    const ctx = canvas.getContext("2d", { alpha: false });
    this._canvas = canvas;
    this._ctx = ctx;

    // 二进制帧 -> canvas
    this._unlistenFrame = await listen("screen-frame", async (ev) => {
      const { jpeg_b64, width, height } = ev.payload || {};
      if (!jpeg_b64) return;
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
        this._localSize = { w: width, h: height };
        // 同步告知对端真实画面尺寸，供其把 0..1 坐标还原为像素
        this.sendMeta({ t: "screen", w: width, h: height });
      }
      try {
        const blob = new Blob([b64ToBytes(jpeg_b64)], { type: "image/jpeg" });
        const bmp = await createImageBitmap(blob);
        ctx.drawImage(bmp, 0, 0, canvas.width, canvas.height);
        bmp.close();
      } catch (e) {
        console.warn("frame decode failed", e);
      }
    });

    await invoke("start_capture", { monitor: 0, fps: 15 });
    this._captureStream = canvas.captureStream(15);
    const track = this._captureStream.getVideoTracks()[0];
    if (track) this.pc.addTrack(track, this._captureStream);
  }

  // ---------- 语音 / 摄像头 ----------
  //
  // 角色分工（协议 5.5 节）：
  //   · 只有被控端采集；控制端仅接收。
  //   · 控制端发 media_req 表达「我要听/要看」，被控端按政策位 + 系统权限决定能不能给。
  //   · 被控端每次状态变化都回 media_state，失败附 reason。
  //   · 关闭用 replaceTrack(null) 保留 m-line，重新打开无需重协商。

  /** 被控端按需追加上/移除轨道后重新协商（新增轨道必须走一次 offer/answer）。 */
  _renegotiate() {
    this._offerChain = this._offerChain
      .then(() => this._doRenegotiate())
      .catch((e) => console.warn("renegotiate failed", e));
  }

  async _doRenegotiate() {
    for (let i = 0; i < 20; i++) {
      if (this.closed || !this.pc || !this.pc.currentRemoteDescription) return;
      if (this.pc.signalingState === "stable") break;
      await sleep(100);
    }
    if (this.closed || !this.pc || this.pc.signalingState === "closed") return;
    try {
      this._renegotiating = true;
      const offer = await this.pc.createOffer();
      await this.pc.setLocalDescription(offer);
      this.signaling.send({
        type: "offer",
        to: this.peerDeviceId,
        session_id: this.sessionId,
        sdp: offer.sdp,
      });
    } finally {
      this._renegotiating = false;
    }
  }

  /** 控制端：表达希望听到/看到的媒体。 */
  requestMedia(desired) {
    if (this.role !== "controller") return;
    this.desired = {
      mic: desired && desired.mic === true,
      camera: desired && desired.camera === true,
    };
    this.sendMeta({ t: "media_req", mic: this.desired.mic, camera: this.desired.camera });
    this._emit("mediaState", { ...this.media, desired: { ...this.desired } });
  }

  /** 控制端：切换某一路。 */
  toggleMedia(kind) {
    if (this.role !== "controller") return;
    const cur = this.desired || { mic: false, camera: false };
    const next = { ...cur, [kind === "camera" ? "camera" : "mic"]: !cur[kind === "camera" ? "camera" : "mic"] };
    this.requestMedia(next);
  }

  /** 被控端：响应 media_req（串行处理，避免并发 getUserMedia 把设备抢崩）。 */
  async _applyMediaRequest(msg) {
    if (this._mediaBusy) {
      this._pendingMediaReq = msg;
      return;
    }
    this._mediaBusy = true;
    try {
      if (msg.mic === true) await this._openMic();
      else await this._closeMic();
      if (msg.camera === true) await this._openCam();
      else await this._closeCam();
    } finally {
      this._mediaBusy = false;
      const next = this._pendingMediaReq;
      this._pendingMediaReq = null;
      if (next) await this._applyMediaRequest(next);
    }
  }

  async _openMic() {
    if (this.role !== "controlled" || this.closed) return;
    if (!this.policy.mic) {
      this.media = { ...this.media, micOn: false, reason: "policy_off" };
      this._sendMediaState();
      return;
    }
    if (this._micStream) {
      this.media = { ...this.media, micOn: true, reason: "" };
      this._sendMediaState();
      return;
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
        video: false,
      });
      const track = stream.getAudioTracks()[0];
      if (!track) throw Object.assign(new Error("no audio track"), { name: "NotFoundError" });
      this._micStream = stream;
      if (this._micSender) await this._micSender.replaceTrack(track);
      else this._micSender = this.pc.addTrack(track, stream);
      track.onended = () => this._closeMic("no_device");
      this.media = { ...this.media, mic: true, micOn: true, reason: "" };
      this.sendMeta(makeTrackAnnounce("mic", track.id));
      this._sendMediaState();
    } catch (e) {
      console.warn("open mic failed", e);
      this._onMediaError("mic", e);
    }
  }

  async _closeMic(reason = "") {
    try {
      if (this._micSender) await this._micSender.replaceTrack(null);
    } catch (e) {
      console.warn("replaceTrack(mic,null) failed", e);
    }
    if (this._micStream) {
      this._micStream.getTracks().forEach((t) => {
        try {
          t.stop();
        } catch {}
      });
      this._micStream = null;
    }
    this.media = { ...this.media, micOn: false, reason };
    if (this.role === "controlled") this._sendMediaState();
  }

  async _openCam() {
    if (this.role !== "controlled" || this.closed) return;
    if (!this.policy.camera) {
      this.media = { ...this.media, camOn: false, reason: "policy_off" };
      this._sendMediaState();
      return;
    }
    if (this._camStream) {
      this.media = { ...this.media, camOn: true, reason: "" };
      this._sendMediaState();
      return;
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: { width: { ideal: 640 }, height: { ideal: 480 }, frameRate: { max: 20 }, facingMode: "user" },
      });
      const track = stream.getVideoTracks()[0];
      if (!track) throw Object.assign(new Error("no camera track"), { name: "NotFoundError" });
      this._camStream = stream;
      if (this._camSender) await this._camSender.replaceTrack(track);
      else this._camSender = this.pc.addTrack(track, stream); // 触发 onnegotiationneeded
      track.onended = () => this._closeCam("no_device");
      this.media = { ...this.media, camera: true, camOn: true, reason: "" };
      this.sendMeta(makeTrackAnnounce("camera", track.id));
      this._sendMediaState();
    } catch (e) {
      console.warn("open camera failed", e);
      this._onMediaError("camera", e);
    }
  }

  async _closeCam(reason = "") {
    try {
      if (this._camSender) await this._camSender.replaceTrack(null);
    } catch (e) {
      console.warn("replaceTrack(cam,null) failed", e);
    }
    if (this._camStream) {
      this._camStream.getTracks().forEach((t) => {
        try {
          t.stop();
        } catch {}
      });
      this._camStream = null;
    }
    this.media = { ...this.media, camOn: false, reason };
    if (this.role === "controlled") this._sendMediaState();
  }

  /** 被控端：用户在横幅上直接关掉某一路（不经过控制端）。 */
  async stopLocalMedia(kind) {
    if (this.role !== "controlled") return;
    if (kind === "camera") await this._closeCam();
    else await this._closeMic();
  }

  _onMediaError(kind, err) {
    const hint = permissionHint(kind, err);
    this.media = {
      ...this.media,
      micOn: kind === "mic" ? false : this.media.micOn,
      camOn: kind === "camera" ? false : this.media.camOn,
      reason: hint.reason,
    };
    this._emit("mediaProblem", hint);
    this._sendMediaState();
  }

  _sendMediaState() {
    this.sendMeta(makeMediaState(this.media));
    this._emit("mediaState", { ...this.media });
  }

  /** 结束会话时务必停掉采集（否则系统麦克风/摄像头指示灯会一直亮）。 */
  stopAllMedia() {
    for (const s of [this._micStream, this._camStream]) {
      if (!s) continue;
      s.getTracks().forEach((t) => {
        try {
          t.stop();
        } catch {}
      });
    }
    this._micStream = null;
    this._camStream = null;
    this._micSender = null;
    this._camSender = null;
  }

  _attachChannel(ch) {
    this.channels[ch.label] = ch;
    ch.binaryType = "arraybuffer";
    ch.onopen = () => {
      this._emit("channelOpen", ch.label);
      // 通道刚就绪时补发一次画面尺寸（可能早于首帧产生了 _localSize）
      if (ch.label === "meta" && this._localSize) {
        this.sendMeta({ t: "screen", w: this._localSize.w, h: this._localSize.h });
      }
      // 用户在通道就绪前就点了「语音/摄像头」→ 这里补发一次请求
      if (ch.label === "meta" && this.role === "controller" && this.desired) {
        this.sendMeta({ t: "media_req", mic: this.desired.mic, camera: this.desired.camera });
      }
    };
    ch.onmessage = (e) => {
      if (ch.label === "control") this._onControl(e.data);
      else if (ch.label === "file") this._enqueueFile(e.data);
      else if (ch.label === "meta") this._onMeta(e.data);
    };
  }

  /** 控制端：创建 offer */
  async createOffer() {
    const offer = await this.pc.createOffer();
    await this.pc.setLocalDescription(offer);
    this._sentOffer = true;
    // 信令中的 sdp 字段为纯 SDP 文本（各端统一约定，不嵌套 JSON）
    this.signaling.send({
      type: "offer",
      to: this.peerDeviceId,
      session_id: this.sessionId,
      sdp: offer.sdp,
    });
  }

  /** 被控端：处理 offer 并回 answer */
  async handleOffer(sdpStr) {
    await this.pc.setRemoteDescription({ type: "offer", sdp: sdpStr });
    await this._flushCandidates();
    const answer = await this.pc.createAnswer();
    await this.pc.setLocalDescription(answer);
    this.signaling.send({
      type: "answer",
      to: this.peerDeviceId,
      session_id: this.sessionId,
      sdp: answer.sdp,
    });
  }

  async handleAnswer(sdpStr) {
    await this.pc.setRemoteDescription({ type: "answer", sdp: sdpStr });
    await this._flushCandidates();
  }

  async handleIce(candStr) {
    const cand = JSON.parse(candStr);
    if (!this.pc.remoteDescription) {
      this._candQueue.push(cand);
      return;
    }
    try {
      await this.pc.addIceCandidate(cand);
    } catch (e) {
      console.warn("addIceCandidate failed", e);
    }
  }

  async _flushCandidates() {
    const q = this._candQueue;
    this._candQueue = [];
    for (const c of q) {
      try {
        await this.pc.addIceCandidate(c);
      } catch (e) {
        console.warn("flush candidate failed", e);
      }
    }
  }

  // ---------- 输入 ----------
  sendInput(evt) {
    const ch = this.channels["control"];
    if (ch && ch.readyState === "open") {
      ch.send(JSON.stringify(evt));
    }
  }

  _onControl(data) {
    let evt;
    try {
      evt = JSON.parse(data);
    } catch {
      return;
    }
    // 被控端：把远程输入注入本机
    invoke("inject_input", { event: evt }).catch((e) => console.warn("inject failed", e));
  }

  // ---------- 元信息 ----------
  sendMeta(obj) {
    const ch = this.channels["meta"];
    if (ch && ch.readyState === "open") ch.send(JSON.stringify(obj));
  }

  _onMeta(data) {
    let msg;
    try {
      msg = JSON.parse(data);
    } catch {
      return;
    }
    this._onMetaMessage(msg);
  }

  // ---------- 文件 ----------
  //
  // 约定（三端一致）：
  //   · `meta` 通道只承载 JSON 文本；文件控制消息（file_offer/file_accept/
  //     file_reject/file_done/file_ack）也走这里。
  //   · `file` 通道只承载二进制块，不含任何 JSON，故接收端无需猜测类型。
  async pickAndSendFile() {
    const meta = await invoke("pick_file");
    if (!meta) return;
    const mc = this.channels["meta"];
    if (!mc || mc.readyState !== "open") {
      this._emit("error", "文件通道未就绪");
      return;
    }
    const fc = this.channels["file"];
    if (!fc || fc.readyState !== "open") {
      this._emit("error", "文件通道未就绪");
      return;
    }
    const id = crypto.randomUUID();
    this._pendingSend = { id, meta };
    mc.send(JSON.stringify({ t: "file_offer", id, name: meta.name, size: meta.size }));
  }

  async _sendFileData(id, meta) {
    const fc = this.channels["file"];
    const mc = this.channels["meta"];
    const CHUNK = 48 * 1024;
    let offset = 0;
    while (offset < meta.size && !this.closed) {
      if (fc.bufferedAmount > 1_000_000) {
        await sleep(15);
        continue;
      }
      const len = Math.min(CHUNK, meta.size - offset);
      const b64 = await invoke("read_file_chunk", { path: meta.path, offset, len });
      fc.send(b64ToBytes(b64));
      offset += len;
      this._emit("fileProgress", { id, current: offset, total: meta.size, outgoing: true });
    }
    mc.send(JSON.stringify({ t: "file_done", id }));
  }

  /** 只处理 `file` 通道上的二进制块 */
  _enqueueFile(data) {
    if (typeof data === "string") return; // 协议上不应出现
    this._fileChain = this._fileChain
      .then(() => this._writeChunk(data))
      .catch((e) => console.warn("file chunk error", e));
  }

  async _writeChunk(data) {
    if (!this._recv) return;
    const bytes = new Uint8Array(data);
    await invoke("file_write_chunk", {
      path: this._recv.path,
      offset: this._recv.offset,
      data: bytesToB64(bytes),
    });
    this._recv.offset += bytes.length;
    this._emit("fileProgress", {
      id: this._recv.id,
      current: this._recv.offset,
      total: this._recv.size,
      outgoing: false,
    });
  }

  /** 处理 `meta` 通道上的文件控制消息 */
  _enqueueFileCtl(msg) {
    this._fileChain = this._fileChain
      .then(() => this._handleFileCtl(msg))
      .catch((e) => console.warn("file ctl error", e));
  }

  /** `meta` 通道上收到 JSON 文本后分流 */
  _onMetaMessage(msg) {
    if (msg && typeof msg.t === "string" && msg.t.startsWith("file_")) {
      this._enqueueFileCtl(msg);
      return;
    }
    if (msg && msg.t === "screen") {
      this._peerSize = { w: msg.w, h: msg.h };
      this._emit("peerScreen", this._peerSize);
      return;
    }
    // ---- 语音 / 摄像头 ----
    if (msg && msg.t === "media_state") {
      this.media = parseMediaState(msg, this.media);
      this._emit("mediaState", { ...this.media });
      // 控制端希望开但被控端没开成 → 把原因抛给 UI 做可操作提示
      if (this.role === "controller" && this.desired && this.media.reason) {
        const wantMic = this.desired.mic && !this.media.micOn;
        const wantCam = this.desired.camera && !this.media.camOn;
        if (wantMic || wantCam) {
          const kind = wantMic ? "mic" : "camera";
          this._emit("mediaProblem", {
            reason: this.media.reason,
            kind,
            what: kind === "mic" ? "麦克风" : "摄像头",
            canOpenSettings: false,
            text: reasonText(this.media.reason),
          });
        }
      }
      return;
    }
    if (msg && msg.t === "media_req") {
      if (this.role === "controlled") this._applyMediaRequest(msg);
      return;
    }
    if (msg && msg.t === "media_track") {
      this._trackKinds = trackKindMap(this._trackKinds, msg);
      return;
    }
    this._emit("meta", msg);
  }

  async _handleFileCtl(msg) {
    const mc = this.channels["meta"];
    if (msg.t === "file_offer") {
      const r = await invoke("file_begin", { name: msg.name });
      this._recv = { id: msg.id, name: msg.name, size: msg.size, offset: 0, path: r.path };
      this._emit("fileIncoming", { name: msg.name, size: msg.size, path: r.path });
      mc.send(JSON.stringify({ t: "file_accept", id: msg.id }));
    } else if (msg.t === "file_accept") {
      if (this._pendingSend && this._pendingSend.id === msg.id) {
        const { id, meta } = this._pendingSend;
        this._pendingSend = null;
        await this._sendFileData(id, meta);
      }
    } else if (msg.t === "file_reject") {
      this._pendingSend = null;
      this._emit("error", "对方拒收文件");
    } else if (msg.t === "file_done") {
      if (this._recv) {
        const res = await invoke("file_finish", { path: this._recv.path });
        this._emit("fileDone", { name: this._recv.name, path: res.path });
        mc.send(JSON.stringify({ t: "file_ack", id: this._recv.id, ok: true }));
        this._recv = null;
      }
    }
  }

  // ---------- 画质 ----------
  async setQuality(level) {
    const presets = { low: 800_000, normal: 2_000_000, high: 5_000_000 };
    const maxBitrate = presets[level] || presets.normal;
    if (this.role === "controlled") {
      // 调整发送端编码码率
      for (const sender of this.pc.getSenders()) {
        if (!sender.track || sender.track.kind !== "video") continue;
        const params = sender.getParameters();
        if (!params.encodings || params.encodings.length === 0) params.encodings = [{}];
        params.encodings[0].maxBitrate = maxBitrate;
        try {
          await sender.setParameters(params);
        } catch (e) {
          console.warn("setParameters failed", e);
        }
      }
    }
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    // 先放设备：麦克风/摄像头指示灯必须立刻熄灭，不能等 pc.close()
    this.stopAllMedia();
    try {
      if (this._unlistenFrame) this._unlistenFrame();
    } catch {}
    try {
      await invoke("stop_capture");
    } catch {}
    for (const ch of Object.values(this.channels)) {
      try {
        ch.close();
      } catch {}
    }
    this.channels = {};
    if (this._captureStream) {
      this._captureStream.getTracks().forEach((t) => t.stop());
      this._captureStream = null;
    }
    if (this.pc) {
      try {
        this.pc.close();
      } catch {}
      this.pc = null;
    }
  }
}
