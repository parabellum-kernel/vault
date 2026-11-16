# Privacy Policy — Vault

**Last updated:** 2026-11-16

## 1. Overview
**Vault** is a local-first, client-side encrypted virtual filesystem application. All encryption, decryption, and metadata management happen locally on your device.

## 2. Google User Data Accessed
When you connect a Google account via OAuth2, Vault requests access to the Google Drive API (`https://www.googleapis.com/auth/drive`) solely to:
- Read storage quota information (`drive.about.get`).
- Upload, update, download (including byte-range reads), list, and delete encrypted blob files and the encrypted VFS catalog stored in your Google Drive.

## 3. Zero-Knowledge Encryption & Local Storage
- Files and directory metadata are encrypted on your device before being uploaded to Google Drive.
- OAuth2 tokens (`refresh_token` / `access_token`) and device keys are stored locally on your machine.
- Vault **does not** operate any central backend server, telemetry collection, analytics, or third-party data sharing. Your credentials and data never leave your device except for direct TLS communication with Google APIs.

## 4. Data Retention & Revocation
- You may revoke Vault's access to your Google account at any time from your Google Account security settings (<https://myaccount.google.com/permissions>).
- Deleting local configuration/database files removes all cached metadata and tokens from your device.
