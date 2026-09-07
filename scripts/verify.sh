#!/bin/sh
# Health check. Runs from anywhere with network access to the phone:
#   HOST=192.168.1.79 sh scripts/verify.sh
set -eu
HOST=${HOST:-192.168.1.79}
fail=0

check() {
	name=$1; url=$2; want=$3
	code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url" || echo 000)
	if [ "$code" = "$want" ]; then
		printf '  ok    %-16s %s\n' "$name" "$url"
	else
		printf '  FAIL  %-16s %s (http %s, want %s)\n' "$name" "$url" "$code" "$want"
		fail=1
	fi
}

echo "endpoints:"
check victoriametrics "http://$HOST:8428/api/v1/query?query=up" 200
check vmalert         "http://$HOST:8880/api/v1/rules"          200
check alertmanager    "http://$HOST:9093/-/ready"               200
check grafana         "http://$HOST:3000/api/health"            200
check node-exporter   "http://$HOST:9100/metrics"               200

echo "scrape targets:"
curl -s -m 10 -G "http://$HOST:8428/api/v1/query" --data-urlencode 'query=up' \
	| tr '}' '\n' | sed -n 's/.*"job":"\([^"]*\)".*/\1/p' | sort -u \
	| while read -r job; do
		v=$(curl -s -m 10 -G "http://$HOST:8428/api/v1/query" \
			--data-urlencode "query=up{job=\"$job\"}" \
			| sed -n 's/.*"value":\[[0-9.]*,"\([0-9]*\)"\].*/\1/p')
		[ "$v" = 1 ] && printf '  ok    %s\n' "$job" || printf '  FAIL  %s (up=%s)\n' "$job" "$v"
	done

echo "alert rules:"
curl -s -m 10 "http://$HOST:8880/api/v1/rules" \
	| tr ',' '\n' | grep -c '"name"' >/dev/null 2>&1 || true
groups=$(curl -s -m 10 "http://$HOST:8880/api/v1/rules" | grep -o '"name":"[a-z-]*"' | sort -u | head -10)
echo "$groups" | sed 's/"name":/  group /;s/"//g'

echo "battery:"
curl -s -m 10 -G "http://$HOST:8428/api/v1/query" \
	--data-urlencode 'query=node_power_supply_capacity{power_supply="qcom_qg"}' \
	| sed -n 's/.*"value":\[[0-9.]*,"\([0-9]*\)"\].*/  capacity \1%/p'
echo

exit $fail
