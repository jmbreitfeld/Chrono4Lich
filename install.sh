#!/usr/bin/env bash
# Chrono installer for Linux. Run from the unpacked Chrono4Lich folder:
#   ./install.sh            (asks before using the Ruby it finds)
#   ./install.sh --ruby /path/to/ruby --yes
#
# Installs for your user only (no sudo) into ~/.local/share/Chrono4Lich, adds a menu
# entry and a "chrono" command. Run it again to upgrade; your settings are kept.
# If lichsched (Chrono's old name) is installed, it's replaced and its schedules carried over.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APP="$DATA_HOME/Chrono4Lich"
OLD_APP="$DATA_HOME/lichsched"
BIN="$HOME/.local/bin"
DESKTOP_DIR="$DATA_HOME/applications"
FILES=(chrono.rb chrono_config.rb chrono_schedule.rb chrono_eaccess.rb chrono_logins.rb chrono_rewards.rb chrono_lich_passwords.rb chrono_github.rb chrono_cronjob.rb chrono_sealedbox.rb chrono_gui.rbw chrono_helper.lic chrono.png README.txt uninstall.sh)

RUBY=""
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ruby) RUBY="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
fail() { printf '\nERROR: %s\n\nSetup did not finish.\n' "$*" >&2; exit 1; }
ask()  { # ask "question" -> 0 for yes (default), 1 for no
  [ "$ASSUME_YES" = 1 ] && return 0
  local a; read -r -p "$1 [Y/n] " a || true
  case "$a" in [nN]*) return 1 ;; *) return 0 ;; esac
}

say ""
say " Chrono setup"
say " ============"
say ""

for f in "${FILES[@]}"; do
  [ -f "$SRC/$f" ] || fail "$f is missing. Unpack the whole Chrono4Lich folder, then run install.sh from inside it."
done

# ---- find the Ruby that runs Lich ----
# Turn whatever we're given (a shim, a symlink) into the real ruby binary, since the
# menu entry and the timers run without your shell's PATH.
resolve_ruby() { "$1" -e 'print RbConfig.ruby' 2>/dev/null; }

if [ -z "$RUBY" ] && [ -f "$APP/ruby_path" ]; then
  prev="$(cat "$APP/ruby_path")"
  [ -x "$prev" ] && RUBY="$prev" && say " Using the same Ruby as last time: $RUBY"
fi
if [ -z "$RUBY" ]; then
  for c in "$(command -v ruby 2>/dev/null || true)" \
           $(ls -d "$HOME"/.rbenv/versions/*/bin/ruby 2>/dev/null | sort -V | tail -n 1) \
           $(ls -d "$HOME"/.asdf/installs/ruby/*/bin/ruby 2>/dev/null | sort -V | tail -n 1) \
           /usr/local/bin/ruby /usr/bin/ruby; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    real="$(resolve_ruby "$c" || true)"
    [ -n "$real" ] || continue
    say " Found Ruby: $real ($("$real" -e 'print RUBY_VERSION'))"
    if ask " Use this Ruby? This should be the one you run Lich with."; then RUBY="$real"; fi
    break
  done
fi
while [ -z "$RUBY" ]; do
  [ "$ASSUME_YES" = 1 ] && fail "No Ruby found. Run again with --ruby /path/to/ruby."
  read -r -p " Full path to the ruby you run Lich with: " RUBY || fail "No Ruby given."
done
REAL="$(resolve_ruby "$RUBY" || true)"
[ -n "$REAL" ] || fail "\"$RUBY\" isn't a working Ruby."
RUBY="$REAL"

say " Checking that this Ruby has GTK, which the window needs..."
if ! "$RUBY" -e "require 'gtk3'" >/dev/null 2>&1; then
  fail "This Ruby can't load GTK3 ($RUBY).
Lich's own windows need it too, so install it the way Lich's Linux instructions say,
usually:   $("$RUBY" -e 'print File.join(RbConfig::CONFIG["bindir"], "gem")') install gtk3
(on Pop!_OS / Ubuntu you may first need:  sudo apt install build-essential libgtk-3-dev)"
fi
say " OK."

# ---- things schedules need (warnings only; manual logins work without them) ----
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
  say " WARNING: systemd user services aren't available here, so schedules won't work."
  say "          Logging in and out from the window still works."
fi
if ! command -v notify-send >/dev/null 2>&1 && ! command -v zenity >/dev/null 2>&1; then
  say " WARNING: notify-send isn't installed, so a failed scheduled login can't pop up a"
  say "          notification. Install it with:  sudo apt install libnotify-bin"
fi

mkdir -p "$APP" "$BIN" "$DESKTOP_DIR"

# ---- replace lichsched, Chrono's old name ----
if [ -d "$OLD_APP" ]; then
  say " Replacing lichsched (Chrono's old name) with Chrono..."
  # keep the Lich folder it had saved
  if [ -f "$OLD_APP/lichsched_config.json" ] && [ ! -f "$APP/chrono_config.json" ]; then
    cp "$OLD_APP/lichsched_config.json" "$APP/chrono_config.json"
  fi
  if [ -x "$OLD_APP/uninstall.sh" ]; then
    # removes its timers, menu entry, command and files; its schedules stay in Lich's data folder
    printf 'y\n' | "$OLD_APP/uninstall.sh" >/dev/null 2>&1 || \
      say " WARNING: lichsched's uninstaller reported a problem; Chrono will remove what's left."
  fi
  rm -f "$DESKTOP_DIR/lichsched.desktop"
  if grep -q 'lichsched.rb' "$BIN/lichsched" 2>/dev/null; then rm -f "$BIN/lichsched"; fi
fi

# ---- copy files (chrono_config.json, your saved Lich folder, is kept) ----
for f in "${FILES[@]}"; do install -m 644 "$SRC/$f" "$APP/$f"; done
chmod 755 "$APP/uninstall.sh"
printf '%s\n' "$RUBY" > "$APP/ruby_path"

# ---- "chrono" command ----
cat > "$BIN/chrono" <<EOF
#!/bin/sh
# Made by the Chrono installer. Runs chrono.rb with the Ruby that runs Lich.
exec "$RUBY" "$APP/chrono.rb" "\$@"
EOF
chmod 755 "$BIN/chrono"

# ---- menu entry (named chrono.desktop so the dock matches it to the window) ----
cat > "$DESKTOP_DIR/chrono.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Chrono
GenericName=Lich login scheduler
Comment=Log GemStone IV characters in and out through Lich5, by hand or on a schedule
Exec="$RUBY" "$APP/chrono_gui.rbw"
Path=$APP
Icon=$APP/chrono.png
StartupWMClass=chrono
Terminal=false
Categories=Game;Utility;
EOF
chmod 644 "$DESKTOP_DIR/chrono.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true

# ---- point schedules at the new files and Ruby (this also carries over lichsched's) ----
rc=0
"$RUBY" "$APP/chrono.rb" rebuild-tasks >"$APP/.rebuild-output" 2>&1 || rc=$?
if [ "$rc" = 3 ]; then
  say " NOTE: some characters are still online from lichsched. Type QUIT in the game for"
  say "       each one, then open Chrono; your old schedules are brought over then."
elif [ "$rc" != 0 ]; then
  say " WARNING: updating your schedules failed:"
  sed 's/^/          /' "$APP/.rebuild-output"
  say "          Open Chrono and click \"Rebuild scheduled tasks\" on the Settings tab."
fi
rm -f "$APP/.rebuild-output"

say ""
say " Done."
say "  - \"Chrono\" is in your applications menu."
case ":$PATH:" in
  *":$BIN:"*) say "  - The \"chrono\" command works in a terminal." ;;
  *) say "  - The command-line version is $BIN/chrono ($BIN isn't on your PATH yet)." ;;
esac
say "  - The first time it opens, it finds your Lich folder or asks you for it."
say "  - To uninstall, run: $APP/uninstall.sh"
say ""
if [ "$ASSUME_YES" = 0 ] && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  if ask " Open Chrono now?"; then
    (cd "$APP" && nohup "$RUBY" "$APP/chrono_gui.rbw" >/dev/null 2>&1 &)
  fi
fi
