import { webview } from '@kit.ArkWeb';
import { common, Want } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Api, ApiError } from '../common/Api';
import { Signaling, SignalListener } from '../common/Signaling';
import { Prefs } from '../common/Prefs';
import { FileReceiver, FileSender, pickOneFile, PickedFile } from '../common/Files';
import { checkMediaPermissions, deniedHint, ensureMediaPermissions, MediaPermissionResult } from '../common/Permissions';
import {
  AuthResult,
  ControlStartData,
  DeviceItem,
  DeviceListResult,
  ErrorData,
  MediaPolicy,
  SessionOkData,
  SessionReqData,
  SignalMessage,
  TurnInfo,
  WechatPollResult
} from '../common/Types';

/** 暴露给 WebView 的原生对象，JS 侧通过 window.rdNative.postMessage(...) 回调。 */
class NativeBridge {
  handler: (text: string) => void = (text: string) => {
  };

  postMessage(text: string): void {
    const fn = this.handler;
    if (fn !== null && fn !== undefined) {
      fn(text);
    }
  }
}

interface BridgeMessage {
  t: string;
  kind?: string;
  sdp?: string;
  candidate?: string;
  state?: string;
  label?: string;
  open?: boolean;
  evt?: object;
  msg?: object;
  id?: string;
  name?: string;
  size?: number;
  offset?: number;
  len?: number;
  b64?: string;
  w?: number;
  h?: number;
  text?: string;
  ok?: boolean;
  reason?: string;
  mic?: boolean;
  camera?: boolean;
  mic_on?: boolean;
  cam_on?: boolean;
}

@Entry
@Component
struct Index {
  // ---------- 视图状态 ----------
  @State view: string = 'auth'; // auth | home | remote
  @State busy: boolean = false;
  @State errText: string = '';

  // ---------- 登录 ----------
  @State serverInput: string = '';
  @State userInput: string = '';
  @State passInput: string = '';
  @State deviceNameInput: string = '';
  @State serverHint: string = '服务器地址，例如 https://rd.example.com';
  @State currentUser: string = '';
  @State online: boolean = false;

  // ---------- 登录方式（v1.03） ----------
  @State authTab: string = 'pwd'; // pwd | sms | wx
  @State smsPhone: string = '';
  @State smsCode: string = '';
  @State smsHint: string = '首次登录会自动创建账号';
  @State smsLeft: number = 0;
  @State smsEnabled: boolean = true;
  @State wxHint: string = '点下面按钮，在浏览器里用微信扫码，扫完这里会自动登录';
  @State wxEnabled: boolean = true;
  @State wxDev: boolean = false;

  // ---------- 设备 ----------
  @State devices: DeviceItem[] = [];

  // ---------- 连接码 ----------
  @State linkCode: string = '';
  @State linkExpire: string = '';

  // ---------- 账号密码连接 ----------
  @State peerUser: string = '';
  @State peerPass: string = '';

  // ---------- 设置 ----------
  @State settingsOpen: boolean = false;
  @State setAuto: boolean = false;
  @State setMic: boolean = true;
  @State setCam: boolean = false;

  // ---------- 远程 ----------
  @State remoteTitle: string = '远程控制';
  @State remoteState: string = '正在建立连接…';
  @State quality: string = 'normal';
  @State txText: string = '';
  @State txPct: number = 0;
  @State txVisible: boolean = false;
  @State textOpen: boolean = false;
  @State textInput: string = '';
  @State reqOpen: boolean = false;
  @State reqText: string = '';
  @State pickOpen: boolean = false;
  @State pickList: DeviceItem[] = [];

  // ---------- 语音 / 摄像头 ----------
  @State mediaText: string = '';
  @State micOn: boolean = false;
  @State camOn: boolean = false;
  @State wantMic: boolean = false;
  @State wantCam: boolean = false;
  @State audioMuted: boolean = false;
  @State permMic: boolean = false;
  @State permCam: boolean = false;

  // ---------- 非状态成员 ----------
  private api: Api = new Api('', '');
  private signaling: Signaling | null = null;
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: NativeBridge = new NativeBridge();

  private sessionId: string = '';
  private peerDeviceId: string = '';
  private turn: TurnInfo = { urls: [], username: '', credential: '' };
  private peerPolicy: MediaPolicy = { mic: false, camera: false };
  private role: string = 'controller';
  private webReady: boolean = false;
  private initPending: boolean = false;
  private pendingReqId: string = '';
  private pendingReqPeer: string = '';
  private pickPeerUser: string = '';
  private pickPeerPass: string = '';
  private sender: FileSender = new FileSender();
  private receiver: FileReceiver = new FileReceiver();
  private wxState: string = '';
  private wxTimer: number = -1;
  private smsTimer: number = -1;

  // ==================== 生命周期 ====================

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    Prefs.init(ctx);
    this.serverInput = Prefs.server();
    this.deviceNameInput = Prefs.deviceName();
    this.quality = Prefs.quality();
    this.bridge.handler = (text: string) => {
      this.onBridge(text);
    };

    // 静默查一次权限状态（不弹窗），设置页里显示"已授权/未授权"
    checkMediaPermissions(ctx).then((r: MediaPermissionResult) => {
      this.permMic = r.mic;
      this.permCam = r.camera;
    }).catch(() => {
      // ignore
    });

    const token = Prefs.token();
    if (token.length > 0) {
      this.api = new Api(Prefs.server(), token);
      this.currentUser = Prefs.username();
      this.view = 'home';
      this.connectSignaling();
      this.refreshDevices();
    } else {
      // 登录页：问一下服务端支持哪些登录方式
      this.loadAuthMethods();
    }
  }

  aboutToDisappear(): void {
    if (this.signaling !== null) {
      this.signaling.close();
      this.signaling = null;
    }
    this.sender.close();
    this.receiver.close();
    if (this.wxTimer >= 0) {
      clearInterval(this.wxTimer);
      this.wxTimer = -1;
    }
    if (this.smsTimer >= 0) {
      clearInterval(this.smsTimer);
      this.smsTimer = -1;
    }
  }

  // ==================== 账号 ====================

  private async doAuth(register: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    this.errText = '';
    if (this.serverInput.trim().length === 0) {
      this.errText = '请填写服务器地址';
      return;
    }
    if (this.userInput.trim().length < 3) {
      this.errText = '账号至少 3 位';
      return;
    }
    if (this.passInput.length < 6) {
      this.errText = '密码至少 6 位';
      return;
    }
    this.busy = true;
    Prefs.setServer(this.serverInput);
    Prefs.setDeviceName(this.deviceNameInput);
    this.api = new Api(Prefs.server(), '');
    try {
      const devName = Prefs.deviceName();
      const devId = Prefs.deviceId();
      const r = register
        ? await this.api.register(this.userInput.trim(), this.passInput, devName, devId)
        : await this.api.login(this.userInput.trim(), this.passInput, devName, devId);
      this.afterAuth(r);
    } catch (e) {
      const msg = e instanceof ApiError ? (e as ApiError).message : '网络异常，请检查服务器地址';
      this.errText = msg;
    } finally {
      this.busy = false;
    }
  }

  /** 三种登录方式共用的收尾。 */
  private afterAuth(r: AuthResult): void {
    Prefs.setAuth(r.token, r.username);
    Prefs.setServer(this.serverInput);
    this.api.token = r.token;
    this.api.setServer(this.serverInput);
    this.currentUser = r.username;
    this.passInput = '';
    this.smsCode = '';
    this.view = 'home';
    this.connectSignaling();
    this.refreshDevices();
  }

  // ==================== 登录方式（v1.03） ====================

  private switchAuthTab(kind: string): void {
    this.authTab = kind;
    this.errText = '';
  }

  /** 服务端支持哪些登录方式，未配置的入口隐藏。 */
  private async loadAuthMethods(): Promise<void> {
    const probe = new Api(this.serverInput.length > 0 ? this.serverInput : Prefs.server(), '');
    try {
      const m = await probe.authMethods();
      this.smsEnabled = m.smsEnabled;
      this.wxEnabled = m.wechatEnabled;
      this.wxDev = m.wechatDev;
      if (!m.smsEnabled) {
        this.smsHint = '服务端未开启短信登录';
      } else if (m.smsDev) {
        this.smsHint = '开发模式：验证码会自动填入';
      }
      if (!m.wechatEnabled) {
        this.wxHint = '服务端未配置微信登录（RD_WECHAT_APP_ID / SECRET）';
      }
    } catch (e) {
      // 服务器地址还没填对，保持默认
    }
  }

  private async sendSms(): Promise<void> {
    this.errText = '';
    const phone = this.smsPhone.trim();
    if (!new RegExp('^1[3-9]\\d{9}$').test(phone)) {
      this.errText = '请输入 11 位手机号';
      return;
    }
    if (this.smsLeft > 0) {
      return;
    }
    const api = new Api(this.serverInput, '');
    try {
      const devCode = await api.sendSmsCode(phone);
      if (devCode.length > 0) {
        this.smsCode = devCode;
        this.smsHint = '开发模式：验证码已自动填入（' + devCode + '）';
      } else {
        this.smsHint = '验证码已发送，5 分钟内有效';
      }
      this.startSmsCountdown(60);
    } catch (e) {
      const msg = e instanceof ApiError ? (e as ApiError).message : '发送失败';
      this.errText = msg;
    }
  }

  private startSmsCountdown(seconds: number): void {
    if (this.smsTimer >= 0) {
      clearInterval(this.smsTimer);
    }
    this.smsLeft = seconds;
    this.smsTimer = setInterval(() => {
      this.smsLeft = this.smsLeft - 1;
      if (this.smsLeft <= 0) {
        clearInterval(this.smsTimer);
        this.smsTimer = -1;
        this.smsLeft = 0;
      }
    }, 1000);
  }

  private async smsLogin(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.errText = '';
    const phone = this.smsPhone.trim();
    const code = this.smsCode.trim();
    if (phone.length !== 11) {
      this.errText = '请输入 11 位手机号';
      return;
    }
    if (code.length !== 6) {
      this.errText = '请输入 6 位验证码';
      return;
    }
    this.busy = true;
    const api = new Api(this.serverInput, '');
    try {
      const r = await api.smsLogin(phone, code, Prefs.deviceName(), Prefs.deviceId());
      this.afterAuth(r);
    } catch (e) {
      const msg = e instanceof ApiError ? (e as ApiError).message : '登录失败';
      this.errText = msg;
    } finally {
      this.busy = false;
    }
  }

  /** 微信扫码：打开浏览器授权 + 轮询结果。 */
  private async wxStart(): Promise<void> {
    this.errText = '';
    const api = new Api(this.serverInput, '');
    try {
      const session = await api.wechatAuthUrl(Prefs.deviceName(), Prefs.deviceId());
      this.wxState = session.state;
      this.wxHint = '已打开授权页，扫码后会自动登录…';
      const ctx = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: session.url
      };
      ctx.startAbility(want).catch(() => {
        this.wxHint = '无法打开浏览器，请手动访问：' + session.url;
      });
      this.pollWechat(session.state);
    } catch (e) {
      const msg = e instanceof ApiError ? (e as ApiError).message : '发起微信登录失败';
      this.errText = msg;
    }
  }

  private pollWechat(state: string): void {
    if (this.wxTimer >= 0) {
      clearInterval(this.wxTimer);
    }
    let waited = 0;
    const api = new Api(this.serverInput, '');
    this.wxTimer = setInterval(() => {
      waited += 2;
      if (waited > 600 || this.wxState !== state) {
        clearInterval(this.wxTimer);
        this.wxTimer = -1;
        return;
      }
      api.wechatPoll(state).then((r: WechatPollResult) => {
        if (r.status === 'ok') {
          clearInterval(this.wxTimer);
          this.wxTimer = -1;
          this.wxState = '';
          const res: AuthResult = {
            token: r.token,
            user_id: r.userId,
            device_id: r.deviceId.length > 0 ? r.deviceId : Prefs.deviceId(),
            username: r.username
          };
          this.afterAuth(res);
        } else if (r.status === 'error') {
          clearInterval(this.wxTimer);
          this.wxTimer = -1;
          this.wxState = '';
          this.wxHint = '登录失败：' + (r.message.length > 0 ? r.message : '授权被拒绝');
        } else if (r.status === 'expired' || r.status === 'consumed') {
          clearInterval(this.wxTimer);
          this.wxTimer = -1;
          this.wxState = '';
          this.wxHint = '二维码已失效，请重新发起';
        } else {
          this.wxHint = '等待扫码…（' + waited + 's）';
        }
      }).catch(() => {
        // 网络抖动继续轮询
      });
    }, 2000);
  }

  private async wxDevSimulate(): Promise<void> {
    if (this.wxState.length === 0) {
      this.errText = '请先点「打开微信扫码登录」';
      return;
    }
    const api = new Api(this.serverInput, '');
    try {
      await api.wechatDevSimulate(this.wxState, 'dev-openid-' + Prefs.deviceId().substring(0, 8));
      this.wxHint = '已模拟扫码，正在登录…';
    } catch (e) {
      const msg = e instanceof ApiError ? (e as ApiError).message : '模拟失败';
      this.errText = msg;
    }
  }

  private logout(): void {
    Prefs.clearAuth();
    if (this.signaling !== null) {
      this.signaling.close();
      this.signaling = null;
    }
    this.devices = [];
    this.online = false;
    this.view = 'auth';
  }

  // ==================== 信令 ====================

  private connectSignaling(): void {
    if (this.signaling !== null) {
      this.signaling.close();
      this.signaling = null;
    }
    const sig = new Signaling(this.api.base);
    const self = this;
    const listener: SignalListener = {
      onOpen(): void {
        self.online = true;
        self.refreshDevices();
      },
      onMessage(text: string): void {
        self.onWs(text);
      },
      onClosed(reason: string): void {
        self.online = false;
      }
    };
    sig.listener = listener;
    sig.connect(Prefs.token());
    this.signaling = sig;
  }

  private onWs(text: string): void {
    let msg: SignalMessage | null = null;
    try {
      msg = JSON.parse(text) as SignalMessage;
    } catch (e) {
      return;
    }
    if (msg === null) {
      return;
    }
    const type = msg.type;
    if (type === 'devices') {
      this.parseDevices(text);
      return;
    }
    if (type === 'offer' || type === 'answer' || type === 'ice') {
      this.jsSignal(type, msg.sdp, msg.candidate);
      return;
    }
    if (type === 'session_req') {
      const d = msg.data as SessionReqData;
      const name = d !== undefined && d.controller_name !== undefined ? d.controller_name : '未知设备';
      this.pendingReqId = msg.session_id !== undefined ? msg.session_id : '';
      this.pendingReqPeer = msg.from !== undefined ? msg.from : '';
      this.reqText = '「' + name + '」请求控制本机。\n注意：HarmonyOS 端暂不支持作为被控方。';
      this.reqOpen = true;
      return;
    }
    if (type === 'session_ok') {
      const d = msg.data as SessionOkData;
      const t = d !== undefined && d.turn !== undefined ? d.turn : Api.turnFrom(undefined);
      this.beginController(
        msg.from !== undefined ? msg.from : '',
        msg.session_id !== undefined ? msg.session_id : '',
        t,
        '远程控制',
        d !== undefined ? d.media : undefined
      );
      return;
    }
    if (type === 'session_deny') {
      this.busy = false;
      this.toast('对方拒绝了连接请求');
      return;
    }
    if (type === 'control_start') {
      const d = msg.data as ControlStartData;
      const name = d !== undefined && d.controller_name !== undefined ? d.controller_name : '';
      this.toast('「' + name + '」正在尝试控制本机（当前端不支持被控）');
      return;
    }
    if (type === 'control_end') {
      this.endControl(true);
      return;
    }
    if (type === 'error') {
      const d = msg.data as ErrorData;
      if (d !== undefined && d.message !== undefined) {
        this.toast(d.message);
      }
      this.busy = false;
    }
  }

  private jsSignal(kind: string, sdp: string | undefined, candidate: string | undefined): void {
    if (!this.webReady) {
      return;
    }
    const payload: Record<string, string> = { 'kind': kind };
    if (sdp !== undefined) {
      payload['sdp'] = sdp;
    }
    if (candidate !== undefined) {
      payload['candidate'] = candidate;
    }
    const script = 'window.RD && window.RD.signal(' + JSON.stringify(payload) + ');';
    this.runJs(script);
  }

  private runJs(script: string): void {
    this.controller.runJavaScript(script).catch((e: BusinessError) => {
      // 页面可能尚未就绪
    });
  }

  // ==================== 设备与连接 ====================

  private async refreshDevices(): Promise<void> {
    try {
      const list = await this.api.devices();
      const mine: DeviceItem[] = [];
      const myId = Prefs.deviceId();
      for (let i = 0; i < list.length; i++) {
        if (list[i].id !== myId) {
          mine.push(list[i]);
        }
      }
      this.devices = mine;
    } catch (e) {
      if (e instanceof ApiError && (e as ApiError).code === 401) {
        this.logout();
      }
    }
  }

  private parseDevices(text: string): void {
    try {
      const r = JSON.parse(text) as DeviceListResult;
      if (r.devices !== undefined) {
        this.devices = r.devices;
      }
    } catch (e) {
      // ignore
    }
  }

  private async startSameAccount(d: DeviceItem): Promise<void> {
    if (!d.online) {
      this.toast('该设备当前离线');
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    const payload: Record<string, object> = {
      'target_device_id': d.id,
      'auth': { 'mode': 'same_account' } as Record<string, string>
    };
    await this.requestAndStart(JSON.stringify(payload), d.name);
  }

  private async useLink(): Promise<void> {
    const code = this.linkCode.trim().toUpperCase();
    if (code.length === 0) {
      this.toast('请输入连接码');
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    const payload: Record<string, object> = {
      'auth': { 'mode': 'link', 'link_code': code } as Record<string, string>
    };
    await this.requestAndStart(JSON.stringify(payload), '连接码设备');
  }

  private async connectByAccount(): Promise<void> {
    const u = this.peerUser.trim();
    const p = this.peerPass;
    if (u.length < 3 || p.length < 6) {
      this.toast('请填写对方的账号与密码');
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const list = await this.api.lookup(u, p);
      this.busy = false;
      const targets: DeviceItem[] = [];
      for (let i = 0; i < list.length; i++) {
        if (list[i].online) {
          targets.push(list[i]);
        }
      }
      if (targets.length === 0) {
        this.toast('对方没有在线设备');
        return;
      }
      this.pickPeerUser = u;
      this.pickPeerPass = p;
      this.pickList = targets;
      this.pickOpen = true;
    } catch (e) {
      this.busy = false;
      const msg = e instanceof ApiError ? (e as ApiError).message : '查询失败';
      this.toast(msg);
    }
  }

  private choosePickDevice(d: DeviceItem): void {
    this.pickOpen = false;
    const payload: Record<string, object> = {
      'target_device_id': d.id,
      'auth': {
        'mode': 'account',
        'username': this.pickPeerUser,
        'password': this.pickPeerPass
      } as Record<string, string>
    };
    this.busy = true;
    this.requestAndStart(JSON.stringify(payload), d.name);
  }

  private async requestAndStart(payload: string, title: string): Promise<void> {
    try {
      const r = await this.api.requestSession(payload);
      this.busy = false;
      if (r.status === 'active') {
        const t = r.turn !== undefined ? r.turn : Api.turnFrom(undefined);
        this.beginController('', r.session_id, t, title, r.media);
      } else {
        this.toast('已发送请求，等待对方同意…');
      }
    } catch (e) {
      this.busy = false;
      const msg = e instanceof ApiError ? (e as ApiError).message : '连接失败';
      this.toast(msg);
    }
  }

  private async genLink(): Promise<void> {
    try {
      const r = await this.api.createLink();
      this.linkCode = r.code;
      const minute = r.ttl_minutes !== undefined ? r.ttl_minutes : 10;
      this.linkExpire = '有效期 ' + minute + ' 分钟，使用一次即失效';
    } catch (e) {
      const msg = e instanceof ApiError ? (e as ApiError).message : '生成失败';
      this.toast(msg);
    }
  }

  // ==================== 远程会话 ====================

  private beginController(peer: string, sessionId: string, turn: TurnInfo, title: string, media?: MediaPolicy): void {
    this.role = 'controller';
    this.peerDeviceId = peer;
    this.sessionId = sessionId;
    this.turn = turn;
    this.remoteTitle = title;
    this.remoteState = '正在建立连接…';
    this.txVisible = false;
    this.txPct = 0;
    this.webReady = false;
    this.initPending = true;
    this.wantMic = false;
    this.wantCam = false;
    this.micOn = false;
    this.camOn = false;
    this.mediaText = '';
    this.peerPolicy = media !== undefined
      ? { mic: media.mic, camera: media.camera }
      : { mic: false, camera: false };
    this.view = 'remote';
  }

  private initWebRtc(): void {
    if (!this.webReady) {
      this.initPending = true;
      return;
    }
    this.initPending = false;
    const opts: Record<string, object | string> = {
      'role': this.role,
      'sessionId': this.sessionId,
      'peer': this.peerDeviceId,
      'turn': this.turn,
      'quality': this.quality,
      'media': this.peerPolicy
    };
    this.runJs('window.RD && window.RD.init(' + JSON.stringify(opts) + ');');
  }

  private endControl(remote: boolean): void {
    const sid = this.sessionId;
    if (!remote && sid.length > 0) {
      this.api.cancelSession(sid).catch(() => {
        // 服务端可能已结束，忽略
      });
      if (this.signaling !== null) {
        const msg: Record<string, string> = {
          'type': 'cancel',
          'to': this.peerDeviceId,
          'session_id': sid
        };
        this.signaling.sendJson(JSON.stringify(msg));
      }
    }
    if (this.webReady) {
      this.runJs('window.RD && window.RD.close();');
    }
    this.sender.close();
    if (this.receiver.path.length > 0) {
      this.receiver.close();
    }
    this.sessionId = '';
    this.peerDeviceId = '';
    this.webReady = false;
    this.txVisible = false;
    this.mediaText = '';
    this.wantMic = false;
    this.wantCam = false;
    this.micOn = false;
    this.camOn = false;
    this.peerPolicy = { mic: false, camera: false };
    this.view = 'home';
    if (remote) {
      this.toast('对方已结束控制');
    }
    this.refreshDevices();
  }

  private cycleQuality(): void {
    let next = 'normal';
    if (this.quality === 'normal') {
      next = 'high';
    } else if (this.quality === 'high') {
      next = 'low';
    } else {
      next = 'normal';
    }
    this.quality = next;
    Prefs.setQuality(next);
    if (this.webReady) {
      this.runJs('window.RD && window.RD.setQuality(' + JSON.stringify(next) + ');');
    }
    const label = next === 'low' ? '流畅' : (next === 'high' ? '高清' : '标准');
    this.toast('画质：' + label);
  }

  private sendText(): void {
    const t = this.textInput;
    if (t.length === 0) {
      return;
    }
    if (this.webReady) {
      const evt: Record<string, string> = { 'type': 'text', 'text': t };
      this.runJs('window.RD && window.RD.sendInput(' + JSON.stringify(evt) + ');');
    }
    this.textInput = '';
    this.textOpen = false;
  }

  /** 控制端：开/关对方的麦克风或摄像头。 */
  private toggleMedia(kind: string): void {
    if (this.role !== 'controller' || !this.webReady) {
      return;
    }
    const allowed = kind === 'mic' ? this.peerPolicy.mic : this.peerPolicy.camera;
    const what = kind === 'mic' ? '麦克风' : '摄像头';
    if (!allowed) {
      this.toast('对方未开放' + what + '权限，请对方在设置里打开后重连');
      return;
    }
    if (kind === 'mic') {
      this.wantMic = !this.wantMic;
    } else {
      this.wantCam = !this.wantCam;
    }
    const mic = this.wantMic ? 'true' : 'false';
    const cam = this.wantCam ? 'true' : 'false';
    this.runJs('window.RD && window.RD.requestMedia(' + mic + ',' + cam + ');');
  }

  /** 控制端：静音对方声音（纯本地）。 */
  private toggleAudio(): void {
    this.audioMuted = !this.audioMuted;
    this.runJs('window.RD && window.RD.setAudioMuted(' + (this.audioMuted ? 'true' : 'false') + ');');
  }

  private async sendFile(): Promise<void> {
    if (!this.webReady) {
      this.toast('请先建立连接');
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const picked: PickedFile | null = await pickOneFile(ctx);
    if (picked === null) {
      return;
    }
    if (!this.sender.open(picked.uri, picked.name, picked.size)) {
      this.toast('无法读取该文件');
      return;
    }
    const id = 'f' + Date.now();
    this.txVisible = true;
    this.txText = picked.name;
    this.txPct = 0;
    const script = 'window.RD && window.RD.startSendFile(' + JSON.stringify(id) + ',' +
      JSON.stringify(picked.name) + ',' + picked.size + ');';
    this.runJs(script);
  }

  // ==================== WebView 桥 ====================

  private onBridge(text: string): void {
    let m: BridgeMessage | null = null;
    try {
      m = JSON.parse(text) as BridgeMessage;
    } catch (e) {
      return;
    }
    if (m === null) {
      return;
    }
    const t = m.t;

    if (t === 'signal') {
      const kind = m.kind !== undefined ? m.kind : '';
      if (this.signaling === null) {
        return;
      }
      const out: Record<string, string> = {
        'type': kind,
        'to': this.peerDeviceId,
        'session_id': this.sessionId
      };
      if (kind === 'ice') {
        out['candidate'] = m.candidate !== undefined ? m.candidate : '';
      } else {
        out['sdp'] = m.sdp !== undefined ? m.sdp : '';
      }
      this.signaling.sendJson(JSON.stringify(out));
      return;
    }

    if (t === 'state') {
      const s = m.state !== undefined ? m.state : '';
      if (s === 'connected') {
        this.remoteState = '';
      } else if (s === 'connecting' || s === 'new') {
        this.remoteState = '正在建立连接…';
      } else if (s === 'disconnected' || s === 'failed' || s === 'closed') {
        this.remoteState = '连接已断开';
      }
      return;
    }

    if (t === 'toast') {
      this.toast(m.text !== undefined ? m.text : '');
      return;
    }

    if (t === 'file_begin') {
      const ctx = getContext(this) as common.UIAbilityContext;
      const name = m.name !== undefined ? m.name : 'received.bin';
      const id = m.id !== undefined ? m.id : '';
      const ok = this.receiver.open(ctx, name);
      this.txVisible = true;
      this.txText = '接收：' + name;
      this.txPct = 0;
      this.runJs('window.RD && window.RD.fileOpened(' + JSON.stringify(id) + ',' + (ok ? 'true' : 'false') + ');');
      return;
    }

    if (t === 'file_chunk') {
      const offset = m.offset !== undefined ? m.offset : 0;
      const data = m.b64 !== undefined ? m.b64 : '';
      this.receiver.write(offset, data);
      return;
    }

    if (t === 'file_end') {
      const path = this.receiver.close();
      const id = m.id !== undefined ? m.id : '';
      this.txPct = 100;
      this.txText = '已保存：' + (path.length > 0 ? path : '接收目录');
      this.toast('文件已保存到应用沙箱');
      this.runJs('window.RD && window.RD.fileClosed(' + JSON.stringify(id) + ');');
      setTimeout(() => {
        this.txVisible = false;
      }, 2500);
      return;
    }

    if (t === 'need_chunk') {
      const offset = m.offset !== undefined ? m.offset : 0;
      const len = m.len !== undefined ? m.len : 48 * 1024;
      const chunk = this.sender.readChunk(offset, len);
      if (chunk.length === 0) {
        this.toast('读取文件失败');
        return;
      }
      if (this.sender.size > 0) {
        this.txPct = Math.min(99, Math.floor((offset + len) * 100 / this.sender.size));
      }
      this.runJs('window.RD && window.RD.pushChunk(' + JSON.stringify(chunk) + ');');
      return;
    }

    if (t === 'tx_done') {
      this.sender.close();
      this.txPct = 100;
      setTimeout(() => {
        this.txVisible = false;
      }, 2000);
      return;
    }

    if (t === 'remote_track') {
      this.remoteState = '';
      return;
    }

    // ---- 语音 / 摄像头 ----
    if (t === 'media_state') {
      this.micOn = m.mic_on === true;
      this.camOn = m.cam_on === true;
      const fmt = (allowed: boolean, on: boolean, label: string): string => {
        if (on) {
          return label + ' 已开';
        }
        return allowed ? label + ' 未开' : label + ' 已关权限';
      };
      let tail = '';
      const reason = m.reason !== undefined ? m.reason : '';
      if (reason === 'policy_off') {
        tail = ' · 被控端已关闭该权限';
      } else if (reason === 'permission_denied') {
        tail = ' · 系统权限未授予';
      } else if (reason === 'no_device') {
        tail = ' · 没有可用设备';
      } else if (reason === 'busy') {
        tail = ' · 设备被占用';
      }
      this.mediaText = fmt(m.mic === true, this.micOn, '麦克风') + ' · ' +
        fmt(m.camera === true, this.camOn, '摄像头') + tail;
      return;
    }

    if (t === 'media_want') {
      this.wantMic = m.mic === true;
      this.wantCam = m.camera === true;
      return;
    }

    if (t === 'media_problem') {
      const kind = m.kind !== undefined ? m.kind : 'mic';
      const reason = m.reason !== undefined ? m.reason : '';
      const what = kind === 'mic' ? '麦克风' : '摄像头';
      let msg = what + ' 打开失败（' + reason + '）';
      if (reason === 'permission_denied') {
        msg = '系统未允许使用' + what + '，请在「设置 → 应用 → 权限」中开启后重试';
      } else if (reason === 'no_device') {
        msg = '没有可用的' + what;
      } else if (reason === 'busy') {
        msg = what + '正被其它应用占用，请关闭后重试';
      } else if (reason === 'policy_off') {
        msg = '本机设置里已关闭' + what + '，本次不会采集';
      }
      this.toast(msg);
      return;
    }
  }

  // ==================== 设置 ====================

  private async openSettings(): Promise<void> {
    try {
      const s = await this.api.getSettings();
      this.setAuto = s.auto_accept_same_account;
      this.setMic = s.mic_enabled;
      this.setCam = s.camera_enabled;
    } catch (e) {
      // 用默认值
    }
    this.settingsOpen = true;
  }

  private async saveSettings(): Promise<void> {
    try {
      await this.api.putSettings(this.setAuto, this.setMic, this.setCam);
      // 打开开关时顺便申请运行时权限，避免真正被控时才手忙脚乱
      if (this.setMic || this.setCam) {
        const ctx = getContext(this) as common.UIAbilityContext;
        const r = await ensureMediaPermissions(ctx, this.setMic, this.setCam);
        this.permMic = r.mic;
        this.permCam = r.camera;
        const hint = deniedHint(r, this.setMic, this.setCam);
        if (hint.length > 0) {
          this.toast(hint);
        }
      }
      this.settingsOpen = false;
      this.toast('设置已保存');
    } catch (e) {
      const msg = e instanceof ApiError ? (e as ApiError).message : '保存失败';
      this.toast(msg);
    }
  }

  private toast(text: string): void {
    if (text.length === 0) {
      return;
    }
    promptAction.showToast({ message: text, duration: 2200 });
  }

  // ==================== UI ====================

  @Builder
  fieldCard(label: string, value: string, hint: string, onChange: (v: string) => void, inputType: InputType) {
    Column({ space: 6 }) {
      Text(label).fontSize(12).fontColor($r('app.color.muted')).width('100%')
      TextInput({ text: value, placeholder: hint })
        .type(inputType)
        .height(46)
        .fontSize(15)
        .fontColor($r('app.color.fg'))
        .placeholderColor($r('app.color.muted'))
        .backgroundColor($r('app.color.panel2'))
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .onChange((v: string) => {
          onChange(v);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  primaryButton(label: string, action: () => void) {
    Button(label)
      .width('100%')
      .height(46)
      .fontSize(16)
      .fontColor(Color.White)
      .backgroundColor($r('app.color.accent'))
      .borderRadius(12)
      .enabled(!this.busy)
      .onClick(() => {
        action();
      })
  }

  @Builder
  ghostButton(label: string, action: () => void) {
    Button(label)
      .width('100%')
      .height(42)
      .fontSize(15)
      .fontColor($r('app.color.fg'))
      .backgroundColor($r('app.color.panel2'))
      .borderRadius(12)
      .onClick(() => {
        action();
      })
  }

  @Builder
  AuthView() {
    Column() {
      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 4 }) {
            Text('远程桌面').fontSize(26).fontWeight(FontWeight.Bold).fontColor($r('app.color.fg'))
            Text('手机 · 电脑 · 平板 互相控制').fontSize(13).fontColor($r('app.color.muted'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 40, bottom: 8 })

          this.fieldCard('服务器', this.serverInput, 'https://rd.example.com', (v: string) => {
            this.serverInput = v;
          }, InputType.URL)

          // 登录方式切换
          Row({ space: 6 }) {
            Button('账号密码')
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .fontColor(this.authTab === 'pwd' ? Color.White : $r('app.color.muted'))
              .backgroundColor(this.authTab === 'pwd' ? $r('app.color.accent2') : $r('app.color.panel2'))
              .borderRadius(10)
              .onClick(() => {
                this.switchAuthTab('pwd');
              })
            if (this.smsEnabled) {
              Button('手机验证码')
                .layoutWeight(1)
                .height(38)
                .fontSize(13)
                .fontColor(this.authTab === 'sms' ? Color.White : $r('app.color.muted'))
                .backgroundColor(this.authTab === 'sms' ? $r('app.color.accent2') : $r('app.color.panel2'))
                .borderRadius(10)
                .onClick(() => {
                  this.switchAuthTab('sms');
                })
            }
            if (this.wxEnabled) {
              Button('微信登录')
                .layoutWeight(1)
                .height(38)
                .fontSize(13)
                .fontColor(this.authTab === 'wx' ? Color.White : $r('app.color.muted'))
                .backgroundColor(this.authTab === 'wx' ? $r('app.color.accent2') : $r('app.color.panel2'))
                .borderRadius(10)
                .onClick(() => {
                  this.switchAuthTab('wx');
                })
            }
          }
          .width('100%')

          if (this.authTab === 'pwd') {
            this.fieldCard('账号', this.userInput, '至少 3 位', (v: string) => {
              this.userInput = v;
            }, InputType.Normal)

            this.fieldCard('密码', this.passInput, '至少 6 位', (v: string) => {
              this.passInput = v;
            }, InputType.Password)
          }

          if (this.authTab === 'sms') {
            this.fieldCard('手机号', this.smsPhone, '11 位手机号', (v: string) => {
              this.smsPhone = v;
            }, InputType.PhoneNumber)

            Row({ space: 8 }) {
              TextInput({ text: this.smsCode, placeholder: '6 位验证码' })
                .type(InputType.Number)
                .maxLength(6)
                .height(46)
                .fontSize(15)
                .fontColor($r('app.color.fg'))
                .placeholderColor($r('app.color.muted'))
                .backgroundColor($r('app.color.panel2'))
                .borderRadius(12)
                .layoutWeight(1)
                .onChange((v: string) => {
                  this.smsCode = v;
                })
              Button(this.smsLeft > 0 ? (this.smsLeft + 's') : '获取验证码')
                .height(46)
                .fontSize(13)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.accent2'))
                .borderRadius(12)
                .enabled(this.smsLeft === 0)
                .onClick(() => {
                  this.sendSms();
                })
            }
            .width('100%')

            Text(this.smsHint).fontSize(11).fontColor($r('app.color.muted')).width('100%')
          }

          if (this.authTab === 'wx') {
            Text(this.wxHint).fontSize(12).fontColor($r('app.color.muted')).width('100%')

            this.primaryButton('打开微信扫码登录', () => {
              this.wxStart();
            })

            if (this.wxDev) {
              this.ghostButton('模拟扫码（开发模式）', () => {
                this.wxDevSimulate();
              })
            }
          }

          this.fieldCard('本机名称', this.deviceNameInput, '例如 我的手机', (v: string) => {
            this.deviceNameInput = v;
          }, InputType.Normal)

          if (this.errText.length > 0) {
            Text(this.errText).fontSize(13).fontColor($r('app.color.danger')).width('100%')
          }

          if (this.authTab === 'pwd') {
            this.primaryButton(this.busy ? '请稍候…' : '登录', () => {
              this.doAuth(false);
            })

            this.ghostButton('注册并登录', () => {
              this.doAuth(true);
            })
          } else if (this.authTab === 'sms') {
            this.primaryButton(this.busy ? '请稍候…' : '登录 / 注册', () => {
              this.smsLogin();
            })
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 40 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  @Builder
  DeviceRow(d: DeviceItem) {
    Row({ space: 12 }) {
      Circle({ width: 8, height: 8 })
        .fill(d.online ? $r('app.color.ok') : $r('app.color.muted'))
      Column({ space: 2 }) {
        Text(d.name).fontSize(15).fontColor($r('app.color.fg')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text((d.online ? '在线 · ' : '离线 · ') + d.os).fontSize(12).fontColor($r('app.color.muted'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button('连接')
        .height(34)
        .fontSize(14)
        .fontColor(Color.White)
        .backgroundColor(d.online ? $r('app.color.accent') : $r('app.color.line'))
        .borderRadius(10)
        .enabled(d.online)
        .onClick(() => {
          this.startSameAccount(d);
        })
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.panel2'))
    .borderRadius(12)
  }

  @Builder
  HomeView() {
    Column() {
      // 顶栏
      Row({ space: 10 }) {
        Circle({ width: 8, height: 8 }).fill(this.online ? $r('app.color.ok') : $r('app.color.muted'))
        Text(this.currentUser).fontSize(15).fontColor($r('app.color.fg')).layoutWeight(1)
        Button('设置')
          .height(32)
          .fontSize(13)
          .fontColor($r('app.color.fg'))
          .backgroundColor($r('app.color.panel2'))
          .borderRadius(10)
          .onClick(() => {
            this.openSettings();
          })
        Button('退出')
          .height(32)
          .fontSize(13)
          .fontColor($r('app.color.muted'))
          .backgroundColor($r('app.color.panel2'))
          .borderRadius(10)
          .onClick(() => {
            this.logout();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 12 })

      Scroll() {
        Column({ space: 14 }) {
          // 我的设备
          Column({ space: 10 }) {
            Row() {
              Text('我的设备').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg')).layoutWeight(1)
              Text('刷新').fontSize(13).fontColor($r('app.color.accent')).onClick(() => {
                this.refreshDevices();
              })
            }
            .width('100%')

            if (this.devices.length === 0) {
              Text('暂无设备，先在其它端登录同一账号')
                .fontSize(13)
                .fontColor($r('app.color.muted'))
                .width('100%')
                .padding({ top: 12, bottom: 12 })
            } else {
              ForEach(this.devices, (d: DeviceItem) => {
                this.DeviceRow(d)
              }, (d: DeviceItem) => d.id)
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.panel'))
          .borderRadius(16)

          // 统一连接码
          Column({ space: 10 }) {
            Text('统一连接码').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg')).width('100%')
            Text('别人用这个码可直接连接本机；也能用它连接别人。')
              .fontSize(12)
              .fontColor($r('app.color.muted'))
              .width('100%')

            if (this.linkCode.length > 0) {
              Column({ space: 4 }) {
                Text(this.linkCode).fontSize(30).fontWeight(FontWeight.Bold).fontColor($r('app.color.accent')).letterSpacing(6)
                Text(this.linkExpire).fontSize(12).fontColor($r('app.color.muted'))
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('app.color.panel2'))
              .borderRadius(12)
            }

            this.ghostButton('生成连接码', () => {
              this.genLink();
            })

            Row({ space: 8 }) {
              TextInput({ text: this.linkCode, placeholder: '输入对方的 8 位连接码' })
                .height(44)
                .fontSize(15)
                .fontColor($r('app.color.fg'))
                .placeholderColor($r('app.color.muted'))
                .backgroundColor($r('app.color.panel2'))
                .borderRadius(12)
                .layoutWeight(1)
                .onChange((v: string) => {
                  this.linkCode = v.toUpperCase();
                })
              Button('连接')
                .height(44)
                .fontSize(15)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.accent2'))
                .borderRadius(12)
                .onClick(() => {
                  this.useLink();
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.panel'))
          .borderRadius(16)

          // 用对方账号密码
          Column({ space: 10 }) {
            Text('用对方账号密码控制').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg')).width('100%')
            Text('输入对方账号密码，选择其在线设备发起控制。').fontSize(12).fontColor($r('app.color.muted')).width('100%')

            TextInput({ text: this.peerUser, placeholder: '对方账号' })
              .height(44)
              .fontSize(15)
              .fontColor($r('app.color.fg'))
              .placeholderColor($r('app.color.muted'))
              .backgroundColor($r('app.color.panel2'))
              .borderRadius(12)
              .onChange((v: string) => {
                this.peerUser = v;
              })

            TextInput({ text: this.peerPass, placeholder: '对方密码' })
              .type(InputType.Password)
              .height(44)
              .fontSize(15)
              .fontColor($r('app.color.fg'))
              .placeholderColor($r('app.color.muted'))
              .backgroundColor($r('app.color.panel2'))
              .borderRadius(12)
              .onChange((v: string) => {
                this.peerPass = v;
              })

            this.primaryButton('连接对方设备', () => {
              this.connectByAccount();
            })
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.panel'))
          .borderRadius(16)

          Text('HarmonyOS 端当前仅作为控制方；被控端请使用 Windows 或 Android 客户端。')
            .fontSize(11)
            .fontColor($r('app.color.muted'))
            .width('100%')
            .padding({ left: 4, bottom: 24 })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  @Builder
  RemoteView() {
    Column() {
      // 顶部工具条
      Row({ space: 8 }) {
        Button('结束')
          .height(32)
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.danger'))
          .borderRadius(10)
          .onClick(() => {
            this.endControl(false);
          })
        Text(this.remoteTitle)
          .fontSize(14)
          .fontColor($r('app.color.fg'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('画质')
          .height(32)
          .fontSize(13)
          .fontColor($r('app.color.fg'))
          .backgroundColor($r('app.color.panel2'))
          .borderRadius(10)
          .onClick(() => {
            this.cycleQuality();
          })
        Button('键盘')
          .height(32)
          .fontSize(13)
          .fontColor($r('app.color.fg'))
          .backgroundColor($r('app.color.panel2'))
          .borderRadius(10)
          .onClick(() => {
            this.textOpen = true;
          })
        Button('文件')
          .height(32)
          .fontSize(13)
          .fontColor($r('app.color.fg'))
          .backgroundColor($r('app.color.panel2'))
          .borderRadius(10)
          .onClick(() => {
            this.sendFile();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor($r('app.color.panel'))

      // 语音 / 摄像头工具条
      Row({ space: 8 }) {
        Button(this.wantMic ? '语音·开' : '语音')
          .height(30)
          .fontSize(12)
          .fontColor(this.wantMic ? Color.White : $r('app.color.fg'))
          .backgroundColor(this.wantMic ? $r('app.color.accent2') : $r('app.color.panel2'))
          .borderRadius(9)
          .enabled(this.peerPolicy.mic)
          .onClick(() => {
            this.toggleMedia('mic');
          })
        Button(this.wantCam ? '摄像头·开' : '摄像头')
          .height(30)
          .fontSize(12)
          .fontColor(this.wantCam ? Color.White : $r('app.color.fg'))
          .backgroundColor(this.wantCam ? $r('app.color.accent2') : $r('app.color.panel2'))
          .borderRadius(9)
          .enabled(this.peerPolicy.camera)
          .onClick(() => {
            this.toggleMedia('camera');
          })
        Button(this.audioMuted ? '声音关' : '声音开')
          .height(30)
          .fontSize(12)
          .fontColor($r('app.color.fg'))
          .backgroundColor($r('app.color.panel2'))
          .borderRadius(9)
          .onClick(() => {
            this.toggleAudio();
          })
        Text(this.mediaText.length > 0 ? this.mediaText : '（对方未开放音视频时会显示原因）')
          .fontSize(10)
          .fontColor($r('app.color.muted'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor($r('app.color.panel2'))

      Stack({ alignContent: Alignment.Center }) {
        Web({ src: $rawfile('rdwebrtc.html'), controller: this.controller })
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(true)
          .mediaPlayGestureAccess(false)
          .javaScriptProxy({
            object: this.bridge,
            name: 'rdNative',
            methodList: ['postMessage'],
            controller: this.controller
          })
          .onPageEnd(() => {
            this.webReady = true;
            if (this.initPending) {
              this.initWebRtc();
            }
          })
          // ArkWeb 的媒体授权：getUserMedia 会先问这里，不放行则直接失败
          .onPermissionRequest((event) => {
            const request = event.request;
            const resources = request.getAccessibleResource();
            const allow: Array<webview.ProtectedResourceType> = [];
            for (let i = 0; i < resources.length; i++) {
              const r = resources[i];
              if (r === webview.ProtectedResourceType.AUDIO_CAPTURE) {
                if (this.setMic) {
                  allow.push(r);
                }
              } else if (r === webview.ProtectedResourceType.VIDEO_CAPTURE) {
                if (this.setCam) {
                  allow.push(r);
                }
              }
            }
            if (allow.length > 0) {
              request.grant(allow);
            } else {
              request.deny();
            }
          })
          .width('100%')
          .height('100%')

        if (this.remoteState.length > 0) {
          Text(this.remoteState)
            .fontSize(14)
            .fontColor($r('app.color.muted'))
            .padding(16)
            .backgroundColor('#CC1C232D')
            .borderRadius(12)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(Color.Black)

      if (this.txVisible) {
        Column({ space: 6 }) {
          Text(this.txText)
            .fontSize(12)
            .fontColor($r('app.color.fg'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Progress({ value: this.txPct, total: 100, type: ProgressType.Linear })
            .width('100%')
            .color($r('app.color.accent'))
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.panel'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }

  @Builder
  SettingsDialog() {
    Column({ space: 14 }) {
      Text('设置').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg')).width('100%')

      Row({ space: 10 }) {
        Text('同账号设备免同意连接（仍会弹出控制提示）')
          .fontSize(13)
          .fontColor($r('app.color.fg'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.setAuto })
          .selectedColor($r('app.color.accent'))
          .onChange((on: boolean) => {
            this.setAuto = on;
          })
      }
      .width('100%')

      Row({ space: 10 }) {
        Text('允许传输语音')
          .fontSize(13)
          .fontColor($r('app.color.fg'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.setMic })
          .selectedColor($r('app.color.accent'))
          .onChange((on: boolean) => {
            this.setMic = on;
          })
      }
      .width('100%')

      Row({ space: 10 }) {
        Text('允许传输摄像头画面')
          .fontSize(13)
          .fontColor($r('app.color.fg'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.setCam })
          .selectedColor($r('app.color.accent'))
          .onChange((on: boolean) => {
            this.setCam = on;
          })
      }
      .width('100%')

      Text('系统权限：麦克风' + (this.permMic ? '已授权' : '未授权') + ' · 摄像头' + (this.permCam ? '已授权' : '未授权'))
        .fontSize(11)
        .fontColor(this.permMic && this.permCam ? $r('app.color.muted') : $r('app.color.danger'))
        .width('100%')

      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor($r('app.color.fg'))
          .backgroundColor($r('app.color.panel2'))
          .borderRadius(12)
          .onClick(() => {
            this.settingsOpen = false;
          })
        Button('保存')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.accent'))
          .borderRadius(12)
          .onClick(() => {
            this.saveSettings();
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('86%')
    .padding(20)
    .backgroundColor($r('app.color.panel'))
    .borderRadius(18)
  }

  @Builder
  RequestDialog() {
    Column({ space: 14 }) {
      Text('连接请求').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg')).width('100%')
      Text(this.reqText).fontSize(14).fontColor($r('app.color.fg')).width('100%')
      Row({ space: 10 }) {
        Button('拒绝')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.danger'))
          .borderRadius(12)
          .onClick(() => {
            this.reqOpen = false;
            if (this.pendingReqId.length > 0) {
              this.api.acceptSession(this.pendingReqId, false).catch(() => {
                // ignore
              });
            }
          })
        Button('同意并提示')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.accent'))
          .borderRadius(12)
          .onClick(() => {
            this.reqOpen = false;
            if (this.pendingReqId.length > 0) {
              this.api.acceptSession(this.pendingReqId, false).catch(() => {
                // ignore
              });
            }
            this.toast('HarmonyOS 端暂不支持作为被控方，请改用 Windows / Android 客户端');
          })
      }
      .width('100%')
    }
    .width('86%')
    .padding(20)
    .backgroundColor($r('app.color.panel'))
    .borderRadius(18)
  }

  @Builder
  PickDialog() {
    Column({ space: 12 }) {
      Text('选择要控制的设备').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg')).width('100%')
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.pickList, (d: DeviceItem) => {
            Row({ space: 10 }) {
              Circle({ width: 8, height: 8 }).fill($r('app.color.ok'))
              Text(d.name)
                .fontSize(15)
                .fontColor($r('app.color.fg'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(d.os).fontSize(12).fontColor($r('app.color.muted'))
            }
            .width('100%')
            .padding(14)
            .backgroundColor($r('app.color.panel2'))
            .borderRadius(12)
            .onClick(() => {
              this.choosePickDevice(d);
            })
          }, (d: DeviceItem) => d.id)
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 300 })
      .scrollBar(BarState.Off)

      Button('取消')
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontColor($r('app.color.fg'))
        .backgroundColor($r('app.color.panel2'))
        .borderRadius(12)
        .onClick(() => {
          this.pickOpen = false;
        })
    }
    .width('86%')
    .padding(20)
    .backgroundColor($r('app.color.panel'))
    .borderRadius(18)
  }

  @Builder
  TextDialog() {
    Column({ space: 14 }) {
      Text('发送文本').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.fg')).width('100%')
      TextInput({ text: this.textInput, placeholder: '输入要发送到远端的文本' })
        .height(46)
        .fontSize(15)
        .fontColor($r('app.color.fg'))
        .placeholderColor($r('app.color.muted'))
        .backgroundColor($r('app.color.panel2'))
        .borderRadius(12)
        .onChange((v: string) => {
          this.textInput = v;
        })
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor($r('app.color.fg'))
          .backgroundColor($r('app.color.panel2'))
          .borderRadius(12)
          .onClick(() => {
            this.textOpen = false;
          })
        Button('发送')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.accent'))
          .borderRadius(12)
          .onClick(() => {
            this.sendText();
          })
      }
      .width('100%')
    }
    .width('86%')
    .padding(20)
    .backgroundColor($r('app.color.panel'))
    .borderRadius(18)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.view === 'auth') {
        this.AuthView()
      } else if (this.view === 'home') {
        this.HomeView()
      } else {
        this.RemoteView()
      }

      if (this.settingsOpen) {
        Column() {
          this.SettingsDialog()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
      }

      if (this.reqOpen) {
        Column() {
          this.RequestDialog()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
      }

      if (this.textOpen) {
        Column() {
          this.TextDialog()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
      }

      if (this.pickOpen) {
        Column() {
          this.PickDialog()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }
}