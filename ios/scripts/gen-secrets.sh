#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export PATH="/opt/homebrew/bin:$PATH"

set -a
. ~/.config/op/agent-sa.env
set +a

CLIENT_ID=$(op read "op://Agent/DayDo Cloudflare Access service token/username")
CLIENT_SECRET=$(op read "op://Agent/DayDo Cloudflare Access service token/credential")

if [[ -z "${CLIENT_ID}" || -z "${CLIENT_SECRET}" ]]; then
  echo "empty secret" >&2
  exit 1
fi

umask 077
cat > Secrets.xcconfig <<EOF
DAYDO_ACCESS_CLIENT_ID = ${CLIENT_ID}
DAYDO_ACCESS_CLIENT_SECRET = ${CLIENT_SECRET}
EOF
chmod 600 Secrets.xcconfig
echo "written"
