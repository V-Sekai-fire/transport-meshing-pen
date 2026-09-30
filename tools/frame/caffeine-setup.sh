#!/bin/bash
# Install a toggleable, no-root sleep inhibitor on the headset: a systemd --user
# service holding a block inhibitor on sleep+idle, plus a caffeine on|off|status
# wrapper. Not enabled at boot -- it is a toggle.
set -e
mkdir -p ~/.config/systemd/user ~/rfd2287

cat > ~/.config/systemd/user/frame-caffeine.service <<'UNIT'
[Unit]
Description=Keep the headset awake (block sleep+idle) for rfd2287 work

[Service]
ExecStart=/usr/bin/systemd-inhibit --what=sleep:idle --who=rfd2287 --why=companion-pen-work --mode=block sleep infinity
Restart=on-failure

[Install]
WantedBy=default.target
UNIT

cat > ~/rfd2287/caffeine.sh <<'WRAP'
#!/bin/bash
# caffeine on|off|status -- toggle the headset's block sleep inhibitor.
case "${1:-status}" in
  on)  systemctl --user start frame-caffeine; sleep 1; echo "caffeine ON ($(systemctl --user is-active frame-caffeine))";;
  off) systemctl --user stop frame-caffeine; echo "caffeine OFF ($(systemctl --user is-active frame-caffeine))";;
  status) echo "service: $(systemctl --user is-active frame-caffeine)"; systemd-inhibit --list 2>/dev/null | grep -i rfd2287 || echo "no rfd2287 inhibitor held";;
  *) echo "usage: caffeine.sh on|off|status";;
esac
WRAP
chmod +x ~/rfd2287/caffeine.sh

systemctl --user daemon-reload
~/rfd2287/caffeine.sh on
echo "--- verify inhibitor held:"
systemd-inhibit --list 2>/dev/null | grep -i rfd2287 || echo "WARN: no rfd2287 inhibitor"
