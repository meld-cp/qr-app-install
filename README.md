# QR App Installer

Scan a QR code of a URL to an APK to download and install it.

## Getting Started
- TODO

## Dev Notes

### How to generate signing key
`keytool -genkey -v -keystore qr_app_install_upload.jks -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias qr_app_install_upload`