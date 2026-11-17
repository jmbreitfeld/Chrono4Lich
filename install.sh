#!/usr/bin/env bash
# Chrono installer for Linux and Mac. Run from the unpacked Chrono4Lich folder:
#   ./install.sh            (asks before using the Ruby it finds)
#   ./install.sh --ruby /path/to/ruby --yes
#
# Installs for your user only (no sudo) into ~/.local/share/Chrono4Lich, adds a menu entry
# (Mac: Chrono in your Applications folder) and a "chrono" command. Run it again to upgrade;
# your settings are kept.
# If lichsched (Chrono's old name) is installed, it's replaced and its schedules carried over.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APP="$DATA_HOME/Chrono4Lich"
OLD_APP="$DATA_HOME/lichsched"
BIN="$HOME/.local/bin"
DESKTOP_DIR="$DATA_HOME/applications"
FILES=(chrono.rb chrono_config.rb chrono_schedule.rb chrono_eaccess.rb chrono_logins.rb chrono_rewards.rb chrono_lich_passwords.rb chrono_github.rb chrono_cronjob.rb chrono_update.rb chrono_sealedbox.rb chrono_gui.rbw chrono_helper.lic chrono.png README.txt uninstall.sh)

IS_MAC=0
[ "$(uname -s)" = Darwin ] && IS_MAC=1
# Mac: the main Applications folder (Finder's sidebar) when this user can write to it, which
# admin users can without a password; otherwise the one in the home folder.
if [ -w /Applications ] && [ "${CHRONO_MAC_APPS:-}" = "" ]; then MAC_APP="/Applications/Chrono.app"
else MAC_APP="${CHRONO_MAC_APPS:-$HOME/Applications}/Chrono.app"; fi

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
# Quoting for what this writes into other files:
#   sq      a word for sh (the "chrono" command, Chrono.app's launcher)
#   desk_q  an argument in a .desktop file's Exec= (inside "..."; see the freedesktop.org spec)
#   desk_v  a plain .desktop value (Path=, Icon=)
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
desk_q() {
  local s="$1"
  s="${s//\\/\\\\\\\\}"; s="${s//\"/\\\\\"}"; s="${s//\`/\\\\\`}"; s="${s//\$/\\\\\$}"; s="${s//%/%%}"
  printf '"%s"' "$s"
}
desk_v() { local s="$1"; printf '%s' "${s//\\/\\\\}"; }
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
has_gtk() { "$1" -e "require 'gtk3'" >/dev/null 2>&1; }
newest() { # the last of a list of version folders, in version order (sort -V isn't everywhere)
  local list; list="$(cat)"; [ -n "$list" ] || return 0
  { printf '%s\n' "$list" | sort -V 2>/dev/null || printf '%s\n' "$list" | sort; } | tail -n 1
}

if [ -z "$RUBY" ] && [ -f "$APP/ruby_path" ]; then
  prev="$(cat "$APP/ruby_path")"
  [ -x "$prev" ] && RUBY="$prev" && say " Using the same Ruby as last time: $RUBY"
fi
if [ -z "$RUBY" ]; then
  # Lich needs a Ruby with GTK3. On a Mac that's usually Homebrew's, not Apple's own old Ruby
  # in /usr/bin, so a Ruby that has GTK3 is offered first.
  first=""
  for c in "$(command -v ruby 2>/dev/null || true)" \
           "$(ls -d "$HOME"/.rbenv/versions/*/bin/ruby 2>/dev/null | newest)" \
           "$(ls -d "$HOME"/.asdf/installs/ruby/*/bin/ruby 2>/dev/null | newest)" \
           /opt/homebrew/opt/ruby/bin/ruby /usr/local/opt/ruby/bin/ruby \
           /usr/local/bin/ruby /usr/bin/ruby; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    real="$(resolve_ruby "$c" || true)"
    [ -n "$real" ] || continue
    [ -n "$first" ] || first="$real"
    has_gtk "$real" || continue
    say " Found Ruby with GTK: $real ($("$real" -e 'print RUBY_VERSION'))"
    if ask " Use this Ruby? This should be the one you run Lich with."; then RUBY="$real"; fi
    break
  done
  if [ -z "$RUBY" ] && [ -n "$first" ] && [ "$ASSUME_YES" = 1 ]; then RUBY="$first"; fi # fails the GTK check below, with help
fi
while [ -z "$RUBY" ]; do
  [ "$ASSUME_YES" = 1 ] && fail "No Ruby found. Run again with --ruby /path/to/ruby."
  read -r -p " Full path to the ruby you run Lich with: " RUBY || fail "No Ruby given."
done
REAL="$(resolve_ruby "$RUBY" || true)"
[ -n "$REAL" ] || fail "\"$RUBY\" isn't a working Ruby."
RUBY="$REAL"

say " Checking that this Ruby has GTK, which the window needs..."
if ! has_gtk "$RUBY"; then
  if [ "$IS_MAC" = 1 ]; then
    fail "This Ruby can't load GTK3 ($RUBY).
Use the Ruby you run Lich with (usually Homebrew's): run again with  --ruby /path/to/ruby
If Lich itself runs, find its Ruby by running in Terminal:  which ruby
To add GTK3 to a Homebrew Ruby:  brew install gtk+3  then
  $("$RUBY" -e 'print File.join(RbConfig::CONFIG["bindir"], "gem")') install gtk3"
  fi
  fail "This Ruby can't load GTK3 ($RUBY).
Lich's own windows need it too, so install it the way Lich's Linux instructions say,
usually:   $("$RUBY" -e 'print File.join(RbConfig::CONFIG["bindir"], "gem")') install gtk3
(on Pop!_OS / Ubuntu you may first need:  sudo apt install build-essential libgtk-3-dev)"
fi
say " OK."

# ---- things schedules need (warnings only; manual logins work without them) ----
if [ "$IS_MAC" = 1 ]; then
  : # Mac: schedules use launchd and alerts use the Mac's own, both built in
elif ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
  say " WARNING: systemd user services aren't available here, so schedules won't work."
  say "          Logging in and out from the window still works."
fi
if [ "$IS_MAC" = 0 ] && ! command -v notify-send >/dev/null 2>&1 && ! command -v zenity >/dev/null 2>&1; then
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

case "$RUBY$APP" in *$'\n'*|*$'\r'*) fail "The Ruby or install folder path has a line break in it, which Chrono can't use." ;; esac

# ---- copy files (chrono_config.json, your saved Lich folder, is kept) ----
for f in "${FILES[@]}"; do install -m 644 "$SRC/$f" "$APP/$f"; done
chmod 755 "$APP/uninstall.sh"
printf '%s\n' "$RUBY" > "$APP/ruby_path"

# ---- "chrono" command (only if that name is free, or already Chrono's) ----
if [ -e "$BIN/chrono" ] && ! grep -q 'chrono.rb' "$BIN/chrono" 2>/dev/null; then
  say " NOTE: $BIN/chrono already exists and isn't Chrono's, so it was left alone."
  say "       The command-line version is: $(sq "$RUBY") $(sq "$APP/chrono.rb")"
else
cat > "$BIN/chrono" <<EOF
#!/bin/sh
# Made by the Chrono installer. Runs chrono.rb with the Ruby that runs Lich.
exec $(sq "$RUBY") $(sq "$APP/chrono.rb") "\$@"
EOF
chmod 755 "$BIN/chrono"
fi

if [ "$IS_MAC" = 1 ]; then
# ---- Mac: Chrono.app in the Applications folder (a small app that starts Chrono) ----
# (an earlier install may have put it in the other Applications folder)
for old_app in "/Applications/Chrono.app" "$HOME/Applications/Chrono.app"; do
  [ "$old_app" = "$MAC_APP" ] && continue
  [ -x "$old_app/Contents/MacOS/Chrono" ] && grep -q 'chrono_gui.rbw' "$old_app/Contents/MacOS/Chrono" 2>/dev/null && rm -rf "$old_app"
done
if [ -e "$MAC_APP" ]; then
  grep -q 'chrono_gui.rbw' "$MAC_APP/Contents/MacOS/Chrono" 2>/dev/null || \
    fail "$MAC_APP already exists and isn't Chrono's, so it wasn't replaced. Rename or move it, then run install.sh again."
  rm -rf "$MAC_APP"
fi
mkdir -p "$MAC_APP/Contents/MacOS" "$MAC_APP/Contents/Resources"
cat > "$MAC_APP/Contents/MacOS/Chrono" <<EOF
#!/bin/sh
# Made by the Chrono installer. Starts Chrono with the Ruby that runs Lich.
export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH"
cd $(sq "$APP") && exec $(sq "$RUBY") $(sq "$APP/chrono_gui.rbw") "\$@"
EOF
printf '%s\n' "$MAC_APP" > "$APP/mac_app"   # where it is, for open-at-sign-in and updates
chmod 755 "$MAC_APP/Contents/MacOS/Chrono"
cat > "$MAC_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Chrono</string>
  <key>CFBundleDisplayName</key><string>Chrono</string>
  <key>CFBundleIdentifier</key><string>net.chrono4lich.chrono</string>
  <key>CFBundleExecutable</key><string>Chrono</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>chrono</string>
  <key>CFBundleShortVersionString</key><string>$("$RUBY" -e 'print File.read(ARGV[0])[/^CHRONO_VERSION = .([0-9.]+)/, 1].to_s' "$APP/chrono.rb")</string>
</dict>
</plist>
EOF
# the pocket watch icon, made from chrono.png with the Mac's own tools
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  set_dir="$(mktemp -d)/chrono.iconset"; mkdir -p "$set_dir"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$APP/chrono.png" --out "$set_dir/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
    sips -z $((sz*2)) $((sz*2)) "$APP/chrono.png" --out "$set_dir/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
  done
  iconutil -c icns "$set_dir" -o "$MAC_APP/Contents/Resources/chrono.icns" >/dev/null 2>&1 || true
fi
else
# ---- menu entry (named chrono.desktop so the dock matches it to the window) ----
cat > "$DESKTOP_DIR/chrono.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Chrono
GenericName=Lich login scheduler
Comment=Log GemStone IV characters in and out through Lich5, by hand or on a schedule
Exec=$(desk_q "$RUBY") $(desk_q "$APP/chrono_gui.rbw")
Path=$(desk_v "$APP")
Icon=$(desk_v "$APP/chrono.png")
StartupWMClass=chrono
Terminal=false
Categories=Game;Utility;
EOF
chmod 644 "$DESKTOP_DIR/chrono.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true

fi

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
if [ "$IS_MAC" = 1 ]; then
  if [ "$MAC_APP" = "/Applications/Chrono.app" ]; then say "  - \"Chrono\" is in your Applications folder."
  else say "  - \"Chrono\" is in the Applications folder inside your home folder ($MAC_APP)."; fi
  say "    Or press Command-Space and type Chrono."
else say "  - \"Chrono\" is in your applications menu."; fi
case ":$PATH:" in
  *":$BIN:"*) say "  - The \"chrono\" command works in a terminal." ;;
  *) say "  - The command-line version is $BIN/chrono ($BIN isn't on your PATH yet)." ;;
esac
say "  - The first time it opens, it finds your Lich folder or asks you for it."
say "  - To uninstall, run: $APP/uninstall.sh"
say ""
if [ "$ASSUME_YES" = 0 ] && { [ "$IS_MAC" = 1 ] || [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  if ask " Open Chrono now?"; then
    if [ "$IS_MAC" = 1 ]; then open "$MAC_APP"
    else (cd "$APP" && nohup "$RUBY" "$APP/chrono_gui.rbw" >/dev/null 2>&1 &)
    fi
  fi
fi
