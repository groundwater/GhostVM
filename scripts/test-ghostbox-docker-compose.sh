#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
COMPOSE=$ROOT/scripts/ghostbox-docker-compose

/usr/bin/ruby -c "$COMPOSE" >/dev/null

help=$($COMPOSE --help)
case "$help" in
    *'Usage: ghostbox-docker-compose'*'up [-d]'*'down'*'logs [-f]'*) ;;
    *)
        printf '%s\n' 'ghostbox-docker-compose help is incomplete' >&2
        exit 1
        ;;
esac

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ghostbox-docker-compose-test.XXXXXX")
test_dir=$(/usr/bin/ruby -e 'puts File.expand_path(ARGV.fetch(0))' "$test_dir")
compose_file=$test_dir/compose.yaml
fake_docker=$test_dir/ghostbox-docker
state_dir=$test_dir/state
invocations=$test_dir/invocations

cleanup() {
    GHOSTBOX_DOCKER="$fake_docker" \
        GHOSTBOX_DOCKER_COMPOSE_STATE="$state_dir" \
        "$COMPOSE" -f "$compose_file" down --timeout 1 >/dev/null 2>&1 || true
    rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

cat >"$test_dir/.env" <<'EOF'
TAG=16
EOF

cat >"$compose_file" <<'EOF'
name: sample
services:
  database:
    image: postgres:${TAG:-latest}
    environment:
      POSTGRES_PASSWORD: secret
    volumes:
      - ./data:/var/lib/postgresql/data
  web:
    image: example/web:latest
    depends_on:
      - database
    command: [serve, --port, "80"]
    environment:
      - MODE=test
    ports:
      - "8080:80"
EOF

cat >"$fake_docker" <<'EOF'
#!/bin/sh
set -eu

record=
for argument in "$@"; do
    record=$record${record:+|}$argument
done
printf '%s\n' "$record" >>"$GHOSTBOX_DOCKER_COMPOSE_TEST_LOG"

if [ "$1" = pull ]; then
    printf 'Pulled %s\n' "$2"
    exit 0
fi

name=
previous=
for argument in "$@"; do
    if [ "$previous" = --name ]; then
        name=$argument
        break
    fi
    previous=$argument
done
printf '%s ready\n' "$name"
trap 'exit 0' HUP INT TERM
while :; do sleep 1; done
EOF
chmod 755 "$fake_docker"

run_compose() {
    GHOSTBOX_DOCKER="$fake_docker" \
        GHOSTBOX_DOCKER_COMPOSE_STATE="$state_dir" \
        GHOSTBOX_DOCKER_COMPOSE_TEST_LOG="$invocations" \
        "$COMPOSE" -f "$compose_file" "$@"
}

resolved=$(run_compose config)
case "$resolved" in
    *'image: postgres:16'*) ;;
    *)
        printf '%s\n' 'Compose interpolation did not resolve .env values' >&2
        exit 1
        ;;
esac
if [ "$(run_compose config --services)" != "$(printf 'database\nweb')" ]; then
    printf '%s\n' 'Compose config did not list services in declaration order' >&2
    exit 1
fi

run_compose pull database >/dev/null
if [ "$(cat "$invocations")" != 'pull|postgres:16' ]; then
    printf '%s\n' 'Compose pull did not call ghostbox-docker correctly' >&2
    exit 1
fi
: >"$invocations"

run_compose up -d web >/dev/null
attempt=0
while [ "$attempt" -lt 50 ]; do
    if [ -f "$state_dir/sample/services/database.json" ] && \
        [ -f "$state_dir/sample/services/web.json" ] && \
        [ "$(wc -l <"$invocations" | tr -d ' ')" -eq 2 ]; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ "$attempt" -eq 50 ]; then
    printf '%s\n' 'Compose services did not start' >&2
    exit 1
fi

expected_database="run|--rm|--name|sample-database-1|--env|POSTGRES_PASSWORD=secret|--volume|$test_dir/data:/var/lib/postgresql/data|postgres:16"
expected_web='run|--rm|--name|sample-web-1|--env|MODE=test|--publish|127.0.0.1:8080:80/tcp|example/web:latest|serve|--port|80'
actual=$(cat "$invocations")
expected=$(printf '%s\n%s' "$expected_database" "$expected_web")
if [ "$actual" != "$expected" ]; then
    printf 'service dependency order or run arguments are incorrect:\n%s\n' "$actual" >&2
    exit 1
fi

status=$(run_compose ps)
case "$status" in *'database'*'running'*'postgres:16'*'web'*'example/web:latest'*) ;; *)
    printf '%s\n' 'Compose ps did not report running services' >&2
    exit 1
esac

attempt=0
while [ "$attempt" -lt 20 ]; do
    logs=$(run_compose logs web)
    case "$logs" in *'web | sample-web-1 ready'*) break ;; esac
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ "$attempt" -eq 20 ]; then
    printf '%s\n' 'Compose logs did not return service output' >&2
    exit 1
fi

database_pid=$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("pid")' \
    "$state_dir/sample/services/database.json")
web_pid=$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("pid")' \
    "$state_dir/sample/services/web.json")
run_compose down --timeout 2 >/dev/null
if [ -e "$state_dir/sample/services" ]; then
    printf '%s\n' 'Compose down did not remove service state' >&2
    exit 1
fi
for pid in "$database_pid" "$web_pid"; do
    if kill -0 "$pid" 2>/dev/null; then
        printf 'Compose down left service runner %s alive\n' "$pid" >&2
        exit 1
    fi
done

printf '%s\n' 'ghostbox-docker-compose tests passed'
