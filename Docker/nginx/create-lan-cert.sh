#!/bin/sh
set -eu

ip=${1:?Usage: sh Docker/nginx/create-lan-cert.sh SERVER_IP}
tls_dir=${TLS_DIR:-tls}
umask 077

case "$ip" in
    *[!0-9a-fA-F.:]*) echo 'Expected an IPv4 or IPv6 address.' >&2; exit 1 ;;
esac

mkdir -p "$tls_dir/nginx"
if [ ! -e "$tls_dir/ca.key" ] && [ ! -e "$tls_dir/ca.crt" ]; then
    openssl req -x509 -newkey rsa:3072 -noenc -days 1825 \
        -subj '/CN=Lab Platform Local CA' \
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -addext 'subjectKeyIdentifier=hash' \
        -keyout "$tls_dir/ca.key" -out "$tls_dir/ca.crt"
fi

work_dir=$(mktemp -d "$tls_dir/.cert.XXXXXX")
trap 'rm -f "$work_dir/server.key" "$work_dir/server.csr" "$work_dir/server.crt" "$work_dir/server.ext"; rmdir "$work_dir"' EXIT

openssl req -new -newkey rsa:2048 -noenc -subj "/CN=$ip" \
    -keyout "$work_dir/server.key" -out "$work_dir/server.csr"
cat > "$work_dir/server.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:$ip
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
openssl x509 -req -days 365 -sha256 -in "$work_dir/server.csr" \
    -CA "$tls_dir/ca.crt" -CAkey "$tls_dir/ca.key" \
    -extfile "$work_dir/server.ext" -out "$work_dir/server.crt"
openssl verify -purpose sslserver -verify_ip "$ip" \
    -CAfile "$tls_dir/ca.crt" "$work_dir/server.crt"
mv "$work_dir/server.key" "$work_dir/server.crt" "$tls_dir/nginx/"
printf 'CA certificate: %s/ca.crt\n' "$tls_dir"
