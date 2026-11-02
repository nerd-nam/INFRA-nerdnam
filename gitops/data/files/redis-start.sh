#!/bin/sh
# Redis ACL 파일을 메모리 볼륨(/run/redis)에 만들고 redis-server 를 띄운다.
# 평문 비밀번호는 파일에 남기지 않고 SHA-256 해시(#...)만 쓴다.
#   default  사용 안 함 (인증 없는 접속 거부)
#   api      BE 세션 저장소. 키는 nerdnam:* 만, 위험 명령(@dangerous)은 빼고 health 용 INFO 만 허용
#   exporter 지표 수집(redis-exporter). 키 접근 없음, 상태 조회 명령만
set -eu
: "${REDIS_API_USER:?}" "${REDIS_API_PASSWORD:?}" "${REDIS_EXPORTER_USER:?}" "${REDIS_EXPORTER_PASSWORD:?}"
umask 077
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
cat > /run/redis/users.acl <<EOF
user default off resetpass resetkeys resetchannels -@all
user ${REDIS_API_USER} on #$(sha "$REDIS_API_PASSWORD") resetkeys ~nerdnam:* resetchannels -@all +@all -@dangerous +info
user ${REDIS_EXPORTER_USER} on #$(sha "$REDIS_EXPORTER_PASSWORD") resetkeys resetchannels -@all +@connection +ping +info +config|get +slowlog|get +slowlog|len +latency|latest +latency|histogram +client|list +memory|stats
EOF
exec redis-server /etc/redis/redis.conf
