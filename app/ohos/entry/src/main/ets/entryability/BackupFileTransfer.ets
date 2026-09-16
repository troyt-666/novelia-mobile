import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { MethodCall, MethodResult } from '@ohos/flutter_ohos';

export default class BackupFileTransfer {
  private busy: boolean = false;
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) { this.context = context; }

  async handle(call: MethodCall, result: MethodResult): Promise<void> {
    if (call.method !== 'pickBackup' && call.method !== 'saveBackup') {
      result.notImplemented(); return;
    }
    if (this.busy) { result.error('busy', 'A document picker is already open', null); return; }
    this.busy = true;
    let temporary: string | null = null;
    try {
      const documents = new picker.DocumentViewPicker(this.context);
      if (call.method === 'saveBackup') {
        if (typeof call.args !== 'string') throw new Error('Missing backup path');
        const source = call.args;
        const options = new picker.DocumentSaveOptions();
        options.newFileNames = [source.substring(source.lastIndexOf('/') + 1)];
        const destinations = await documents.save(options);
        if (destinations.length === 0) { result.success(false); return; }
        await this.copyBounded(source, destinations[0]);
        result.success(true);
      } else {
        const options = new picker.DocumentSelectOptions();
        options.maxSelectNumber = 1;
        const sources = await documents.select(options);
        if (sources.length === 0) { result.success(null); return; }
        temporary = `${this.context.cacheDir}/jfz-backup-import-${Date.now()}.jfzbackup`;
        await this.copyBounded(sources[0], temporary);
        result.success(temporary);
        temporary = null;
      }
    } catch (_) {
      result.error('backup_file', 'Unable to copy backup (limit 128 MB)', null);
    } finally {
      if (temporary !== null) {
        try { await fs.unlink(temporary); } catch (_) { /* Partial temporary copy. */ }
      }
      this.busy = false;
    }
  }

  private async copyBounded(source: string, destination: string): Promise<void> {
    const input = await fs.open(source, fs.OpenMode.READ_ONLY);
    try {
      if ((await fs.stat(input.fd)).size > 128 * 1024 * 1024) throw new Error('Backup too large');
      const output = await fs.open(destination, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const buffer = new ArrayBuffer(64 * 1024);
        let total = 0;
        while (true) {
          const count = await fs.read(input.fd, buffer);
          if (count === 0) break;
          total += count;
          if (total > 128 * 1024 * 1024) throw new Error('Backup too large');
          let written = 0;
          while (written < count) {
            const chunk = buffer.slice(written, count);
            const size = await fs.write(output.fd, chunk);
            if (size <= 0) throw new Error('Unable to write backup');
            written += size;
          }
        }
        await fs.fsync(output.fd);
      } finally { await fs.close(output); }
    } finally { await fs.close(input); }
  }
}
