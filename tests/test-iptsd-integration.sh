#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
integration_dir="$repo_dir/userspace/iptsd-sp11"
recipe="$repo_dir/meta-sp11/recipes-support/iptsd-sp11/iptsd-sp11_3.1.0.bb"

# shellcheck disable=SC1091
source "$integration_dir/SOURCE.env"

test "$IPTSD_VERSION" = "3.1.0"
test "$IPTSD_COMMIT" = "a83bc1232f7096f8b33b50fdbda249cd640de670"
test "$IPTSD_TREE" = "06c6e812873e117930eca60b8a32cec40fd13281"

for product in 0c80 0c83; do
  preset="$integration_dir/config/surface-pro-11-$product.conf"
  product_upper="$(printf '%s' "$product" | tr '[:lower:]' '[:upper:]')"
  grep -Fq "Product = 0x$product_upper" "$preset"
  grep -Fq "Disable = true" "$preset"
  grep -Fq "Disable = false" "$preset"
done

render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT

sed \
  -e 's|@IPTSD@|/bin/true|g' \
  -e 's|@CHECKER@|/bin/true|g' \
  -e 's|@SYSTEMCTL@|/bin/systemctl|g' \
  -e 's|@SYSTEMD_ESCAPE@|/bin/systemd-escape|g' \
  "$integration_dir/packaging/sp11-iptsd@.service.in" \
  > "$render_dir/sp11-iptsd@.service"
sed \
  -e 's|@CHECKER@|/bin/true|g' \
  -e 's|@SYSTEMD_ESCAPE@|/bin/systemd-escape|g' \
  "$integration_dir/packaging/70-sp11-iptsd.rules.in" \
  > "$render_dir/70-sp11-iptsd.rules"
sed \
  -e 's|@IPTSD@|/bin/true|g' \
  -e 's|@CHECKER@|/bin/true|g' \
  -e 's|@SYSTEMCTL@|/bin/systemctl|g' \
  -e 's|@SYSTEMD_ESCAPE@|/bin/systemd-escape|g' \
  "$integration_dir/packaging/sp11-iptsd-restart.in" \
  > "$render_dir/sp11-iptsd-restart"

if rg -n '@(IPTSD|CHECKER|SYSTEMCTL|SYSTEMD_ESCAPE)@' "$render_dir"; then
  echo "An integration template placeholder was not rendered." >&2
  exit 1
fi

grep -Fq 'BindsTo=%i.device' "$render_dir/sp11-iptsd@.service"
grep -Fq 'StopWhenUnneeded=yes' "$render_dir/sp11-iptsd@.service"
grep -Fq '001C:045E:0C80.*' "$render_dir/70-sp11-iptsd.rules"
grep -Fq '001C:045E:0C83.*' "$render_dir/70-sp11-iptsd.rules"
grep -Fq 'ENV{SYSTEMD_WANTS}="sp11-iptsd@$result.service"' \
  "$render_dir/70-sp11-iptsd.rules"
grep -Fq '*/001C:045E:0C80.*|*/001C:045E:0C83.*)' \
  "$render_dir/sp11-iptsd-restart"
case '/sys/devices/platform/spi/001C:045E:0C83.0001' in
  */001C:045E:0C80.*|*/001C:045E:0C83.*) ;;
  *) echo "SP11 HID parent path did not match the sleep-hook guard." >&2; exit 1 ;;
esac
sh -n "$render_dir/sp11-iptsd-restart"

grep -Fq "SRCREV = \"$IPTSD_COMMIT\"" "$recipe"
grep -Fq 'RDEPENDS:${PN} += "systemd-extra-utils"' "$recipe"
grep -Fq 'RCONFLICTS:${PN} += "g6-pen iptsd"' "$recipe"
grep -Fq 'file://${UNPACKDIR}/LICENSE.integration' "$recipe"

for script in \
  "$repo_dir/scripts/build-sp11-iptsd-docker.sh" \
  "$repo_dir/scripts/install-sp11-iptsd.sh" \
  "$repo_dir/scripts/validate-sp11-iptsd-payload.sh" \
  "$repo_dir/scripts/install-sp11-support.sh" \
  "$repo_dir/scripts/build-sp11-live-usb-image.sh"; do
  bash -n "$script"
done

payload_explicit="false"
if [ "${SP11_IPTSD_PAYLOAD+x}" = "x" ]; then
  payload_explicit="true"
fi
payload="${SP11_IPTSD_PAYLOAD:-$repo_dir/payload/iptsd-sp11}"
if [ -f "$payload/SHA256SUMS" ]; then
  "$repo_dir/scripts/validate-sp11-iptsd-payload.sh" \
    --payload "$payload" --integration "$integration_dir"
elif [ "$payload_explicit" = "true" ]; then
  echo "Explicit SP11_IPTSD_PAYLOAD is not a complete payload: $payload" >&2
  exit 1
fi

if rg -n '/Users/|/private/tmp/|0x6e.*(payload|capture|identifier)' \
  "$integration_dir" "$recipe"; then
  echo "Public iptsd integration files contain private-path or sideband material." >&2
  exit 1
fi

echo "SP11 iptsd integration checks passed."
