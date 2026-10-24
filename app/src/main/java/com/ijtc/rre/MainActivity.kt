package com.ijtc.rre

import android.accounts.AccountManager
import android.app.ActivityManager
import android.app.AlertDialog
import android.graphics.BitmapFactory
import android.app.Activity
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telephony.SubscriptionManager
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.provider.ContactsContract
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : Activity() {
    private lateinit var webView: WebView
    private val allowedHost by lazy { Uri.parse(getString(R.string.app_url)).host }
    private var pendingRequestId: String? = null
    private var pendingFields: Set<String> = emptySet()
    private var fileChooserCallback: ValueCallback<Array<Uri>>? = null

    private companion object {
        const val CONTACT_PERMISSION_REQUEST = 1
        const val CONTACT_PICKER_REQUEST = 2
        const val EMAIL_ACCOUNT_PICKER_REQUEST = 3
        const val SIM_PERMISSION_REQUEST = 4
        const val FILE_CHOOSER_REQUEST = 5
        const val CONTACT_BRIDGE_NAME = "RreContactPicker"
        const val CONTACT_PICKER_POLYFILL = """
            (() => {
              let nextId = 0;
              const pending = new Map();
              window.__rreContactPickerResolve = (id, result) => {
                const callbacks = pending.get(id);
                if (!callbacks) return;
                pending.delete(id);
                try { callbacks.resolve(JSON.parse(result)); }
                catch (error) { callbacks.reject(error); }
              };
              window.__rreContactPickerReject = (id, message) => {
                const callbacks = pending.get(id);
                if (!callbacks) return;
                pending.delete(id);
                callbacks.reject(new DOMException(message, 'NotAllowedError'));
              };
              const contacts = {
                select(fields) {
                  if (!Array.isArray(fields) || fields.length === 0) {
                    return Promise.reject(new TypeError('At least one contact field is required.'));
                  }
                  const id = ++nextId;
                  return new Promise((resolve, reject) => {
                    pending.set(id, { resolve, reject });
                    window.RreContactPicker.pick(String(id), JSON.stringify(fields));
                  });
                }
              };
              try {
                Object.defineProperty(navigator, 'contacts', {
                  configurable: true,
                  value: contacts
                });
              } catch (error) {
                console.error('Could not enable the native contact picker.', error);
              }
            })();
        """
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyRecentsIcon()

        webView = WebView(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.cacheMode = WebSettings.LOAD_DEFAULT
            addJavascriptInterface(ContactPickerBridge(), CONTACT_BRIDGE_NAME)
            webChromeClient = object : WebChromeClient() {
                override fun onShowFileChooser(
                    view: WebView,
                    filePathCallback: ValueCallback<Array<Uri>>,
                    fileChooserParams: FileChooserParams
                ): Boolean {
                    fileChooserCallback?.onReceiveValue(null)
                    fileChooserCallback = filePathCallback
                    val intent = fileChooserParams.createIntent().apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        if (fileChooserParams.mode == FileChooserParams.MODE_OPEN_MULTIPLE) {
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        }
                    }
                    return try {
                        startActivityForResult(
                            Intent.createChooser(intent, fileChooserParams.title ?: "ফাইল নির্বাচন করুন"),
                            FILE_CHOOSER_REQUEST
                        )
                        true
                    } catch (_: Exception) {
                        fileChooserCallback = null
                        filePathCallback.onReceiveValue(null)
                        false
                    }
                }
            }
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String) {
                    super.onPageFinished(view, url)
                    if (Uri.parse(url).host == allowedHost) {
                        view.evaluateJavascript(CONTACT_PICKER_POLYFILL, null)
                    }
                }
            }
        }
        setContentView(webView)

        val restoredPage = savedInstanceState?.let(webView::restoreState)
        if (restoredPage == null) {
            webView.loadUrl(getString(R.string.app_url))
        }
    }

    private fun applyRecentsIcon() {
        val label = getString(R.string.app_name)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            setTaskDescription(
                ActivityManager.TaskDescription.Builder()
                    .setLabel(label)
                    .setIcon(R.drawable.ic_recents_logo)
                    .build()
            )
        } else {
            val icon = BitmapFactory.decodeResource(resources, R.drawable.ic_recents_logo)
            @Suppress("DEPRECATION")
            setTaskDescription(ActivityManager.TaskDescription(label, icon))
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        webView.saveState(outState)
    }

    private inner class ContactPickerBridge {
        @JavascriptInterface
        fun pick(requestId: String, fieldsJson: String) {
            runOnUiThread {
                if (Uri.parse(webView.url).host != allowedHost) {
                    replyPicker(requestId, error = "Contact picker is only available on the app website.")
                    return@runOnUiThread
                }
                if (!requestId.matches(Regex("\\d+"))) {
                    return@runOnUiThread
                }
                if (pendingRequestId != null) {
                    replyPicker(requestId, error = "A contact picker is already open.")
                    return@runOnUiThread
                }

                val requestedFields = try {
                    val fields = JSONArray(fieldsJson)
                    (0 until fields.length())
                        .mapNotNull { fields.optString(it).takeIf(String::isNotBlank) }
                        .toSet()
                } catch (_: Exception) {
                    replyPicker(requestId, error = "Invalid contact fields.")
                    return@runOnUiThread
                }
                val supportedFields = requestedFields.intersect(setOf("name", "tel", "email"))
                if (supportedFields.none { it == "tel" || it == "email" }) {
                    replyPicker(requestId, error = "Select a phone number or email address.")
                    return@runOnUiThread
                }

                pendingRequestId = requestId
                pendingFields = supportedFields
                if (supportedFields == setOf("tel")) {
                    requestSimPickerPermissions()
                } else if ("email" in supportedFields && "tel" !in supportedFields) {
                    launchEmailAccountPicker()
                } else if (checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(
                        arrayOf(Manifest.permission.READ_CONTACTS),
                        CONTACT_PERMISSION_REQUEST
                    )
                } else {
                    launchContactPicker()
                }
            }
        }
    }

    private fun requestSimPickerPermissions() {
        val requiredPermissions = buildList {
            add(Manifest.permission.READ_PHONE_STATE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                add(Manifest.permission.READ_PHONE_NUMBERS)
            }
        }
        val missingPermissions = requiredPermissions.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missingPermissions.isEmpty()) {
            showSimPicker()
        } else {
            requestPermissions(missingPermissions.toTypedArray(), SIM_PERMISSION_REQUEST)
        }
    }

    private fun showSimPicker() {
        try {
            val subscriptions = getSystemService(SubscriptionManager::class.java)
                .activeSubscriptionInfoList
                .orEmpty()
            val availableNumbers = subscriptions.mapNotNull { info ->
                val number = info.number?.trim()?.takeIf(String::isNotEmpty) ?: return@mapNotNull null
                info to number
            }
            if (availableNumbers.isEmpty()) {
                finishPicker(error = "No phone number is available from the SIM. Your carrier may not provide it.")
                return
            }

            val labels = availableNumbers.map { (info, number) ->
                val slot = getString(R.string.sim_slot_label, info.simSlotIndex + 1)
                val carrier = info.carrierName?.toString()?.takeIf(String::isNotBlank)
                listOfNotNull(slot, carrier, number).joinToString(" - ")
            }.toTypedArray()
            AlertDialog.Builder(this)
                .setTitle(R.string.sim_picker_title)
                .setItems(labels) { _, index ->
                    val number = availableNumbers[index].second
                    val selectedNumber = JSONObject().put("tel", JSONArray().put(number))
                    finishPicker(JSONArray().put(selectedNumber).toString())
                }
                .setOnCancelListener { finishPicker(JSONArray().toString()) }
                .show()
        } catch (exception: SecurityException) {
            finishPicker(error = exception.message ?: "SIM phone-number permission was denied.")
        } catch (exception: Exception) {
            finishPicker(error = exception.message ?: "Could not read SIM phone numbers.")
        }
    }

    private fun launchEmailAccountPicker() {
        try {
            val intent = AccountManager.newChooseAccountIntent(
                null,
                null,
                arrayOf("com.google"),
                null,
                null,
                null,
                null
            )
            startActivityForResult(intent, EMAIL_ACCOUNT_PICKER_REQUEST)
        } catch (exception: Exception) {
            finishPicker(error = exception.message ?: "Could not open the Google account picker.")
        }
    }

    private fun launchContactPicker() {
        try {
            startActivityForResult(
                Intent(Intent.ACTION_PICK, ContactsContract.Contacts.CONTENT_URI),
                CONTACT_PICKER_REQUEST
            )
        } catch (exception: Exception) {
            finishPicker(error = exception.message ?: "Could not open the contacts app.")
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == SIM_PERMISSION_REQUEST) {
            if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
                showSimPicker()
            } else {
                finishPicker(error = "SIM permission was denied.")
            }
            return
        }
        if (requestCode != CONTACT_PERMISSION_REQUEST) return

        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            launchContactPicker()
        } else {
            finishPicker(error = "Contacts permission was denied.")
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == FILE_CHOOSER_REQUEST) {
            val callback = fileChooserCallback ?: return
            fileChooserCallback = null
            val clip = data?.clipData
            val uris = if (resultCode == RESULT_OK && clip != null && clip.itemCount > 0) {
                Array(clip.itemCount) { clip.getItemAt(it).uri }
            } else {
                WebChromeClient.FileChooserParams.parseResult(resultCode, data)
            }
            callback.onReceiveValue(uris)
            return
        }
        if (requestCode == EMAIL_ACCOUNT_PICKER_REQUEST) {
            val email = if (resultCode == RESULT_OK) {
                data?.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)
            } else {
                null
            }
            if (email.isNullOrBlank()) {
                finishPicker(JSONArray().toString())
            } else {
                val selectedAccount = JSONObject().put("email", JSONArray().put(email))
                finishPicker(JSONArray().put(selectedAccount).toString())
            }
            return
        }
        if (requestCode != CONTACT_PICKER_REQUEST) return

        val selectedUri = data?.data
        if (resultCode != RESULT_OK || selectedUri == null) {
            finishPicker(JSONArray().toString())
            return
        }

        try {
            finishPicker(readSelectedContact(selectedUri).toString())
        } catch (exception: Exception) {
            finishPicker(error = exception.message ?: "Could not read the selected contact.")
        }
    }

    private fun readSelectedContact(uri: Uri): JSONArray {
        val contact = JSONObject()
        val contactId = queryFirstValue(uri, ContactsContract.Contacts._ID)
            ?: throw IllegalStateException("The selected contact could not be read.")

        if ("name" in pendingFields) {
            val name = queryFirstValue(uri, ContactsContract.Contacts.DISPLAY_NAME)
            contact.put("name", JSONArray().apply { if (!name.isNullOrBlank()) put(name) })
        }
        if ("tel" in pendingFields) {
            contact.put(
                "tel",
                queryContactValues(
                    ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                    ContactsContract.CommonDataKinds.Phone.NUMBER,
                    contactId
                )
            )
        }
        if ("email" in pendingFields) {
            contact.put(
                "email",
                queryContactValues(
                    ContactsContract.CommonDataKinds.Email.CONTENT_URI,
                    ContactsContract.CommonDataKinds.Email.ADDRESS,
                    contactId
                )
            )
        }
        return JSONArray().put(contact)
    }

    private fun queryFirstValue(uri: Uri, column: String): String? =
        contentResolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.getString(cursor.getColumnIndexOrThrow(column))
            } else {
                null
            }
        }

    private fun queryContactValues(uri: Uri, column: String, contactId: String): JSONArray {
        val values = JSONArray()
        contentResolver.query(
            uri,
            arrayOf(column),
            "${ContactsContract.Data.CONTACT_ID} = ?",
            arrayOf(contactId),
            null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                cursor.getString(cursor.getColumnIndexOrThrow(column))
                    ?.takeIf(String::isNotBlank)
                    ?.let(values::put)
            }
        }
        return values
    }

    private fun finishPicker(result: String? = null, error: String? = null) {
        val requestId = pendingRequestId ?: return
        pendingRequestId = null
        pendingFields = emptySet()
        replyPicker(requestId, result, error)
    }

    private fun replyPicker(requestId: String, result: String? = null, error: String? = null) {
        val callback = if (error == null) {
            "window.__rreContactPickerResolve($requestId,${JSONObject.quote(result ?: "[]")})"
        } else {
            "window.__rreContactPickerReject($requestId,${JSONObject.quote(error)})"
        }
        webView.evaluateJavascript(callback, null)
    }

    @Deprecated("Deprecated in Android")
    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
        } else {
            super.onBackPressed()
        }
    }

    override fun onDestroy() {
        if (::webView.isInitialized) {
            webView.stopLoading()
            webView.destroy()
        }
        super.onDestroy()
    }
}
