#!/bin/sh
# Redis ACL 파일을 메모리 볼륨(/run/redis)에 만들고 redis-server 를 띄운다.
# 평문 비밀번호는 파일에 남기지 않고 SHA-256 해시(#...)만 쓴다.
#   default  사용 안 함 (인증 없는 접속 거부)
#   api      BE 세션 저장소. 키는 nerdnam:* 만, 위험 명령(@dangerous)은 빼고 health 용 INFO 만 허용
# 7단계 exporter 사용자는 관측 단계에서 따로 추가한다.
set -eu
: "${REDIS_API_USER:?}" "${REDIS_API_PASSWORD:?}"
umask 077
hash=$(printf '%s' "$REDIS_API_PASSWORD" | sha256sum | cut -d' ' -f1)
cat > /run/redis/users.acl <<EOF
user default off resetpass resetkeys resetchannels -@all
user ${REDIS_API_USER} on #${hash} resetkeys ~nerdnam:* resetchannels -@all +@all -@dangerous +info
EOF
exec redis-server /etc/redis/redis.conf
