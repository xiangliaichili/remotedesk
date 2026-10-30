import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

const b64: util.Base64Helper = new util.Base64Helper();

/** 发送侧：按偏移读取本地文件分块。 */
export class FileSender {
  name: string = '';
  size: number = 0;
  private path: string = '';
  private file: fs.File | null = null;

  open(path: string, name: string, size: number): boolean {
    try {
      this.file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      this.path = path;
      this.name = name;
      this.size = size;
      return true;
    } catch (e) {
      this.file = null;
      return false;
    }
  }

  /** 返回 base64 编码的分块，读不到返回空串。 */
  readChunk(offset: number, len: number): string {
    if (this.file === null) {
      return '';
    }
    const want = Math.min(len, this.size - offset);
    if (want <= 0) {
      return '';
    }
    const buf = new ArrayBuffer(want);
    try {
      const read = fs.readSync(this.file.fd, buf, { offset: offset, length: want });
      if (read <= 0) {
        return '';
      }
      return b64.encodeToStringSync(new Uint8Array(buf.slice(0, read)));
    } catch (e) {
      return '';
    }
  }

  close(): void {
    if (this.file !== null) {
      try {
        fs.closeSync(this.file);
      } catch (e) {
        // ignore
      }
      this.file = null;
    }
  }
}

/** 接收侧：把远端分块顺序写入沙箱目录。 */
export class FileReceiver {
  private file: fs.File | null = null;
  path: string = '';
  name: string = '';

  static receivedDir(ctx: common.Context): string {
    const dir = ctx.filesDir + '/received';
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      // ignore
    }
    return dir;
  }

  /** 重名时追加 " (n)"，避免覆盖。 */
  private static uniquePath(dir: string, name: string): string {
    const dot = name.lastIndexOf('.');
    const stem = dot > 0 ? name.substring(0, dot) : name;
    const ext = dot > 0 ? name.substring(dot) : '';
    let candidate = dir + '/' + name;
    let i = 1;
    while (true) {
      try {
        if (!fs.accessSync(candidate)) {
          return candidate;
        }
      } catch (e) {
        return candidate;
      }
      candidate = dir + '/' + stem + ' (' + i + ')' + ext;
      i++;
      if (i > 999) {
        return dir + '/' + Date.now() + '_' + name;
      }
    }
  }

  open(ctx: common.Context, name: string): boolean {
    try {
      const target = FileReceiver.uniquePath(FileReceiver.receivedDir(ctx), name);
      this.file = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      this.path = target;
      this.name = name;
      return true;
    } catch (e) {
      this.file = null;
      return false;
    }
  }

  write(offset: number, data: string): boolean {
    if (this.file === null) {
      return false;
    }
    try {
      const bytes = b64.decodeSync(data);
      fs.writeSync(this.file.fd, bytes.buffer as ArrayBuffer, { offset: offset, length: bytes.length });
      return true;
    } catch (e) {
      return false;
    }
  }

  close(): string {
    const p = this.path;
    if (this.file !== null) {
      try {
        fs.closeSync(this.file);
      } catch (e) {
        // ignore
      }
      this.file = null;
    }
    return p;
  }
}

export interface PickedFile {
  uri: string;
  name: string;
  size: number;
}

/** 打开系统文件选择器。 */
export async function pickOneFile(ctx: common.Context): Promise<PickedFile | null> {
  try {
    const viewPicker = new picker.DocumentViewPicker(ctx);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    const uris = await viewPicker.select(options);
    if (uris === undefined || uris === null || uris.length === 0) {
      return null;
    }
    const uri = uris[0];
    let name = uri.substring(uri.lastIndexOf('/') + 1);
    name = decodeURIComponent(name);
    let size = 0;
    try {
      const st = fs.statSync(uri);
      size = st.size;
    } catch (e) {
      size = 0;
    }
    const out: PickedFile = { uri: uri, name: name, size: size };
    return out;
  } catch (e) {
    return null;
  }
}