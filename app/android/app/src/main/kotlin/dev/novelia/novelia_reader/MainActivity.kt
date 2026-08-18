package dev.novelia.novelia_reader

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private val accountKeyAlias = "dev.novelia.reader.account.v1"
    private val accountPreferences = "novelia_encrypted_account"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.novelia/external_links",
        ).setMethodCallHandler { call, result ->
            if (call.method != "open") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val rawUrl = call.arguments as? String
            val uri = rawUrl?.let(Uri::parse)
            if (uri == null || (uri.scheme != "https" && uri.scheme != "http")) {
                result.error("INVALID_URL", "Only HTTP(S) links are allowed.", null)
                return@setMethodCallHandler
            }
            try {
                startActivity(Intent(Intent.ACTION_VIEW, uri))
                result.success(true)
            } catch (_: ActivityNotFoundException) {
                result.success(false)
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.novelia/account_session",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "read" -> result.success(readAccountSession())
                    "write" -> {
                        val value = call.arguments as? String
                        if (value == null) {
                            result.error("INVALID_VALUE", "Session must be text.", null)
                        } else {
                            writeAccountSession(value)
                            result.success(null)
                        }
                    }
                    "clear" -> {
                        clearAccountSession()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error(
                    "SECURE_STORAGE",
                    "The encrypted account session could not be accessed.",
                    null,
                )
            }
        }
    }

    private fun accountKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(accountKeyAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                accountKeyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun writeAccountSession(value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, accountKey())
        val encrypted = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        val committed = getSharedPreferences(accountPreferences, Context.MODE_PRIVATE)
            .edit()
            .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .commit()
        check(committed) { "Encrypted session was not committed." }
    }

    private fun readAccountSession(): String? {
        val preferences = getSharedPreferences(accountPreferences, Context.MODE_PRIVATE)
        val encodedIv = preferences.getString("iv", null)
        val encodedCiphertext = preferences.getString("ciphertext", null)
        if (encodedIv == null && encodedCiphertext == null) return null
        check(encodedIv != null && encodedCiphertext != null) {
            "Encrypted session is incomplete."
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            accountKey(),
            GCMParameterSpec(128, Base64.decode(encodedIv, Base64.NO_WRAP)),
        )
        val cleartext = cipher.doFinal(Base64.decode(encodedCiphertext, Base64.NO_WRAP))
        return String(cleartext, StandardCharsets.UTF_8)
    }

    private fun clearAccountSession() {
        val committed = getSharedPreferences(accountPreferences, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
        check(committed) { "Encrypted session was not cleared." }
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(accountKeyAlias)) keyStore.deleteEntry(accountKeyAlias)
    }
}
