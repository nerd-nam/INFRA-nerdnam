# 빈 PVC 로 처음 시작할 때만 공식 이미지 entrypoint 가 실행한다 (/docker-entrypoint-initdb.d).
# 이미 데이터가 있으면 실행되지 않으므로 Secret 의 비밀번호를 바꿔도 DB 역할은 그대로다.
#
# 역할 분리
#   postgres          슈퍼유저. 이 스크립트와 운영 작업(확장 업그레이드 등)에만 쓴다
#   nerdnam_migrator  DB 소유자. BE Flyway 가 app/rag 스키마와 테이블을 만든다
#   nerdnam_app       BE 런타임. migrator 가 만든 스키마·테이블에 DML 권한만 받는다
#   nerdnam_exporter  지표 수집(postgres-exporter). pg_monitor 만, 업무 테이블은 읽지 못한다
#
# vector 확장은 trusted 가 아니라 비슈퍼유저가 만들 수 없다. 그래서 여기서 미리 만들고,
# BE V1 migration 의 CREATE EXTENSION IF NOT EXISTS 는 이미 있는 확장을 건너뛴다.
# 실행 비트가 없는 파일이라 entrypoint(bash, set -Eeo pipefail)가 source 한다. 셸 옵션을 바꾸지 않는다.
: "${NERDNAM_DB:?}" "${NERDNAM_MIGRATOR_USER:?}" "${NERDNAM_MIGRATOR_PASSWORD:?}"
: "${NERDNAM_APP_USER:?}" "${NERDNAM_APP_PASSWORD:?}"
: "${NERDNAM_EXPORTER_USER:?}" "${NERDNAM_EXPORTER_PASSWORD:?}"

# 비밀번호는 명령줄 인자로 넘기지 않고 psql 이 환경 변수에서 읽는다(\getenv).
psql -v ON_ERROR_STOP=1 --no-psqlrc --username "$POSTGRES_USER" --dbname postgres <<'SQL'
\getenv db NERDNAM_DB
\getenv migrator NERDNAM_MIGRATOR_USER
\getenv migrator_password NERDNAM_MIGRATOR_PASSWORD
\getenv app NERDNAM_APP_USER
\getenv app_password NERDNAM_APP_PASSWORD
\getenv exporter NERDNAM_EXPORTER_USER
\getenv exporter_password NERDNAM_EXPORTER_PASSWORD

CREATE ROLE :"migrator" LOGIN PASSWORD :'migrator_password';
CREATE ROLE :"app" LOGIN PASSWORD :'app_password';
CREATE ROLE :"exporter" LOGIN PASSWORD :'exporter_password' CONNECTION LIMIT 3;
GRANT pg_monitor TO :"exporter";
CREATE DATABASE :"db" OWNER :"migrator";
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO :"app";
GRANT CONNECT ON DATABASE :"db" TO :"exporter";

\connect :"db"
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

-- Flyway(migrator)가 앞으로 만드는 스키마·테이블·시퀀스에 런타임 권한을 자동으로 준다.
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator" GRANT USAGE ON SCHEMAS TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator" GRANT USAGE, SELECT ON SEQUENCES TO :"app";
SQL
