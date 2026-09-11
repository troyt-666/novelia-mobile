
import { FlutterAbility, FlutterEngine, MethodChannel, MethodCall, MethodResult, EventChannel, EventSink, Any } from '@ohos/flutter_ohos';
import { inputConsumer, KeyCode, KeyEvent } from '@kit.InputKit';
import bundleManager from '@ohos.bundle.bundleManager';
import { BusinessError } from '@ohos.base';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import AccountSessionStore from './AccountSessionStore';

export default class EntryAbility extends FlutterAbility {
  private sessionQueue: Promise<void> = Promise.resolve();
  private readerVolumeEvents: EventSink | null = null;
  private volumeUp = (_event: KeyEvent): void => this.readerVolumeEvents?.success(-1);
  private volumeDown = (_event: KeyEvent): void => this.readerVolumeEvents?.success(1);

  private stopReaderVolumeKeys() {
    if (this.readerVolumeEvents === null) return;
    this.readerVolumeEvents = null;
    inputConsumer.off('keyPressed', this.volumeUp);
    inputConsumer.off('keyPressed', this.volumeDown);
  }

  cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
    this.stopReaderVolumeKeys();
    super.cleanUpFlutterEngine(flutterEngine);
  }

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
    new EventChannel(messenger, 'io.github.troyt666.jfzreader/reader_volume_keys')
      .setStreamHandler({
        onListen: (_args: Any, events: EventSink): void => {
          this.readerVolumeEvents = events;
          try {
            inputConsumer.on('keyPressed', {
              key: KeyCode.KEYCODE_VOLUME_UP, action: 1, isRepeat: false
            }, this.volumeUp);
            inputConsumer.on('keyPressed', {
              key: KeyCode.KEYCODE_VOLUME_DOWN, action: 1, isRepeat: false
            }, this.volumeDown);
          } catch (error) {
            this.stopReaderVolumeKeys();
            const failure = error as BusinessError;
            events.error('volume_keys', 'Unable to listen for volume keys', failure.code);
          }
        },
        onCancel: (_args: Any): void => this.stopReaderVolumeKeys()
      });
    const sessions = new AccountSessionStore(this.context);
    new MethodChannel(messenger, 'io.github.troyt666.jfzreader/account_session')
      .setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult) => {
        this.sessionQueue = this.sessionQueue.then(async () => {
          switch (call.method) {
            case 'read': result.success(await sessions.read()); break;
            case 'write':
              if (typeof call.args !== 'string' || call.args.length === 0) {
                result.error('invalid_session', 'Expected a non-empty session string', null);
                break;
              }
              await sessions.write(call.args);
              result.success(null);
              break;
            case 'clear': await sessions.clear(); result.success(null); break;
            default: result.notImplemented();
          }
        }).catch((error: BusinessError) => {
          result.error('session_store', 'Unable to access secure account storage', error.code);
        });
      } });
    new MethodChannel(messenger, 'io.github.troyt666.jfzreader/app_version')
      .setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult) => {
        if (call.method !== 'get') { result.notImplemented(); return; }
        try {
          const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
          result.success(new Map<string, string>([
            ['name', info.versionName], ['buildNumber', info.versionCode.toString()]
          ]));
        } catch (error) {
          result.error('app_version', 'Unable to read app version', (error as BusinessError).code);
        }
      } });
    new MethodChannel(messenger, 'io.github.troyt666.jfzreader/external_links')
      .setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult) => {
        if (call.method !== 'open') { result.notImplemented(); return; }
        if (typeof call.args !== 'string' || !/^https?:\/\/[^\s/]+/i.test(call.args)) {
          result.error('invalid_url', 'Only HTTP(S) links are allowed', null);
          return;
        }
        this.context.openLink(call.args)
          .then(() => result.success(true))
          .catch((error: BusinessError) => result.error('external_link', 'Unable to open link', error.code));
      } });
  }
}
