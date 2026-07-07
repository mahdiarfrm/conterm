#!/usr/bin/env bash
# One-time setup: create a stable self-signed code-signing identity
# ("Conterm Signing") in the login keychain. scripts/build.sh picks it
# up automatically from then on.
#
# Why: an ad-hoc signature gets a fresh cdhash every build, and TCC
# keys folder-access grants to the signature — so every rebuild (and
# for users, every UPDATE) re-prompts for Documents/Desktop/Downloads
# access. A certificate-anchored signature keeps one designated
# requirement forever, so macOS asks once and remembers.
#
# macOS will ask for your login password once when trusting the cert.
set -euo pipefail

NAME="Conterm Signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "OK: '$NAME' already exists — nothing to do"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> generating certificate"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null

# PEM key + cert imported separately — a PKCS12 bundle from OpenSSL 3
# uses a MAC the keychain importer rejects ("MAC verification failed").
echo "==> importing into the login keychain"
security import "$TMP/key.pem" \
    -k ~/Library/Keychains/login.keychain-db \
    -T /usr/bin/codesign
security import "$TMP/cert.pem" \
    -k ~/Library/Keychains/login.keychain-db

echo "==> trusting for code signing (password prompt is expected)"
security add-trusted-cert -p codeSign \
    -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "OK: '$NAME' ready — run scripts/build.sh to sign with it"
else
    echo "WARN: identity not visible yet; open Keychain Access and check" >&2
    echo "      the '$NAME' certificate's trust settings." >&2
    exit 1
fi
