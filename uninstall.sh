#!/usr/bin/env bash
# Removes Chrono: its schedule timers, menu entry, command and files.
# Your schedules stay saved in Lich's data folder (data/chrono), so reinstalling and
# clicking "Rebuild scheduled tasks" brings them back. Lich itself is not touched.

set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

read -r -p "Uninstall Chrono? [y/N] " a || true
case "$a" in [yY]*) ;; *) echo "Nothing changed."; exit 0 ;; esac

RUBY="$(cat "$APP/ruby_path" 2>/dev/null || true)"
if [ -n "$RUBY" ] && [ -x "$RUBY" ] && [ -f "$APP/chrono.rb" ]; then
  if ! "$RUBY" "$APP/chrono.rb" remove-tasks; then
    echo "WARNING: couldn't remove the schedule timers. Remove ~/.config/systemd/user/chrono-* by hand,"
    echo "         then run: systemctl --user daemon-reload"
  fi
else
  echo "WARNING: Lich's Ruby wasn't found, so the schedule timers couldn't be removed."
  echo "         Remove ~/.config/systemd/user/chrono-* by hand, then run: systemctl --user daemon-reload"
fi

rm -f "$DESKTOP_DIR/chrono.desktop"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/chrono.desktop"   # "Open Chrono when I sign in"
if grep -q 'chrono.rb' "$BIN/chrono" 2>/dev/null; then rm -f "$BIN/chrono"; fi
for f in chrono.rb chrono_config.rb chrono_schedule.rb chrono_eaccess.rb chrono_logins.rb chrono_rewards.rb chrono_lich_passwords.rb chrono_github.rb chrono_cronjob.rb chrono_sealedbox.rb chrono_gui.rbw chrono_helper.lic chrono.png \
         README.txt chrono_config.json chrono.log ruby_path uninstall.sh; do
  rm -f "$APP/$f"
done
rmdir "$APP" 2>/dev/null || echo "Left $APP in place because it has other files in it."
echo "Chrono is uninstalled."
echo "Optional: delete scripts/chrono_helper.lic and data/chrono in your Lich folder."
