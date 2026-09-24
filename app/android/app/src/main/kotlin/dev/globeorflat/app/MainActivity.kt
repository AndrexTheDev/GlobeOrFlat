// ============================================================================
// GlobeOrFlat — Android Keystore bridge (MethodChannel: "globeorflat/keystore")
// SPDX-License-Identifier: MIT
//
// Requires minSdkVersion 23 (EC P-256 in the hardware-backed Keystore with
// SHA-256 digests). The key is non-exportable: only signature operations are
// possible on-device, which is exactly what the append-only backend needs.
//
// Methods:
//   ensureKeyPair()            -> base64 DER SPKI public key (creates if absent)
//   getPublicKeySpkiBase64()   -> base64 DER SPKI public key or null
//   sign(message: String)      -> base64 DER ECDSA signature (SHA256withECDSA)
//   deleteKey()                -> removes the key pair
// ============================================================================

package dev.globeorflat.app

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPair
import java.security.KeyStore
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import android.util.Base64

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "globeorflat/keystore"
        private const val KEY_ALIAS = "gof_device_key"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "ensureKeyPair" -> result.success(getOrCreateKeyPairSpkiBase64())
                        "getPublicKeySpkiBase64" -> result.success(existingSpkiBase64())
                        "sign" -> {
                            val message: String? = call.argument("message")
                            if (message == null) {
                                result.error("INVALID_ARGS", "message is required", null)
                            } else {
                                result.success(signBase64Der(message.toByteArray(Charsets.UTF_8)))
                            }
                        }
                        "deleteKey" -> {
                            val ks = keystore()
                            if (ks.containsAlias(KEY_ALIAS)) ks.deleteEntry(KEY_ALIAS)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("KEYSTORE_ERROR", e.message, null)
                }
            }
    }

    private fun keystore(): KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    /** Returns the SPKI (X.509 SubjectPublicKeyInfo) DER of the public key, base64. */
    private fun getOrCreateKeyPairSpkiBase64(): String {
        val ks = keystore()
        if (!ks.containsAlias(KEY_ALIAS)) {
            val generator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE
            )
            val spec = KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                // No user-auth gate: calibration and uploads must work offline
                // and without unlock ceremonies.
                .setUserAuthenticationRequired(false)
                .build()
            generator.initialize(spec)
            generator.generateKeyPair()
        }
        val cert = ks.getCertificate(KEY_ALIAS)
            ?: throw IllegalStateException("Keystore key vanished right after creation")
        return Base64.encodeToString(cert.publicKey.encoded, Base64.NO_WRAP)
    }

    private fun existingSpkiBase64(): String? {
        val ks = keystore()
        if (!ks.containsAlias(KEY_ALIAS)) return null
        val cert = ks.getCertificate(KEY_ALIAS) ?: return null
        return Base64.encodeToString(cert.publicKey.encoded, Base64.NO_WRAP)
    }

    /** SHA256withECDSA — produces the ASN.1 DER signature the backend expects. */
    private fun signBase64Der(messageBytes: ByteArray): String {
        val ks = keystore()
        if (!ks.containsAlias(KEY_ALIAS)) {
            throw IllegalStateException("Device key not initialised — call ensureKeyPair first")
        }
        val entry = ks.getEntry(KEY_ALIAS, null) as KeyStore.PrivateKeyEntry
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(entry.privateKey)
        signer.update(messageBytes)
        return Base64.encodeToString(signer.sign(), Base64.NO_WRAP)
    }
}
