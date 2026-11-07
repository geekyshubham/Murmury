#!/bin/sh
# Creates a local self-signed code-signing identity so rebuilt apps keep their macOS permissions.
# Remove it any time in Keychain Access (login keychain, "Murmury Local Signing").
set -e
DIR=$(mktemp -d); trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Murmury Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -days 3650 -config "$DIR/cfg"
openssl pkcs12 -export -legacy -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "Murmury Local Signing" \
  -out "$DIR/id.p12" -passout pass:murmury 2>/dev/null \
  || openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "Murmury Local Signing" -out "$DIR/id.p12" -passout pass:murmury
security import "$DIR/id.p12" -k ~/Library/Keychains/login.keychain-db -P murmury -T /usr/bin/codesign
