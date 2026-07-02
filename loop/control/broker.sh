#!/usr/bin/env bash
# Secret broker (credential-injecting reverse proxy). Lets the worker Claude USE dev APIs without
# ever READING their tokens: the broker HOLDS the credentials and injects them into outbound
# requests. Workers call $BROKER_URL/<alias>/<path...> with no credential of their own.
#
#   ./control/broker.sh up        # (re)start the broker from control/secret.broker.env
#   ./control/broker.sh status
#   ./control/broker.sh down
#
# Configure aliases in control/secret.broker.env (gitignored), one per line:
#   <alias> = <upstream-base-url> | <Header-Name: secret value>
# e.g.
#   github = https://api.github.com | Authorization: Bearer ghp_xxx
#   stripe = https://api.stripe.com | Authorization: Bearer sk_test_xxx
#
# The raw secret lives ONLY in the broker container (host-trusted, like the worker key — D12).
# Workers never receive secret.broker.env; they only get BROKER_URL (set by spawn.sh).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

CMD="${1:-up}"
SECRETS="$CONFIG_DIR/secret.broker.env"
BR="$(brokername)"

reap_broker() {
  docker rm -f "$BR" >/dev/null 2>&1 || true
}

case "$CMD" in
  down)
    reap_broker; echo "broker: down."; exit 0 ;;
  status)
    if container_running broker 2>/dev/null || docker ps --format '{{.Names}}' | grep -qx "$BR"; then
      echo "broker: running at http://$BR:$BROKER_PORT (aliases below)"
      docker logs "$BR" 2>&1 | tail -1
    else echo "broker: not running."; fi
    exit 0 ;;
  up) : ;;
  *) die "usage: broker.sh up|down|status" ;;
esac

[ -f "$SECRETS" ] || die "no $SECRETS — copy secret.broker.env.example there and add your dev API credentials."

# Build BROKER_ROUTES JSON from secret.broker.env. (jq assembles it so values are escaped safely.)
routes='{}'
while IFS= read -r line; do
  line="${line%%$'\r'}"
  case "$line" in ''|'#'*) continue ;; esac
  [ "${line#*=}" != "$line" ] || continue
  alias="$(printf '%s' "${line%%=*}" | xargs)"            # trim
  rhs="${line#*=}"
  upstream="$(printf '%s' "${rhs%%|*}" | xargs)"
  header="$(printf '%s' "${rhs#*|}" | sed -e 's/^ *//' -e 's/ *$//')"
  [ -n "$alias" ] && [ -n "$upstream" ] || continue
  routes="$(jq -c --arg a "$alias" --arg u "$upstream" --arg h "$header" \
            '. + {($a): {upstream:$u, header:$h}}' <<<"$routes")"
done < "$SECRETS"

[ "$routes" != '{}' ] || die "no usable aliases parsed from $SECRETS"

ensure_worker_network
reap_broker

# In broker-only egress mode the broker bridges the internal worker net to the internet, so it
# also joins a normal (NAT) network for its own outbound calls.
docker run -d --name "$BR" --network "$(netname)" \
  --entrypoint node \
  -e BROKER_ROUTES="$routes" -e BROKER_PORT="$BROKER_PORT" \
  -v "$CONTROL_DIR/broker/broker.js":/broker.js:ro \
  "$IMAGE" /broker.js >/dev/null

if [ "${WORKER_EGRESS:-open}" = "broker-only" ]; then
  net_exists "$(extnetname)" || docker network create "$(extnetname)" >/dev/null
  docker network connect "$(extnetname)" "$BR" 2>/dev/null || true
fi

echo "broker: up at http://$BR:$BROKER_PORT  (workers reach it via \$BROKER_URL)"
echo "broker: aliases -> $(jq -r 'keys|join(", ")' <<<"$routes")"
echo "broker: egress mode = ${WORKER_EGRESS}. Workers call \$BROKER_URL/<alias>/<path>; tokens never reach them."
progress_log BROKER_UP "-" "-" "aliases: $(jq -r 'keys|join(",")' <<<"$routes")"
