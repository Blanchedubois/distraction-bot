#!/bin/zsh
# A self-signed code-signing identity called "Distraction Bot Dev" in the login keychain.
# With it the app's designated requirement is stable across rebuilds, so macOS
# keeps the Accessibility grant; ad-hoc signatures change every build and lose it.
set -euo pipefail
if security find-identity -v -p codesigning | grep -q '"Distraction Bot Dev"'; then echo "Distraction Bot Dev already exists"; exit 0; fi
T=$(mktemp -d)
cat > "$T/ext.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Distraction Bot Dev
[v3]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$T/key.pem" -out "$T/cert.pem" -config "$T/ext.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -out "$T/dbot.p12" -inkey "$T/key.pem" -in "$T/cert.pem" -passout pass:dbot 2>/dev/null \
  || openssl pkcs12 -export -out "$T/dbot.p12" -inkey "$T/key.pem" -in "$T/cert.pem" -passout pass:dbot
KC="$HOME/Library/Keychains/login.keychain-db"
security import "$T/dbot.p12" -k "$KC" -P dbot -T /usr/bin/codesign -T /usr/bin/security
# trust it for code signing (macOS may ask for your password once)
security add-trusted-cert -p codeSign -k "$KC" "$T/cert.pem" || echo "could not mark trusted automatically; open Keychain Access → Distraction Bot Dev → Trust → Code Signing: Always Trust"
rm -rf "$T"
# let codesign use the key without a dialog on every build (asks for your login password once)
security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KC" >/dev/null || echo "partition list not set; codesign will ask each build — click Always Allow"
security find-identity -v -p codesigning | grep "Distraction Bot Dev" || echo "identity not visible yet; check Keychain Access"
