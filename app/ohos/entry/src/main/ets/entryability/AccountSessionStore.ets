import asset from '@ohos.security.asset';
import crypto from '@ohos.security.cryptoFramework';
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';

interface EncryptedSession {
  iv: string;
  tag: string;
  data: string;
}

// Asset secrets are limited to 1024 bytes. Store only the AES key there;
// keep the complete cookie/token pair in one authenticated, encrypted value.
export default class AccountSessionStore {
  private encoder = new util.TextEncoder();
  private decoder = new util.TextDecoder('utf-8');
  private base64 = new util.Base64Helper();
  private alias = this.encoder.encodeInto('jfzreader.account_session.v1');

  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  private key(create: boolean): crypto.SymKey {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.alias);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let bytes: Uint8Array;
    try {
      bytes = asset.querySync(query)[0].get(asset.Tag.SECRET) as Uint8Array;
    } catch (error) {
      if (!create || (error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) {
        throw error as Error;
      }
      bytes = crypto.createRandom().generateRandomSync(32).data;
      const attributes: asset.AssetMap = new Map();
      attributes.set(asset.Tag.ALIAS, this.alias);
      attributes.set(asset.Tag.SECRET, bytes);
      attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      asset.addSync(attributes);
    }
    return crypto.createSymKeyGenerator('AES256').convertKeySync({ data: bytes });
  }

  async read(): Promise<string | null> {
    const store = await preferences.getPreferences(this.context, { name: 'account_session' });
    const encoded = await store.get('encrypted', '') as string;
    if (encoded.length === 0) return null;
    const saved = JSON.parse(encoded) as EncryptedSession;
    if (typeof saved.iv !== 'string' || typeof saved.tag !== 'string' || typeof saved.data !== 'string') {
      throw new Error('Invalid encrypted session');
    }
    const params: crypto.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: this.base64.decodeSync(saved.iv) },
      aad: { data: this.alias },
      authTag: { data: this.base64.decodeSync(saved.tag) }
    };
    const cipher = crypto.createCipher('AES256|GCM|NoPadding');
    cipher.initSync(crypto.CryptoMode.DECRYPT_MODE, this.key(false), params);
    const plain = cipher.updateSync({ data: this.base64.decodeSync(saved.data) });
    cipher.doFinalSync(null); // Verify the tag before returning any plaintext.
    return this.decoder.decodeWithStream(plain.data);
  }

  async write(value: string): Promise<void> {
    const params: crypto.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: crypto.createRandom().generateRandomSync(12),
      aad: { data: this.alias },
      authTag: { data: new Uint8Array(16) }
    };
    const cipher = crypto.createCipher('AES256|GCM|NoPadding');
    cipher.initSync(crypto.CryptoMode.ENCRYPT_MODE, this.key(true), params);
    const encrypted = cipher.updateSync({ data: this.encoder.encodeInto(value) });
    const tag = cipher.doFinalSync(null);
    const saved: EncryptedSession = {
      iv: this.base64.encodeToStringSync(params.iv.data),
      tag: this.base64.encodeToStringSync(tag.data),
      data: this.base64.encodeToStringSync(encrypted.data)
    };
    const store = await preferences.getPreferences(this.context, { name: 'account_session' });
    await store.put('encrypted', JSON.stringify(saved));
    await store.flush();
  }

  async clear(): Promise<void> {
    const store = await preferences.getPreferences(this.context, { name: 'account_session' });
    await store.delete('encrypted');
    await store.flush();
  }
}
