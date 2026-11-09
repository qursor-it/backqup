#!/bin/sh
# End-to-end test: dump -> age encrypt (public key only) -> S3 -> decrypt -> restore -> compare.
# Needs only Docker. Usage: sh tests/e2e/run.sh
set -eu

cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1 # Git Bash on Windows must not rewrite /paths passed to docker
export BACKQUP_IMAGE="${BACKQUP_IMAGE:-backqup:dev}"
mkdir -p .work

DC="docker compose"
step() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
bq() { $DC exec -T "$@"; } # bq [-e VAR=val] <service> <cmd...>
aws() { $DC run --rm -T aws "$1"; } # aws "<shell command>"
S3="aws --endpoint-url http://s3:8333"

cleanup() {
  code=$?
  $DC exec -T backqup sh -c 'rm -rf /work/*' >/dev/null 2>&1 || true # files are root-owned
  $DC down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf .work
  if [ "$code" -eq 0 ]; then echo "E2E PASSED"; else echo "E2E FAILED (exit $code)" >&2; fi
}
trap cleanup EXIT

wait_for() { # wait_for <description> <cmd...>
  desc=$1; shift
  i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -le 60 ] || fail "timeout waiting for $desc"
    sleep 2
  done
}

if ! docker image inspect "$BACKQUP_IMAGE" >/dev/null 2>&1; then
  step "building $BACKQUP_IMAGE"
  docker build -t "$BACKQUP_IMAGE" ../..
fi

step "starting stack"
$DC up -d pg maria pg-restore maria-restore s3 backqup
wait_for postgres bq pg pg_isready -U postgres -d appdb
wait_for pg-restore bq pg-restore pg_isready -U postgres -d appdb
wait_for mariadb bq maria mariadb -uroot -pmariapass appdb -e 'select 1'
wait_for maria-restore bq maria-restore mariadb -uroot -pmariapass appdb -e 'select 1'
wait_for s3 aws "$S3 s3 ls"
aws "$S3 s3 mb s3://backups"

step "generating throwaway age keys (private keys stay in .work, never given to gobackup)"
bq backqup sh -c 'age-keygen -o /work/key.txt 2>/dev/null; age-keygen -o /work/wrong.txt 2>/dev/null'
RECIPIENT=$(bq backqup age-keygen -y /work/key.txt | tr -d '\r')
case "$RECIPIENT" in age1*) ;; *) fail "no public key: $RECIPIENT" ;; esac

for m in pg maria; do
  step "gobackup perform $m"
  bq -e AGE_RECIPIENT="$RECIPIENT" backqup gobackup perform -c /etc/gobackup/gobackup.yml --model "$m"
done

step "downloading objects from the S3 store"
aws "$S3 s3 cp --recursive s3://backups/ /work/dl/ >/dev/null"
for m in pg maria; do
  n=$(bq backqup sh -c "ls /work/dl/$m/*.tar.age 2>/dev/null | wc -l" | tr -d '\r')
  [ "$n" = 1 ] || fail "expected exactly one /work/dl/$m/*.tar.age object, found $n"
done

for m in pg maria; do
  step "$m: object is encrypted and only the private key opens it"
  bq backqup sh -c "
    set -e
    f=\$(ls /work/dl/$m/*.tar.age)
    head -c 21 \"\$f\" | grep -q '^age-encryption.org/v1' || { echo 'missing age header'; exit 1; }
    if tar -tf \"\$f\" >/dev/null 2>&1; then echo 'object is readable as tar without decrypting'; exit 1; fi
    if age -d -i /work/wrong.txt -o /dev/null \"\$f\" 2>/dev/null; then echo 'decrypted with the WRONG key'; exit 1; fi
    mkdir -p /work/out/$m
    age -d -i /work/key.txt -o /work/out/$m.tar \"\$f\"
    tar -xf /work/out/$m.tar -C /work/out/$m
    find /work/out/$m -type f
  " || fail "$m: encryption checks"
done

step "restoring into fresh servers"
bq -e PGPASSWORD=pgpass backqup sh -c '
  set -e
  f=$(find /work/out/pg -type f -name "appdb*")
  pg_restore --list "$f" >/dev/null
  pg_restore -h pg-restore -U postgres -d appdb --no-owner "$f"
' || fail "pg restore"
bq backqup sh -c '
  set -e
  f=$(find /work/out/maria -type f -name "appdb*.sql")
  mariadb -h maria-restore -uroot -pmariapass appdb < "$f"
' || fail "maria restore"

step "comparing content with the seed"
PGQ="select count(*) || chr(32) || md5(string_agg(name, chr(44) order by id)) from items"
MQ='select concat(count(*), " ", md5(group_concat(name order by id separator ","))) from items'
src=$(bq -e PGPASSWORD=pgpass backqup psql -h pg -U postgres -d appdb -Atc "$PGQ" | tr -d '\r')
dst=$(bq -e PGPASSWORD=pgpass backqup psql -h pg-restore -U postgres -d appdb -Atc "$PGQ" | tr -d '\r')
echo "postgres: source=[$src] restored=[$dst]"
[ -n "$src" ] && [ "$src" = "$dst" ] || fail "postgres content differs"
case "$src" in 200\ *) ;; *) fail "unexpected postgres seed: $src" ;; esac

src=$(bq backqup mariadb -h maria -uroot -pmariapass appdb -N -e "$MQ" | tr -d '\r')
dst=$(bq backqup mariadb -h maria-restore -uroot -pmariapass appdb -N -e "$MQ" | tr -d '\r')
echo "mariadb: source=[$src] restored=[$dst]"
[ -n "$src" ] && [ "$src" = "$dst" ] || fail "mariadb content differs"
case "$src" in 200\ *) ;; *) fail "unexpected mariadb seed: $src" ;; esac
