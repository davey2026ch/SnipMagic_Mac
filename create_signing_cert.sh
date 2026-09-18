#!/bin/bash
# 创建代码签名用的固定自签证书（本机执行一次即可，之后一直复用）。
#
# 为什么需要它：
#   截图工具支持自动更新（下载 dmg → 替换 /Applications 里的 .app → 重启）。
#   macOS 的屏幕录制等 TCC 授权是按「代码签名要求（designated requirement）」记的。
#   ad-hoc 签名（codesign --sign -）的 DR 绑在 cdhash 上，每次重新构建都会变，
#   于是每更新一次就要重新授权一次。换成固定证书后
#       DR = identifier X and certificate root = H"<证书指纹>"
#   与文件内容无关，之后每次自动更新权限都保得住。
#
# 踩过的坑（别改）：
#   1. openssl 3.x 默认用 AES-256-CBC 打包 p12，macOS 的 security 工具会报
#      "MAC verification failed during PKCS12 import (wrong password?)" ——
#      看着像密码错，其实是算法不兼容，必须显式指定传统算法三件套：
#          -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
#   2. 证书在钥匙串里会显示为「不受信任」（CSSMERR_TP_NOT_TRUSTED），
#      这是正常的：代码签名不需要它被信任，也不用去改信任设置。
set -euo pipefail

IDENTITY="ScreenshotTool Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_PASS="shotool"
WORK="$(mktemp -d /tmp/st-signing-cert-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# 注意：变量后面紧跟中文/全角字符时必须写成 ${VAR}，否则 bash 会把那个字符
# 的字节当成变量名的一部分，报出莫名其妙的 "IDENTITY?: unbound variable"。
if security find-identity -p codesigning 2>/dev/null | /usr/bin/grep -qF "$IDENTITY"; then
    echo "证书「${IDENTITY}」已存在，无需重复创建："
    security find-identity -p codesigning | /usr/bin/grep -F "$IDENTITY" || true
    exit 0
fi

cd "$WORK"

cat > openssl.cnf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = ScreenshotTool Self-Signed
O = ScreenshotTool
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> 生成自签证书（10 年有效，含 Code Signing 扩展）"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
    -config openssl.cnf 2>/dev/null

echo "==> 打包 p12（必须用传统算法，否则 macOS 导不进去）"
openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem -passout "pass:$P12_PASS" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -name "$IDENTITY"

echo "==> 导入登录钥匙串"
security import cert.p12 -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign -A

echo ""
echo "完成。当前签名身份："
security find-identity -p codesigning | /usr/bin/grep -F "$IDENTITY" || true
echo ""
echo "接下来 ./build_app.sh 会自动用它签名。若要做跨构建比对，可用："
echo "    codesign -dr - /path/to/app    # designated requirement 应只含证书指纹"
