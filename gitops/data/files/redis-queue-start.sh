#!/bin/sh
# AI 작업 큐 Redis 의 ACL 파일을 메모리 볼륨(/run/redis)에 만들고 redis-server 를 띄운다.
# 평문 비밀번호는 파일에 남기지 않고 SHA-256 해시(#...)만 쓴다. 명령은 쓰는 것만 연다(BE #67, AI #52·#53, SPEC #101).
#   default  사용 안 함
#   api      요청 넣기 ai:req:* (XADD, 접수 거절용 XLEN) / 자기 결과 읽고 지우기 ai:res:* (XREAD·XDEL·EXPIRE)
#   ai       요청 꺼내기 ai:req:* (소비자 그룹·회수·XDEL·lag 계산) / 결과 넣기 ai:res:* (XADD) / 중복 실행 막기 ai:run:* (SET NX)
#   exporter 지표 수집(redis-exporter). 키 접근 없음
set -eu
: "${REDIS_API_USER:?}" "${REDIS_API_PASSWORD:?}" "${REDIS_AI_USER:?}" "${REDIS_AI_PASSWORD:?}" \
  "${REDIS_EXPORTER_USER:?}" "${REDIS_EXPORTER_PASSWORD:?}"
umask 077
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
conn='+ping +hello +client|setname +client|setinfo +client|id'
cat > /run/redis/users.acl <<ACL
user default off resetpass resetkeys resetchannels -@all
user ${REDIS_API_USER} on #$(sha "$REDIS_API_PASSWORD") resetkeys ~ai:req:* ~ai:res:* resetchannels -@all ${conn} +xadd +xlen +xread +xdel +expire
user ${REDIS_AI_USER} on #$(sha "$REDIS_AI_PASSWORD") resetkeys ~ai:req:* ~ai:res:* ~ai:run:* resetchannels -@all ${conn} +xreadgroup +xack +xautoclaim +xclaim +xgroup|create +xdel +xlen +xpending +xinfo|groups +xinfo|stream +xadd +set +get +del +expire
user ${REDIS_EXPORTER_USER} on #$(sha "$REDIS_EXPORTER_PASSWORD") resetkeys resetchannels -@all +@connection +ping +info +config|get +slowlog|get +slowlog|len +latency|latest +latency|histogram +client|list +memory|stats
ACL
exec redis-server /etc/redis/redis.conf
