# chrono_gui.rbw - window for logging GemStone IV and DragonRealms characters in and out through Lich5
#
# Keep this file next to chrono.rb. The installer (setup.exe or install.bat on Windows,
# install.sh on Linux) makes the shortcut that starts it.
#
# Logins and logouts are done by running chrono.rb, so everything the window does
# also goes into data\Chrono4Lich\chrono.log.

require 'gtk3'
require_relative 'chrono_config'

# ---------- finding the Lich folder before anything else loads ----------

module LichFolderPicker
  module_function

  def message(type, buttons, text)
    d = Gtk::MessageDialog.new(type: type, buttons_type: buttons, message: text)
    d.title = 'Chrono setup'
    r = d.run
    d.destroy
    r
  end

  def browse(parent = nil, title: 'Pick your Lich folder (the one with lich.rbw in it)')
    d = Gtk::FileChooserDialog.new(title: title,
                                   parent: parent, action: :select_folder,
                                   buttons: [['Cancel', Gtk::ResponseType::CANCEL], ['Select', Gtk::ResponseType::ACCEPT]])
    dir = d.run == Gtk::ResponseType::ACCEPT ? d.filename : nil
    d.destroy
    dir
  end

  # Several Lich installs found: let the person pick one.
  def choose(found, parent = nil)
    d = Gtk::Dialog.new(title: 'Chrono setup', parent: parent, flags: [:modal])
    d.add_button('Browse...', 1)
    d.add_button('Cancel', Gtk::ResponseType::CANCEL)
    d.add_button('Use this one', Gtk::ResponseType::OK)
    box = Gtk::Box.new(:vertical, 6)
    box.margin = 12
    box.pack_start(Gtk::Label.new('More than one Lich folder was found. Which one do you use?'), expand: false, fill: false)
    group = nil
    radios = found.map do |dir|
      r = group ? Gtk::RadioButton.new(member: group, label: ChronoConfig.disp(dir)) : Gtk::RadioButton.new(label: ChronoConfig.disp(dir))
      group ||= r
      box.pack_start(r, expand: false, fill: false)
      [r, dir]
    end
    d.content_area.pack_start(box, expand: true, fill: true)
    d.show_all
    resp = d.run
    picked = radios.find { |r, _| r.active? }&.last
    d.destroy
    return picked if resp == Gtk::ResponseType::OK
    return browse(parent) if resp == 1
    nil
  end

  # Ask until we have a valid folder or the person gives up. Returns the folder or nil.
  def pick(parent = nil, intro: nil)
    found = ChronoConfig.detect
    dir =
      if found.size == 1 && intro.nil?
        found.first
      elsif found.size > 1
        choose(found, parent)
      else
        message(:info, :ok, "#{intro || 'Chrono couldn\'t find your Lich folder.'}\n\n" \
                            'Pick the folder that has lich.rbw in it.')
        browse(parent)
      end
    loop do
      return nil unless dir
      return ChronoConfig.normalize(dir) if ChronoConfig.valid_lich_dir?(dir)
      message(:error, :ok, "#{ChronoConfig.why_invalid(dir)}\n\nPick the folder that has lich.rbw in it.")
      dir = browse(parent)
    end
  end

  def ensure_configured
    ChronoConfig.lich_dir || save_or_quit(pick)
  rescue RuntimeError => e # saved folder no longer valid
    save_or_quit(pick(intro: e.message))
  end

  def save_or_quit(dir)
    unless dir
      message(:warning, :ok, 'Chrono needs to know where Lich is installed, so it will close now. ' \
                             'Open it again when you\'re ready to pick the folder.')
      exit 0
    end
    ChronoConfig.save('lich_dir' => dir)
    dir
  end
end

# (the folder check and loading chrono.rb happen at the bottom, inside the crash handler)

CLI_SCRIPT = File.join(__dir__, 'chrono.rb')

def gui_log(msg)
  dir = defined?(STATE_DIR) && STATE_DIR ? STATE_DIR : ChronoConfig::APP_DIR
  FileUtils.mkdir_p(dir)
  File.open(File.join(dir, 'chrono.log'), 'a', 0o600) do |f|
    f.puts "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}  GUI: #{msg}"
  end
rescue StandardError
  nil # the log is a convenience; never let it hide the real error
end

# "Open Chrono when I sign in": Windows' per-user Run list (no admin needed), or a desktop
# autostart file on Linux. Starts minimized.
module Autostart
  RUN_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
  NAME    = 'Chrono'

  module_function

  def gui_script = File.join(ChronoConfig::APP_DIR, 'chrono_gui.rbw')

  def linux_file
    File.join(ENV['XDG_CONFIG_HOME'] || File.join(Dir.home, '.config'), 'autostart', 'chrono.desktop')
  end

  def command
    if ChronoConfig.windows?
      %("#{rubyw_path.tr('/', '\\')}" "#{gui_script.tr('/', '\\')}" --minimized)
    else
      "#{desktop_arg(RbConfig.ruby)} #{desktop_arg(gui_script)} --minimized"
    end
  end

  # One quoted argument for a .desktop file's Exec= line (freedesktop.org's rules: inside "...",
  # \ " ` $ take a backslash, which the file format then doubles; % is written %%).
  def desktop_arg(s)
    raise ArgumentError, 'path has a line break' if s.match?(/[\r\n]/)
    %("#{s.gsub(/[\\"`$]/) { |c| c == '\\' ? '\\\\\\\\' : "\\\\#{c}" }.gsub('%', '%%')}")
  end

  def desktop_value(s) = s.gsub('\\', '\\\\\\\\')

  # Mac: a launchd agent that opens Chrono when you sign in.
  def mac_file = File.join(Dir.home, 'Library', 'LaunchAgents', 'net.chrono4lich.autostart.plist')

  def on?
    if ChronoConfig.mac?
      File.exist?(mac_file)
    elsif ChronoConfig.windows?
      system('reg', 'query', RUN_KEY, '/v', NAME, out: File::NULL, err: File::NULL) ? true : false
    else
      File.exist?(linux_file)
    end
  end

  def enable!
    if ChronoConfig.mac?
      FileUtils.mkdir_p(File.dirname(mac_file))
      app = ChronoUpdate.mac_app
      # through Chrono.app when there is one, so it shows as "Chrono" with its icon, not "ruby"
      args = app ? ['/usr/bin/open', '-a', app, '--args', '--minimized'] : [RbConfig.ruby, gui_script, '--minimized']
      File.write(mac_file, Schedules.plist_xml(
        'Label' => 'net.chrono4lich.autostart',
        'ProgramArguments' => args,
        'WorkingDirectory' => ChronoConfig::APP_DIR,
        'EnvironmentVariables' => { 'PATH' => Schedules::MAC_PATH },
        'RunAtLoad' => true,
        'LimitLoadToSessionType' => 'Aqua'
      ))
    elsif ChronoConfig.windows?
      ok = system('reg', 'add', RUN_KEY, '/v', NAME, '/t', 'REG_SZ', '/d', command, '/f', out: File::NULL, err: File::NULL)
      fail! "Windows didn't accept the startup setting (reg add failed)." unless ok
    else
      FileUtils.mkdir_p(File.dirname(linux_file))
      File.write(linux_file, <<~DESKTOP)
        [Desktop Entry]
        Type=Application
        Name=Chrono
        Comment=Opens Chrono (minimized) when you sign in
        Exec=#{command}
        Path=#{desktop_value(ChronoConfig::APP_DIR)}
        Icon=#{desktop_value(File.join(ChronoConfig::APP_DIR, 'chrono.png'))}
        Terminal=false
        X-GNOME-Autostart-enabled=true
      DESKTOP
    end
    gui_log("autostart on: #{command}")
  end

  def disable!
    if ChronoConfig.mac?
      FileUtils.rm_f(mac_file)
    elsif ChronoConfig.windows?
      system('reg', 'delete', RUN_KEY, '/v', NAME, '/f', out: File::NULL, err: File::NULL)
    else
      FileUtils.rm_f(linux_file)
    end
    gui_log('autostart off')
  end

  # Keeps the entry pointing at this Chrono and Ruby (after an update or a new Ruby).
  def refresh!
    enable! if on?
  rescue StandardError => e
    gui_log("autostart refresh failed: #{e.message}")
  end
end

# Window settings kept between sessions (Lich5/data/chrono/gui_settings.json): which characters
# are ticked, the start scripts, and the update-check choices.
module GuiPrefs
  module_function

  def file = File.join(STATE_DIR, 'gui_settings.json')

  def load
    JSON.parse(File.read(file))
  rescue StandardError
    {}
  end

  def get(key, default = nil)
    v = load[key]
    v.nil? ? default : v
  end

  def set(key, value)
    data = load
    return if data[key] == value

    data[key] = value
    ensure_state_dir
    tmp = "#{file}.tmp"
    File.write(tmp, JSON.pretty_generate(data))
    File.rename(tmp, file)
  rescue StandardError => e
    gui_log("couldn't save window settings: #{e.message}")
  end
end

# Light or dark, and how big the text is (Settings tab), kept in gui_settings.json.
# Dark uses the theme's own dark version (GTK's "prefer dark"); "Match my computer" follows
# the Mac's, Windows' or GNOME's light/dark setting, and is checked again every 30 seconds.
# Text size scales the font GTK uses everywhere, from the size the system gave it.
module Appearance
  THEMES = [['auto', 'Match my computer'], ['light', 'Light'], ['dark', 'Dark']].freeze
  SIZES  = [[100, 'Normal'], [125, 'Large'], [150, 'Larger'], [175, 'Largest'], [200, 'Huge']].freeze

  module_function

  def theme
    t = GuiPrefs.get('theme', 'auto').to_s
    THEMES.any? { |id, _| id == t } ? t : 'auto'
  end

  def text_scale = GuiPrefs.get('text_scale', 100).to_i.clamp(50, 300)

  # The computer's own light/dark setting, where Chrono can tell (otherwise light).
  def system_dark?
    if ChronoConfig.mac?
      IO.popen(%w[defaults read -g AppleInterfaceStyle], err: File::NULL, &:read).to_s.strip.casecmp?('dark')
    elsif ChronoConfig.windows?
      require 'win32/registry' # read directly: running reg.exe would flash a console window
      Win32::Registry::HKEY_CURRENT_USER.open('Software\Microsoft\Windows\CurrentVersion\Themes\Personalize') do |r|
        r['AppsUseLightTheme'].to_i.zero?
      end
    else
      IO.popen(%w[gsettings get org.gnome.desktop.interface color-scheme], err: File::NULL, &:read).to_s.include?('dark')
    end
  rescue StandardError, LoadError
    false
  end

  def dark? = theme == 'dark' || (theme == 'auto' && system_dark?)

  def css
    @css ||= Gtk::CssProvider.new.tap do |p|
      Gtk::StyleContext.add_provider_for_screen(Gdk::Screen.default, p, Gtk::StyleProvider::PRIORITY_APPLICATION)
    end
  end

  # GTK's settings object, fetched once and kept for good. glib2 finds the Ruby object for a GTK
  # object through a pointer Ruby's garbage collector doesn't see. So when Chrono let go of it
  # and fetched it again 30 seconds later, it could get back one the collector had already
  # found unused but not yet freed; Ruby then freed it while apply! was using it, and the window
  # crashed. Keeping it means it's never unused.
  def settings = (@settings ||= Gtk::Settings.default)

  # Applies both settings. Returns true if anything changed (so the caller can redraw).
  # This runs every 30 seconds, so it compares with what it set last time and only touches GTK
  # when something changed: each setting or style sheet change makes GTK restyle the whole window.
  def apply!
    want_dark = dark?
    scale = text_scale
    dark_changed = want_dark != @applied_dark
    font_changed = scale != @applied_scale
    return false unless dark_changed || font_changed

    if dark_changed
      settings.gtk_application_prefer_dark_theme = want_dark
      @applied_dark = want_dark
    end
    if font_changed
      @base_font ||= settings.gtk_font_name.to_s
      desc = Pango::FontDescription.new(@base_font)
      base = desc.size.to_f / Pango::SCALE
      base = 12.0 if base <= 0
      desc.size = (base * scale / 100.0 * Pango::SCALE).round
      settings.gtk_font_name = desc.to_s
      # tick boxes and round buttons don't follow the font, so grow them with it (themes draw them 14-16px)
      box = (14 * scale / 100.0).round
      css.load(data: "check, radio { min-width: #{box}px; min-height: #{box}px; }")
      @applied_scale = scale
    end
    true
  rescue StandardError => e
    gui_log("couldn't apply the appearance settings: #{e.class}: #{e.message}")
    false
  end
end

class ChronoWindow
  COL_CHECK   = 0
  COL_NAME    = 1
  COL_REALM   = 2
  COL_ACCOUNT = 3
  COL_STATUS  = 4
  COL_SPEC    = 5
  COL_FRONTEND = 6 # the frontend this character logs in with (editable)
  COL_CODE     = 7 # its game code, to find its saved login

  STATE_TEXT = {
    'online'        => 'Online',
    'logging_out'   => 'Logging out...',
    'logout_failed' => 'LOGOUT FAILED',
    'offline'       => 'Offline'
  }.freeze

  def initialize
    @queue = Queue.new
    @busy = false
    @job_errors = []
    build_window
    append_log("!!! DragonRealms characters are hidden: #{DR_LICH_DIR_PROBLEM}") if DR_LICH_DIR_PROBLEM
    install_helpers
    safely { reload_characters }
    safely { refresh_status }
    GLib::Timeout.add(200) { safely { pump_queue }; true }
    GLib::Timeout.add_seconds(3) { safely { refresh_status unless @busy_refreshing }; true }
    # "Match my computer": notice when the computer switches between light and dark
    GLib::Timeout.add_seconds(30) { safely { refresh_appearance if Appearance.theme == 'auto' }; true }
    @win.show_all
    @win.iconify if ARGV.include?('--minimized') # opened at sign-in
    Autostart.refresh!
    check_for_update(quiet: true) if GuiPrefs.get('check_updates', true)
  end

  # Puts the current helper in each Lich folder's scripts folder, so it's there for Lich's
  # autostart (Saga logins) even before Chrono logs anyone in from that folder.
  def install_helpers
    lich_folders.each do |dir|
      ensure_helper!(dir)
    rescue Fail, SystemCallError => e
      gui_log("couldn't install #{HELPER}.lic into #{dir}: #{e.message}")
    end
  end

  # ---------- updates and about ----------

  # Asks GitHub for the newest release in the background. quiet: only speak up if there's a
  # newer version (and it wasn't skipped); otherwise also say "up to date" / "couldn't check".
  def check_for_update(quiet:)
    result = nil
    done = false
    Thread.new do
      result = ChronoGitHub.latest_release
    ensure
      done = true
    end
    GLib::Timeout.add(300) do
      next true unless done

      safely { show_update_result(result, quiet) }
      false
    end
  end

  def show_update_result(rel, quiet)
    if rel.nil?
      gui_log('update check: GitHub not reachable')
      info_dialog("Couldn't check for updates right now (GitHub didn't answer). Try again later.") unless quiet
      return
    end
    unless ChronoGitHub.newer?(rel[:version], CHRONO_VERSION)
      info_dialog("Chrono #{CHRONO_VERSION} is the latest version.") unless quiet
      return
    end
    return if quiet && GuiPrefs.get('skipped_version') == rel[:version]

    gui_log("update available: #{rel[:version]} (have #{CHRONO_VERSION})")
    @update_release = rel
    @update_label.text = "Chrono #{rel[:version]} is available. You have #{CHRONO_VERSION}."
    @update_bar.no_show_all = false # (show_all skips a widget marked no_show_all)
    @update_bar.show_all
  end

  def build_update_bar
    @update_bar = Gtk::InfoBar.new
    @update_bar.message_type = :info
    @update_bar.no_show_all = true
    @update_label = Gtk::Label.new('')
    @update_label.xalign = 0
    @update_bar.content_area.pack_start(@update_label, expand: true, fill: true)
    @update_bar.add_button('Update now', 1)
    @update_bar.add_button('Release page', 4)
    @update_bar.add_button('Not now', 2)
    @update_bar.add_button('Skip this version', 3)
    @update_bar.signal_connect('response') do |_, id|
      safely do
        rel = @update_release
        case id
        when 1
          @update_bar.hide
          update_now(rel)
          next
        when 4
          open_url(rel[:url])
          append_log("Opened the release page for Chrono #{rel[:version]}. Run the installer there; your settings are kept.")
        when 3
          GuiPrefs.set('skipped_version', rel[:version])
          append_log("Won't mention Chrono #{rel[:version]} again. (Settings > Check for updates now still finds it.)")
        end
        @update_bar.hide
      end
    end
    @update_bar
  end

  # Downloads this system's update, checks it, closes Chrono and starts it.
  def update_now(rel)
    unless ChronoUpdate.can_update_here?
      info_dialog("This copy of Chrono was set up from the zip, so it can't update itself (the installer would " \
                  "put a second copy somewhere else).\n\nOpening the release page: download Chrono4Lich.zip there " \
                  'and replace this folder, or switch to the setup .exe.')
      return open_url(rel[:url])
    end
    asset = ChronoUpdate.asset_for_here(rel)
    unless asset
      info_dialog("Chrono #{rel[:version]} has no download for this system. Opening the release page.")
      return open_url(rel[:url])
    end
    what = if ChronoConfig.windows? then 'start the installer (its last page can reopen Chrono)'
           elsif ChronoConfig.mac? then 'install it in a Terminal window, then reopen itself'
           else 'run its install.sh, then reopen itself'
           end
    return unless confirm_dialog("Update to Chrono #{rel[:version]}?\n\nChrono will download #{asset[:name]} " \
                                 "(#{(asset[:size] / 1_048_576.0).round(1)} MB), check it, close, and #{what}.\n\n" \
                                 'Characters that are logged in stay logged in, and your settings and schedules are kept.')
    in_background("Downloading Chrono #{rel[:version]}...",
                  done: lambda { |path|
                    safely do
                      if ChronoConfig.mac? # (see ChronoUpdate.start_mac!)
                        ChronoUpdate.start_mac!(path, version: rel[:version])
                      else
                        ChronoUpdate.start!(path, version: rel[:version])
                      end
                      append_log("Starting the update to Chrono #{rel[:version]}. Chrono will close now.")
                      remember_window_size
                      GLib::Timeout.add(800) { Gtk.main_quit; false }
                    end
                  },
                  failed: ->(msg) { error_dialog("The update didn't happen:\n\n#{msg}") }) do
      ChronoUpdate.fetch(rel)
    end
  end

  def about_dialog
    d = Gtk::AboutDialog.new
    d.transient_for = @win
    d.modal = true
    d.program_name = 'Chrono'
    d.version = CHRONO_VERSION
    d.comments = "Logs GemStone IV and DragonRealms characters in and out through Lich5, by hand or on a schedule.\n" \
                 "Adds and manages Lich's saved logins (any frontend, plus Warlock).\n" \
                 'Claims monthly SimuCoins and, if you like, daily login rewards, on this computer or on GitHub.'
    d.website = ChronoGitHub::PROJECT_URL
    d.website_label = 'Chrono on GitHub (downloads, help)'
    d.authors = ['Peggyanne']
    # "Credits" button in the About window
    d.add_credit_section('Inspired by', ['Ondreian, author of simu-rewards (reward claiming)',
                                         "OSXLich-Doug, author of Lich5's account manager (Logins tab)"])
    d.add_credit_section('Built on', ['Lich5 by Elanthia Online', 'elogin.lic (the original idea)'])
    d.copyright = 'Copyright (c) 2026 Peggyanne'
    d.license_type = :mit_x11
    d.logo = GdkPixbuf::Pixbuf.new(file: ICON_FILE, width: 96, height: 96) if File.exist?(ICON_FILE)
    d.run
    d.destroy
  end

  # ---------- layout ----------

  def build_window
    @win = Gtk::Window.new('Chrono')
    # the size (and maximized or not) the window had when it was last closed
    w, h = Array(GuiPrefs.get('window_size', [760, 620])).map(&:to_i)
    @win.set_default_size(w.clamp(500, 10_000), h.clamp(400, 10_000))
    @win.maximize if GuiPrefs.get('window_maximized', false)
    @win.signal_connect('window-state-event') do |_, ev|
      @win_maximized = ev.new_window_state.maximized?
      false
    end
    @win.signal_connect('delete-event') do
      keep_open = !confirm_close
      remember_window_size unless keep_open
      keep_open
    end
    @win.signal_connect('destroy') { Gtk.main_quit }

    root = Gtk::Box.new(:vertical, 8)
    root.margin = 10
    @win.add(root)

    root.pack_start(build_update_bar, expand: false, fill: false)

    notebook = Gtk::Notebook.new
    notebook.append_page(scrollable(build_characters_page), Gtk::Label.new('Characters'))
    notebook.append_page(scrollable(build_schedules_page), Gtk::Label.new('Schedules'))
    notebook.append_page(scrollable(build_rewards_page), Gtk::Label.new('Rewards'))
    notebook.append_page(scrollable(build_logins_page), Gtk::Label.new('Logins'))
    notebook.append_page(scrollable(build_settings_page), Gtk::Label.new('Settings'))
    root.pack_start(notebook, expand: true, fill: true)

    # output, shared by both tabs
    @log_view = Gtk::TextView.new
    @log_view.editable = false
    @log_view.cursor_visible = false
    @log_view.monospace = true
    @log_view.wrap_mode = :word_char
    log_scroll = Gtk::ScrolledWindow.new
    log_scroll.set_policy(:automatic, :automatic)
    log_scroll.set_size_request(-1, 160)
    log_scroll.add(@log_view)
    root.pack_start(log_scroll, expand: false, fill: true)

    status_row = Gtk::Box.new(:horizontal, 6)
    @status_label = Gtk::Label.new('Ready.')
    @status_label.xalign = 0
    status_row.pack_start(@status_label, expand: true, fill: true)
    status_row.pack_end(button('About Chrono') { about_dialog }, expand: false, fill: false)
    root.pack_start(status_row, expand: false, fill: false)
  end

  def build_characters_page
    outer = Gtk::Box.new(:vertical, 8)
    outer.margin = 6

    # filters, kept for next time (GemStone only and DragonRealms only exclude each other)
    filters = Gtk::Box.new(:horizontal, 12)
    @hide_test = Gtk::CheckButton.new("Don't show Test")
    @gs_only = Gtk::CheckButton.new('GemStone only')
    @dr_only = Gtk::CheckButton.new('DragonRealms only')
    @hide_test.active = GuiPrefs.get('hide_test', false) == true
    @gs_only.active = GuiPrefs.get('game_filter', nil) == 'gs'
    @dr_only.active = GuiPrefs.get('game_filter', nil) == 'dr'
    @hide_test.signal_connect('toggled') { safely { filters_changed } }
    [[@gs_only, @dr_only], [@dr_only, @gs_only]].each do |box, other|
      box.signal_connect('toggled') do
        safely do
          if box.active? && other.active?
            @filters_syncing = true
            other.active = false
            @filters_syncing = false
          end
          filters_changed
        end
      end
    end
    [@hide_test, @gs_only, @dr_only].each { |c| filters.pack_start(c, expand: false, fill: false) }
    @filter_count = Gtk::Label.new('')
    filters.pack_end(@filter_count, expand: false, fill: false)
    outer.pack_start(filters, expand: false, fill: false)

    # character list
    @store = Gtk::ListStore.new(TrueClass, String, String, String, String, String, String, String)
    @view = Gtk::TreeView.new(@store)
    toggle = Gtk::CellRendererToggle.new
    toggle.signal_connect('toggled') do |_, path|
      iter = @store.get_iter(path)
      iter[COL_CHECK] = !iter[COL_CHECK]
      remember_selection
    end
    @check_col = Gtk::TreeViewColumn.new('', toggle, active: COL_CHECK)
    @view.append_column(@check_col)
    [['Character', COL_NAME], ['Realm', COL_REALM], ['Account', COL_ACCOUNT]].each do |title, col|
      column = Gtk::TreeViewColumn.new(title, Gtk::CellRendererText.new, text: col)
      column.resizable = true
      column.sort_column_id = col
      @view.append_column(column)
    end
    @frontend_col = character_frontend_column
    @view.append_column(@frontend_col)
    status_col = Gtk::TreeViewColumn.new('Status', Gtk::CellRendererText.new, text: COL_STATUS)
    status_col.resizable = true
    status_col.sort_column_id = COL_STATUS
    @view.append_column(status_col)
    # A "Log in" / "Log out" button on each row: one character, whatever is ticked. A list
    # can't hold real buttons, so it shows a picture of one, drawn by a real (off-screen) button
    # in the current theme; clicks on it are handled below.
    # (redrawn by refresh_appearance when the theme or text size changes)
    @row_images = row_images
    cell = Gtk::CellRendererPixbuf.new
    cell.xpad = 4
    cell.xalign = 0
    @action_col = Gtk::TreeViewColumn.new('', cell)
    @action_col.set_cell_data_func(cell) do |_col, c, _model, iter|
      img = @row_images[row_action(iter)]
      c.visible = !img.nil?
      c.pixbuf = img if img
    end
    @view.append_column(@action_col)
    @view.signal_connect('button-press-event') do |view, ev|
      hit = ev.button == 1 && ev.event_type == Gdk::EventType::BUTTON_PRESS && view.get_path_at_pos(ev.x.to_i, ev.y.to_i)
      if hit && hit[1] == @action_col
        iter = @store.get_iter(hit[0])
        GLib::Idle.add { safely { row_action_clicked(iter[COL_SPEC], iter[COL_NAME], row_action(iter)) }; false } if iter
        true
      else
        false
      end
    end
    # Double-clicking a character (or Enter on it) does what its row's button does: Log in or Log out.
    # (Double-clicking the tick box only ticks it, and the Frontend only opens its dropdown; the
    # button handles its own clicks above.)
    @view.signal_connect('row-activated') do |_view, path, column|
      next if column == @check_col || column == @frontend_col # (those are for ticking and picking)

      iter = @store.get_iter(path)
      action = iter && row_action(iter)
      GLib::Idle.add { safely { row_action_clicked(iter[COL_SPEC], iter[COL_NAME], action) }; false } if action
    end
    list_scroll = Gtk::ScrolledWindow.new
    list_scroll.set_policy(:automatic, :automatic)
    list_scroll.add(@view)
    outer.pack_start(list_scroll, expand: true, fill: true)

    # selection buttons
    row1 = Gtk::Box.new(:horizontal, 6)
    row1.pack_start(button('Select all') { set_all_checks(true) }, expand: false, fill: false)
    row1.pack_start(button('Select none') { set_all_checks(false) }, expand: false, fill: false)
    hint = Gtk::Label.new('Tip: double-click a character to log it in or out.')
    hint.style_context.add_class('dim-label')
    hint.margin_start = 6
    row1.pack_start(hint, expand: false, fill: false)
    row1.pack_end(button('Reload characters') { reload_characters; refresh_status }, expand: false, fill: false)
    outer.pack_start(row1, expand: false, fill: false)

    # start scripts
    row2 = Gtk::Box.new(:horizontal, 6)
    row2.pack_start(Gtk::Label.new('Start scripts after login (comma-separated):'), expand: false, fill: false)
    @scripts_entry = Gtk::Entry.new
    @scripts_entry.placeholder_text = 'optional, e.g. go2,bigshot'
    @scripts_entry.text = GuiPrefs.get('scripts', '').to_s
    @scripts_entry.signal_connect('changed') { GuiPrefs.set('scripts', @scripts_entry.text) }
    row2.pack_start(@scripts_entry, expand: true, fill: true)
    outer.pack_start(row2, expand: false, fill: false)

    # actions
    row3 = Gtk::Box.new(:horizontal, 6)
    @action_buttons = [
      button('Log in selected') { login_selected },
      button('Log out selected') { logout_selected },
      button('Log out all') { run_job('Log out all', [%w[logout all]]) },
      button('Force close selected...') { kill_selected }
    ]
    @action_buttons[0..2].each { |b| row3.pack_start(b, expand: false, fill: false) }
    row3.pack_end(@action_buttons[3], expand: false, fill: false)
    outer.pack_start(row3, expand: false, fill: false)
    outer
  end

  # ---------- schedules tab ----------

  def build_schedules_page
    page = Gtk::Box.new(:vertical, 8)
    page.margin = 6

    # name, days, login, logout, characters, on
    @sched_store = Gtk::ListStore.new(String, String, String, String, String, String)
    @sched_view = Gtk::TreeView.new(@sched_store)
    [['Schedule', 0], ['Days', 1], ['Log in', 2], ['Log out', 3], ['Characters', 4], ['On', 5]].each do |title, col|
      column = Gtk::TreeViewColumn.new(title, Gtk::CellRendererText.new, text: col)
      column.resizable = true
      @sched_view.append_column(column)
    end
    @sched_view.signal_connect('row-activated') { safely { edit_schedule } }
    scroll = Gtk::ScrolledWindow.new
    scroll.set_policy(:automatic, :automatic)
    scroll.add(@sched_view)
    page.pack_start(scroll, expand: true, fill: true)

    row = Gtk::Box.new(:horizontal, 6)
    row.pack_start(button('New...') { edit_schedule_dialog(nil) }, expand: false, fill: false)
    row.pack_start(button('Edit...') { edit_schedule }, expand: false, fill: false)
    row.pack_start(button('Delete...') { delete_schedule }, expand: false, fill: false)
    test_login  = button('Test login now') { test_schedule('login') }
    test_logout = button('Test logout now') { test_schedule('logout') }
    @action_buttons.push(test_login, test_logout)
    row.pack_end(test_logout, expand: false, fill: false)
    row.pack_end(test_login, expand: false, fill: false)
    page.pack_start(row, expand: false, fill: false)

    note_text =
      if ChronoConfig.windows?
        'Schedules run even when this window is closed. The computer must be on or asleep ' \
        '(not shut down), and you must be signed in to Windows. A pop-up appears if a ' \
        'scheduled login or logout fails.'
      else
        'Schedules run even when this window is closed. The computer must be on and awake ' \
        '(a sleeping computer isn\'t woken up), and you must be logged in to your desktop. ' \
        'A notification appears if a scheduled login or logout fails.'
      end
    note = Gtk::Label.new(note_text)
    note.wrap = true
    note.xalign = 0
    page.pack_start(note, expand: false, fill: false)

    safely { reload_schedules }
    page
  end

  # ---------- settings tab ----------

  # ---------- rewards tab ----------

  def build_rewards_page
    page = Gtk::Box.new(:vertical, 8)
    page.margin = 6

    row = Gtk::Box.new(:horizontal, 6)
    @rewards_on = Gtk::CheckButton.new('Claim rewards automatically every day at')
    row.pack_start(@rewards_on, expand: false, fill: false)
    box, @rewards_time = time_row(nil)
    @rewards_time_box = box
    row.pack_start(box, expand: false, fill: false)
    save = button('Save') { save_rewards_schedule }
    @action_buttons << save
    row.pack_end(save, expand: false, fill: false)
    page.pack_start(row, expand: false, fill: false)

    @rewards_info = Gtk::Label.new('')
    @rewards_info.xalign = 0
    @rewards_info.wrap = true
    page.pack_start(@rewards_info, expand: false, fill: false)

    # free-to-play accounts get only daily login rewards; hiding them is kept for next time
    f2p_row = Gtk::Box.new(:horizontal, 12)
    @hide_f2p = Gtk::CheckButton.new("Don't show F2P")
    @hide_f2p.active = GuiPrefs.get('hide_f2p', false) == true
    @hide_f2p.signal_connect('toggled') { safely { GuiPrefs.set('hide_f2p', @hide_f2p.active?); reload_rewards } }
    f2p_row.pack_start(@hide_f2p, expand: false, fill: false)
    @rewards_count = Gtk::Label.new('')
    f2p_row.pack_end(@rewards_count, expand: false, fill: false)
    page.pack_start(f2p_row, expand: false, fill: false)

    # account, simucoins, daily, last result, claim on GitHub, has characters that get daily rewards,
    # plan (F2P, Standard, Premium...), free-to-play
    @rewards_store = Gtk::ListStore.new(String, TrueClass, TrueClass, String, TrueClass, TrueClass, String, TrueClass)
    @rewards_view = Gtk::TreeView.new(@rewards_store)
    @rewards_view.append_column(Gtk::TreeViewColumn.new('Account', Gtk::CellRendererText.new, text: 0))
    @rewards_view.append_column(Gtk::TreeViewColumn.new('Plan', Gtk::CellRendererText.new, text: 6))
    [[1, 'SimuCoins', :coins], [2, 'Daily login rewards', :daily]].each do |col, title, key|
      toggle = Gtk::CellRendererToggle.new
      toggle.signal_connect('toggled') do |_, path|
        safely do
          it = @rewards_store.get_iter(path)
          it[col] = !it[col]
          Rewards.set_account(it[0], key => it[col])
          append_log("#{it[0]}: #{title} #{it[col] ? 'on' : 'off'}.")
          reload_github_status
        end
      end
      column = Gtk::TreeViewColumn.new(title, toggle, active: col)
      # no SimuCoins box for a free-to-play account (it gets no bonus), and no daily one for an
      # account with no characters that get daily rewards
      column.set_cell_data_func(toggle) do |_c, r, _m, it|
        r.activatable = r.visible = key == :daily ? it[5] : !it[7]
      end
      @rewards_view.append_column(column)
    end
    gh_toggle = Gtk::CellRendererToggle.new
    gh_toggle.signal_connect('toggled') do |_, path|
      safely do
        it = @rewards_store.get_iter(path)
        it[4] = !it[4]
        Rewards.set_account(it[0], where: it[4] ? 'github' : 'pc')
        append_log("#{it[0]}: claims on #{it[4] ? 'GitHub' : 'this PC'}.")
        reload_rewards
      end
    end
    gh_col = Gtk::TreeViewColumn.new('Claim on GitHub', gh_toggle, active: 4)
    # Not for a free-to-play account: simu-rewards on GitHub always checks the store first, and
    # for an account with no SimuCoin bonus that would likely fail the run every day. Its daily
    # login rewards are claimed here instead.
    gh_col.set_cell_data_func(gh_toggle) { |_c, r, _m, it| r.activatable = r.visible = !it[7] }
    @rewards_view.append_column(gh_col)
    last = Gtk::TreeViewColumn.new('Last result', Gtk::CellRendererText.new, text: 3)
    last.expand = true
    @rewards_view.append_column(last)
    @rewards_view.tooltip_column = 3 # hover a row to see the whole result
    scroll = Gtk::ScrolledWindow.new
    scroll.set_policy(:automatic, :automatic)
    scroll.add(@rewards_view)
    # ask for room for every account (there are only a few), so large text doesn't squeeze it
    scroll.propagate_natural_height = true if scroll.respond_to?(:propagate_natural_height=)
    page.pack_start(scroll, expand: true, fill: true)

    row2 = Gtk::Box.new(:horizontal, 6)
    all = button('Claim now') { run_job('Claim rewards', [['run-rewards']]) }
    one = button('Claim now for selected') do
      it = @rewards_view.selection.selected
      next error_dialog('Click an account in the list first.') unless it
      run_job("Claim rewards for #{it[0]}", [['run-rewards', it[0]]])
    end
    @action_buttons.push(all, one)
    row2.pack_start(all, expand: false, fill: false)
    row2.pack_start(one, expand: false, fill: false)
    row2.pack_end(button('History...') { rewards_history_dialog }, expand: false, fill: false)
    page.pack_start(row2, expand: false, fill: false)

    # GitHub: claims while this computer is off
    gh_title = Gtk::Label.new
    gh_title.set_markup('<b>GitHub</b> (claims even while this computer is off)')
    gh_title.xalign = 0
    page.pack_start(gh_title, expand: false, fill: false)
    @github_status = Gtk::Label.new('')
    @github_status.xalign = 0
    @github_status.wrap = true
    page.pack_start(@github_status, expand: false, fill: false)
    row3 = Gtk::Box.new(:horizontal, 6)
    @github_setup_btn = button('Set up GitHub...') { github_dialog(:sync) }
    open_btn = button('Open results on GitHub') do
      gh = Rewards.github_state
      next error_dialog('GitHub isn\'t set up yet.') unless gh && gh['repo']
      open_url(ChronoGitHub.actions_url(gh['repo']))
    end
    stop_btn = button('Stop using GitHub...') { github_dialog(:stop) }
    @action_buttons.push(@github_setup_btn, stop_btn)
    row3.pack_start(@github_setup_btn, expand: false, fill: false)
    row3.pack_start(open_btn, expand: false, fill: false)
    row3.pack_end(stop_btn, expand: false, fill: false)
    page.pack_start(row3, expand: false, fill: false)

    # Exact timing: cron-job.org starts the GitHub run on time (GitHub's own timer runs late)
    row4 = Gtk::Box.new(:horizontal, 6)
    @exact_btn = button('Exact timing...') { exact_dialog }
    @action_buttons.push(@exact_btn)
    @exact_status = Gtk::Label.new('')
    @exact_status.xalign = 0
    @exact_status.wrap = true
    row4.pack_start(@exact_btn, expand: false, fill: false)
    row4.pack_start(@exact_status, expand: true, fill: true)
    page.pack_start(row4, expand: false, fill: false)

    note = Gtk::Label.new(
      'SimuCoins: your subscription bonus is offered once a month. Chrono checks every day, so it\'s ' \
      "claimed as soon as it's offered, and a day the computer was off is caught up the next time it's on.\n" \
      'Daily login rewards (off unless you turn them on): Chrono briefly logs in each Prime character on ' \
      'the account, collects the reward, and quits. Don\'t turn this on for an account you might be playing ' \
      'at that time: a character online somewhere else (not started by Chrono) would be disconnected. ' \
      "Characters Chrono started are detected, and that account is skipped.\n" \
      'Claim on GitHub: that account is claimed by GitHub instead of this computer, using elanthia-online\'s ' \
      'simu-rewards. GitHub can\'t see who is online, so daily login rewards there never skip.'
    )
    note.wrap = true
    note.xalign = 0
    page.pack_start(note, expand: false, fill: false)

    safely { reload_rewards }
    page
  end

  def reload_rewards
    return unless @rewards_store
    data = Rewards.load
    @rewards_on.active = data['enabled']
    h, m = data['time'].split(':').map(&:to_i)
    hour, minute = @rewards_time_box.children.select { |c| c.is_a?(Gtk::SpinButton) }
    hour.value = h
    minute.value = m
    @rewards_info.text =
      if data['enabled']
        "On: every day at #{data['time']}. Runs even when this window is closed; the computer just needs to be on."
      else
        'Off. Tick the box and click Save to claim every day.'
      end
    selected = @rewards_view.selection.selected&.[](0)
    @rewards_store.clear
    all = Rewards.accounts(data)
    shown = @hide_f2p&.active? ? all.reject { |a| a[:free] } : all
    @rewards_count&.text = shown.size == all.size ? "#{all.size} accounts" : "#{shown.size} of #{all.size} shown"
    shown.each do |a|
      it = @rewards_store.append
      it[0] = a[:name]
      it[1] = a[:coins]
      it[2] = a[:daily]
      it[3] = a[:where] == 'github' ? 'claimed on GitHub (see "Open results on GitHub")' : Rewards.summary(a[:last])
      it[4] = a[:where] == 'github'
      it[5] = a[:daily_ok]
      it[6] = a[:plan].to_s
      it[7] = a[:free]
      @rewards_view.selection.select_iter(it) if a[:name] == selected
    end
    reload_github_status(data)
  end

  def reload_github_status(data = Rewards.load)
    return unless @github_status
    gh = Rewards.github_state(data)
    why = Rewards.github_needs_update(data)
    active = gh && !gh['stopped']
    @github_setup_btn.label = active ? 'Update GitHub...' : 'Set up GitHub...'
    @github_status.text =
      if !active && Rewards.github_accounts(data).empty?
        'Not set up. Tick "Claim on GitHub" for the accounts GitHub should claim, then click "Set up GitHub".'
      elsif !active
        "Not set up yet for #{Rewards.github_accounts(data).map { |a| a[:name] }.join(', ')}. Click \"Set up GitHub\"."
      else
        text = "github.com/#{gh['repo']} claims for #{Array(gh['accounts']).join(', ')} every day at about #{gh['time']}; " \
               "set up #{Time.at(gh['at']).strftime('%b %-d %-I:%M %p')}."
        why ? "#{text}\nNEEDS UPDATING: #{why}. Click \"Update GitHub\"." : text
      end
    return unless @exact_status
    ex = Rewards.exact_state(data)
    ex_why = Rewards.exact_needs_update(data)
    @exact_status.text =
      if ex && ex_why
        "NEEDS UPDATING: #{ex_why}. Click \"Exact timing\"."
      elsif ex
        "On: cron-job.org starts the run at #{ex['time']}#{ex['tz'] == 'UTC' ? ' (UTC-based; shifts with daylight saving)' : ''}; " \
          "GitHub's own schedule is a backup at #{ChronoGitHub.backup_time(ex['time'])}."
      elsif active
        "Off. GitHub's own timer can start runs hours late. Exact timing uses a free cron-job.org account to start it on time."
      else
        'Available once GitHub is set up.'
      end
    @exact_btn.sensitive = active ? true : false
  end

  # GitHub was turned off: its cron-job.org job would only fail from now on, so remove it.
  def exact_off_after_github_stop
    key = secret_dialog('Remove exact timing',
                        'GitHub claiming is off, so cron-job.org\'s daily job isn\'t needed anymore. Paste your cron-job.org ' \
                        "API key so Chrono can delete it, or leave it empty and delete the \"#{ChronoCronJob::TITLE}\" job " \
                        'on cron-job.org yourself.', 'cron-job.org API key:',
                        link: ['Open cron-job.org settings', ChronoCronJob::KEY_PAGE], allow_empty: true)
    key = '' if key.nil?
    Rewards.exact_stop!(key.empty? ? nil : key)
    info_dialog("#{key.empty? ? "Delete the \"#{ChronoCronJob::TITLE}\" job on cron-job.org, and" : 'Done. Also'} delete the " \
                '"Chrono4Lich exact timing" token on GitHub: your picture (top right) > Settings > Developer settings > ' \
                'Personal access tokens > Fine-grained tokens.')
    reload_rewards
  end

  # Everything this computer has claimed (or tried to), newest first, by account.
  def rewards_history_dialog
    all = Rewards.history.sort_by { |h| -h['at'].to_i }
    d = Gtk::Dialog.new(title: 'Rewards history', parent: @win, flags: %i[modal destroy_with_parent])
    d.set_default_size(720, 480)
    d.add_button('Close', Gtk::ResponseType::CLOSE)
    box = Gtk::Box.new(:vertical, 8)
    box.margin = 10
    d.content_area.pack_start(box, expand: true, fill: true)

    claims = Rewards.last_coin_claims
    head = if claims.empty?
             'No SimuCoins claimed by this computer yet.'
           else
             'Last SimuCoins claimed: ' + claims.sort.map do |acct, h|
               "#{acct} #{Time.at(h['at']).strftime('%b %-d, %Y')}#{h['balance'].to_s.empty? ? '' : " (balance #{h['balance']})"}"
             end.join(';  ')
           end
    box.pack_start(wrapped_label(head), expand: false, fill: false)

    filter_row = Gtk::Box.new(:horizontal, 6)
    filter_row.pack_start(Gtk::Label.new('Show:'), expand: false, fill: false)
    filter = Gtk::ComboBoxText.new
    filter.append_text('All accounts')
    all.map { |h| h['account'] }.uniq.sort.each { |a| filter.append_text(a) }
    filter.active = 0
    filter_row.pack_start(filter, expand: false, fill: false)
    claimed_only = Gtk::CheckButton.new('Only claims and problems')
    filter_row.pack_start(claimed_only, expand: false, fill: false)
    box.pack_start(filter_row, expand: false, fill: false)

    # when, account, reward, result, weight
    store = Gtk::ListStore.new(String, String, String, String, Integer)
    view = Gtk::TreeView.new(store)
    [['When', 0], ['Account', 1], ['Reward', 2], ['Result', 3]].each do |title, col|
      c = Gtk::TreeViewColumn.new(title, Gtk::CellRendererText.new, text: col, weight: 4)
      c.resizable = true
      c.expand = true if col == 3
      view.append_column(c)
    end
    view.tooltip_column = 3
    sw = Gtk::ScrolledWindow.new
    sw.set_policy(:automatic, :automatic)
    sw.add(view)
    box.pack_start(sw, expand: true, fill: true)
    fill = lambda do
      store.clear
      acct = filter.active.zero? ? nil : filter.active_text
      all.each do |h|
        next if acct && h['account'] != acct
        important = h['status'] == 'claimed' || !h['ok']
        next if claimed_only.active? && !important

        it = store.append
        it[0] = Time.at(h['at']).strftime('%Y-%m-%d %H:%M')
        it[1] = h['account'].to_s
        it[2] = h['character'] ? "#{h['reward']}: #{h['character']}" : h['reward'].to_s
        it[3] = case h['status']
                when 'claimed' then "CLAIMED #{h['text']}#{h['balance'].to_s.empty? ? '' : " (balance #{h['balance']})"}"
                when 'not_due' then "not due yet: #{h['text']}"
                when 'error' then "FAILED: #{h['text']}"
                else h['text'].to_s
                end
        it[4] = important ? 700 : 400
      end
    end
    filter.signal_connect('changed') { fill.call }
    claimed_only.signal_connect('toggled') { fill.call }
    fill.call

    gh = Rewards.github_state
    if gh && gh['repo'] && !gh['stopped']
      note = Gtk::Box.new(:horizontal, 6)
      note.pack_start(wrapped_label("Accounts that claim on GitHub (#{Array(gh['accounts']).join(', ')}) aren't listed here: " \
                                    'GitHub keeps their results.'), expand: true, fill: true)
      b = Gtk::Button.new(label: 'Open results on GitHub')
      b.signal_connect('clicked') { open_url(ChronoGitHub.actions_url(gh['repo'])) }
      note.pack_start(b, expand: false, fill: false)
      box.pack_start(note, expand: false, fill: false)
    end
    d.show_all
    d.run
    d.destroy
  end

  def info_dialog(text)
    d = Gtk::MessageDialog.new(parent: @win, flags: :destroy_with_parent, type: :info,
                               buttons_type: :close, message: text)
    d.title = 'Chrono'
    d.run
    d.destroy
    nil
  end

  def bold_label(text)
    l = Gtk::Label.new
    l.set_markup("<b>#{text.gsub('&', '&amp;').gsub('<', '&lt;')}</b>")
    l.xalign = 0
    l
  end

  def wrapped_label(text)
    l = Gtk::Label.new(text)
    l.wrap = true
    l.xalign = 0
    l.max_width_chars = 60
    l
  end

  # Asks for one secret (an API key). Returns the text, or nil if cancelled.
  def secret_dialog(title, text, field, link: nil, allow_empty: false)
    d = Gtk::Dialog.new(title: title, parent: @win, flags: %i[modal destroy_with_parent])
    d.add_button('Cancel', Gtk::ResponseType::CANCEL)
    d.add_button('OK', Gtk::ResponseType::OK)
    box = Gtk::Box.new(:vertical, 8)
    box.margin = 14
    d.content_area.pack_start(box, expand: true, fill: true)
    box.pack_start(wrapped_label(text), expand: false, fill: false)
    if link
      b = Gtk::Button.new(label: link[0])
      b.signal_connect('clicked') { open_url(link[1]) }
      box.pack_start(b, expand: false, fill: false)
    end
    box.pack_start(wrapped_label(field), expand: false, fill: false)
    entry = password_entry
    entry.activates_default = true
    box.pack_start(entry, expand: false, fill: false)
    d.default_response = Gtk::ResponseType::OK
    d.show_all
    loop do
      return (d.destroy; nil) unless d.run == Gtk::ResponseType::OK
      value = entry.text.strip
      if value.empty? && !allow_empty
        error_dialog('Paste the key first.')
        next
      end
      d.destroy
      return value
    end
  end

  # Exact timing: set it up, move it after the claim time changed, or turn it off.
  def exact_dialog
    data = Rewards.load
    gh = Rewards.github_state(data)
    return error_dialog('Set up GitHub first (Claim on GitHub, then "Set up GitHub...").') unless gh && gh['repo'] && !gh['stopped']
    ex = Rewards.exact_state(data)
    key_link = ['Open cron-job.org settings', ChronoCronJob::KEY_PAGE]
    after_github = lambda do
      reload_rewards
      github_dialog(:sync, confirm: false) if Rewards.github_needs_update
    end

    if ex && Rewards.exact_token_expiring?(data)
      info_dialog("The GitHub token cron-job.org uses to start the run #{Rewards.exact_needs_update(data).sub(/\Athe GitHub token it uses /, '').sub(/; set.*/, '')}.\n\n" \
                  'Make a new one and set exact timing up again; the cron-job.org job is updated in place. ' \
                  'Afterwards, delete the old "Chrono4Lich exact timing" token on GitHub.')
      exact_setup_dialog(gh, after_github)
    elsif ex && Rewards.exact_needs_update(data)
      key = secret_dialog('Update exact timing',
                          "The claim time changed to #{data['time']}. Paste your cron-job.org API key so Chrono can " \
                          'move its job (cron-job.org > Settings > API).', 'cron-job.org API key:', link: key_link)
      return unless key
      in_background('Updating cron-job.org...',
                    done: ->(_) { append_log("Exact timing: cron-job.org now starts the run at #{Rewards.load['time']}."); after_github.call },
                    failed: ->(msg) { error_dialog("Exact timing wasn't updated:\n\n#{msg}") }) do
        Rewards.exact_update_time!(key)
      end
    elsif ex
      return unless confirm_dialog("Exact timing is on: cron-job.org starts the GitHub run at #{ex['time']}.\n\n" \
                                   'Turn it off? GitHub\'s own schedule then runs at the claim time again (you\'ll sign in ' \
                                   'to GitHub to update it).')
      key = secret_dialog('Turn off exact timing',
                          'Paste your cron-job.org API key so Chrono can delete its job. Or leave it empty and delete ' \
                          "the \"#{ChronoCronJob::TITLE}\" job on cron-job.org yourself.",
                          'cron-job.org API key:', link: key_link, allow_empty: true)
      return if key.nil?
      in_background('Turning off exact timing...',
                    done: lambda { |_|
                      append_log('Exact timing turned off.')
                      info_dialog("Exact timing is off.#{key.empty? ? "\n\nDelete the \"#{ChronoCronJob::TITLE}\" job on cron-job.org." : ''}\n\n" \
                                  'Also delete the "Chrono4Lich exact timing" token on GitHub: your picture (top right) > Settings > ' \
                                  'Developer settings > Personal access tokens > Fine-grained tokens.')
                      after_github.call
                    },
                    failed: ->(msg) { error_dialog("Exact timing wasn't turned off:\n\n#{msg}") }) do
        Rewards.exact_stop!(key.empty? ? nil : key)
      end
    else
      exact_setup_dialog(gh, after_github)
    end
  end

  def exact_setup_dialog(gh, after_github)
    d = Gtk::Dialog.new(title: 'Exact timing', parent: @win, flags: %i[modal destroy_with_parent])
    d.add_button('Cancel', Gtk::ResponseType::CANCEL)
    d.add_button('Set up', Gtk::ResponseType::OK)
    box = Gtk::Box.new(:vertical, 8)
    box.margin = 14
    d.content_area.pack_start(box, expand: true, fill: true)
    box.pack_start(wrapped_label(
      'GitHub\'s own timer often starts runs late, sometimes by hours. With exact timing, a free cron-job.org ' \
      "account starts the run at #{Rewards.load['time']} every day, and GitHub's own schedule stays on as a backup " \
      "#{ChronoGitHub::BACKUP_DELAY / 3600} hours later (it only claims if that day's run didn't succeed). " \
      'Chrono doesn\'t keep the token or the key.'
    ), expand: false, fill: false)

    box.pack_start(bold_label('1. A GitHub token that can only start runs'), expand: false, fill: false)
    box.pack_start(wrapped_label(
      'Click the button: GitHub opens its token page with the name, expiry and permission filled in. ' \
      'GitHub can\'t fill in one setting, so do this yourself:'
    ), expand: false, fill: false)
    must = Gtk::Label.new
    must.set_markup("<b>Under \"Repository access\", choose \"Only select repositories\" and pick only " \
                    "#{ChronoGitHub::REPO_NAME}.</b> Not \"All repositories\".")
    must.wrap = true
    must.xalign = 0
    must.max_width_chars = 60
    box.pack_start(must, expand: false, fill: false)
    box.pack_start(wrapped_label('Then click "Generate token" and copy the token (it starts with github_pat_).'),
                   expand: false, fill: false)
    tb = Gtk::Button.new(label: "Open GitHub's token page")
    tb.signal_connect('clicked') { open_url(ChronoGitHub.run_token_url) }
    box.pack_start(tb, expand: false, fill: false)
    token = password_entry
    token.placeholder_text = 'Paste the GitHub token here'
    box.pack_start(token, expand: false, fill: false)

    box.pack_start(bold_label('2. A cron-job.org API key'), expand: false, fill: false)
    box.pack_start(wrapped_label(
      'Make a free account at cron-job.org (or sign in). Open Settings, create an API key, and copy it.'
    ), expand: false, fill: false)
    kb = Gtk::Button.new(label: 'Open cron-job.org')
    kb.signal_connect('clicked') { open_url(ChronoCronJob::KEY_PAGE) }
    box.pack_start(kb, expand: false, fill: false)
    key = password_entry
    key.placeholder_text = 'Paste the cron-job.org API key here'
    box.pack_start(key, expand: false, fill: false)
    box.pack_start(wrapped_label(
      'After this, Chrono asks you to sign in to GitHub once more, to make GitHub\'s own schedule the backup.'
    ), expand: false, fill: false)
    d.show_all

    loop do
      return d.destroy unless d.run == Gtk::ResponseType::OK
      t = token.text.strip
      k = key.text.strip
      if t.empty? || k.empty?
        error_dialog('Paste both the GitHub token and the cron-job.org API key.')
        next
      end
      d.destroy
      exact_finish_setup(k, t, after_github)
      return
    end
  end

  def exact_finish_setup(k, t, after_github)
    in_background('Setting up exact timing...',
                  done: lambda { |_|
                    ex = Rewards.exact_state
                    append_log("Exact timing on: cron-job.org starts the run at #{ex['time']} (#{ex['tz']}).")
                    after_github.call
                  },
                  failed: ->(msg) { error_dialog("Exact timing wasn't set up:\n\n#{msg}") }) do
      Rewards.exact_setup!(k, t)
    end
  end

  # Opens a web page in the browser. Only https addresses: the Windows way of opening a link also
  # runs files, so nothing else is ever passed to it.
  def open_url(url)
    url = url.to_s
    unless url.match?(%r{\Ahttps://[^\s"'<>`]+\z}i) || (ENV['CHRONO_DEV'] == '1' && url.start_with?('http://127.0.0.1'))
      gui_log("Not opening #{url[0, 100].inspect}: not an https address")
      return error_dialog("Chrono only opens https web addresses, and this one isn't:\n\n#{url[0, 200]}")
    end
    cmd = if Gem.win_platform? then ['rundll32', 'url.dll,FileProtocolHandler', url]
          elsif ChronoConfig.mac? then ['open', url]
          else ['xdg-open', url]
          end
    Process.detach(Process.spawn(*cmd, in: File::NULL, out: File::NULL, err: File::NULL))
  rescue SystemCallError => e
    error_dialog("Couldn't open the browser (#{e.message}). Open this address yourself:\n\n#{url}")
  end

  # Signs in to GitHub with a code, then sets up/updates (:sync) or turns off (:stop) GitHub claiming.
  # The sign-in is used for this one job and forgotten.
  def github_dialog(purpose, confirm: true)
    data = Rewards.load
    if purpose == :sync
      wanted = Rewards.github_accounts(data)
      return error_dialog('Tick "Claim on GitHub" for at least one account first.') if wanted.empty?
      return unless !confirm || confirm_dialog(
        "This stores the Simutronics logins for #{wanted.map { |a| a[:name] }.join(', ')} as encrypted secrets in a " \
        "private repository on your GitHub account (#{ChronoGitHub::REPO_NAME}), and claims rewards there every day " \
        "at about #{data['time']}.\n\nOnly GitHub can decrypt them, to run the claim. #{ChronoGitHub::ACTION_NOTICE}\n\n" \
        'Chrono doesn\'t keep the GitHub sign-in; you\'ll sign in again only when changing something. ' \
        "You can withdraw Chrono's GitHub access any time at #{ChronoGitHub::REVOKE_URL}"
      )
    else
      gh = Rewards.github_state(data)
      return error_dialog('GitHub was never set up from this computer.') unless gh && gh['repo']
      return unless confirm_dialog("Turn off the daily run in github.com/#{gh['repo']} and delete the logins stored there?\n\n" \
                                   'Your accounts go back to being claimed on this computer.')
    end

    d = Gtk::Dialog.new(title: 'Sign in to GitHub', parent: @win, flags: %i[modal destroy_with_parent])
    d.set_default_size(460, 340)
    close_btn = d.add_button('Cancel', Gtk::ResponseType::CANCEL)
    box = Gtk::Box.new(:vertical, 10)
    box.margin = 14
    d.content_area.pack_start(box, expand: true, fill: true)
    intro = Gtk::Label.new('Contacting GitHub...')
    intro.wrap = true
    intro.xalign = 0
    code = Gtk::Label.new('')
    code.selectable = true
    after = Gtk::Label.new('')
    after.wrap = true
    after.xalign = 0
    open_btn = Gtk::Button.new(label: 'Open the GitHub page again')
    open_btn.no_show_all = true
    steps = Gtk::Label.new('')
    steps.xalign = 0
    steps.yalign = 0
    steps.wrap = true
    [intro, code, after, open_btn, steps].each { |w| box.pack_start(w, expand: false, fill: false) }

    queue = Queue.new
    cancelled = false
    finished = false
    closed = false
    device = nil
    open_btn.signal_connect('clicked') { open_url(device[:verification_uri]) if device }
    d.signal_connect('response') do
      unless finished
        cancelled = true # the background sign-in notices and stops
        set_busy(false, 'Ready.')
      end
      closed = true
      d.destroy
    end
    d.show_all
    set_busy(true, 'Signing in to GitHub...')

    Thread.new do
      dev = ChronoGitHub.start_sign_in
      queue << [:code, dev]
      token = ChronoGitHub.wait_for_token(dev, cancelled: -> { cancelled })
      queue << [:step, 'Signed in.']
      if purpose == :sync
        Rewards.github_sync!(token, progress: ->(line) { queue << [:step, line] })
      else
        Rewards.github_stop!(token)
        queue << [:step, 'Turned off the daily run and deleted the stored logins.']
      end
      queue << [:done]
    rescue Fail, ChronoGitHub::Error, ChronoEAccess::Error => e
      queue << [:error, e.message]
    rescue StandardError => e
      gui_log("UNEXPECTED ERROR: #{e.class}: #{e.message}\n    #{e.backtrace.first(5).join("\n    ")}")
      queue << [:error, "Unexpected error: #{e.class}: #{e.message}"]
    end

    lines = []
    GLib::Timeout.add(200) do
      until queue.empty?
        kind, val = queue.pop
        case kind
        when :code
          device = val
          intro.text = 'On the GitHub page that just opened, enter this code:'
          after.text = "Then click Authorize to approve Chrono4Lich.\n(The code is already copied, so you can paste it.)"
          code.set_markup("<span size='xx-large' weight='bold' font_family='monospace'>#{val[:user_code]}</span>")
          open_btn.show
          begin
            Gtk::Clipboard.get(Gdk::Selection::CLIPBOARD).text = val[:user_code]
          rescue StandardError
            nil # copying is a convenience
          end
          open_url(val[:verification_uri])
        when :step
          lines << val
          steps.text = lines.join("\n")
          intro.text = 'Working on GitHub...'
          code.text = ''
          after.text = ''
          open_btn.hide
        when :done, :error
          finished = true
          set_busy(false, 'Ready.')
          if kind == :done
            intro.text = purpose == :sync ? 'GitHub is set up.' : 'GitHub claiming is off.'
            after.text = "Chrono doesn't keep the GitHub sign-in. To withdraw its access to your GitHub " \
                         "account, use #{ChronoGitHub::REVOKE_URL}"
            append_log(purpose == :sync ? "GitHub set up: #{lines.last}" : 'GitHub claiming turned off.')
          else
            intro.text = "That didn't work:\n#{val}"
            append_log("!!! GitHub: #{val}")
          end
          close_btn.label = 'Close'
          safely { reload_rewards }
          if kind == :done && purpose == :stop && Rewards.exact_state
            GLib::Idle.add { safely { exact_off_after_github_stop }; false }
          end
        end
      end
      !finished && !closed
    end
  rescue StandardError
    set_busy(false, 'Ready.')
    raise
  end

  def save_rewards_schedule
    on = @rewards_on.active?
    time = @rewards_time.call
    in_background('Saving the rewards schedule...',
                  done: lambda { |_|
                    append_log(on ? "Daily rewards on, every day at #{time}." : 'Daily rewards off.')
                    reload_rewards
                  },
                  failed: ->(msg) { error_dialog("The rewards schedule wasn't saved:\n\n#{msg}") }) do
      Rewards.set_schedule(on, time)
    end
  end

  # ---------- logins tab ----------

  def build_logins_page
    page = Gtk::Box.new(:vertical, 8)
    page.margin = 6

    @logins_info = Gtk::Label.new('')
    @logins_info.xalign = 0
    @logins_info.wrap = true
    page.pack_start(@logins_info, expand: false, fill: false)

    # Like Lich's account manager: each account is a row that opens to show its characters.
    # label, realm, frontend, account, character, game_code, weight (bold for accounts)
    @logins_store = Gtk::TreeStore.new(String, String, String, String, String, String, Integer)
    @logins_view = Gtk::TreeView.new(@logins_store)
    name_cell = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new('Account / Character', name_cell, text: 0, weight: 6)
    col.resizable = true
    col.expand = true
    @logins_view.append_column(col)
    col = Gtk::TreeViewColumn.new('Realm', Gtk::CellRendererText.new, text: 1)
    col.resizable = true
    @logins_view.append_column(col)
    @logins_view.append_column(frontend_choice_column)
    # one click on an account opens or closes its characters
    @logins_view.activate_on_single_click = true
    @logins_view.signal_connect('row-activated') do |view, path, _col|
      it = @logins_store.get_iter(path)
      next unless it && it[4].to_s.empty?

      view.row_expanded?(path) ? view.collapse_row(path) : view.expand_row(path, false)
    end
    @logins_view.signal_connect('row-expanded') { |_, it, _| (@logins_open ||= {})[it[3].downcase] = true }
    @logins_view.signal_connect('row-collapsed') { |_, it, _| (@logins_open ||= {}).delete(it[3].downcase) }
    scroll = Gtk::ScrolledWindow.new
    scroll.set_policy(:automatic, :automatic)
    scroll.add(@logins_view)
    page.pack_start(scroll, expand: true, fill: true)

    row = Gtk::Box.new(:horizontal, 6)
    add_btn  = button('Add account...') { add_logins_dialog }
    more_btn = button('Add characters...') { add_logins_dialog(selected_login_account) }
    edit_btn = button('Edit...') { edit_login_dialog }
    pw_btn   = button('Change password...') { change_password_dialog }
    rm_btn   = button('Remove...') { remove_selected_login }
    @action_buttons.push(add_btn, more_btn, edit_btn, pw_btn, rm_btn)
    [add_btn, more_btn, edit_btn, pw_btn].each { |b| row.pack_start(b, expand: false, fill: false) }
    row.pack_end(rm_btn, expand: false, fill: false)
    row.pack_end(button('Refresh') { safely { reload_logins } }, expand: false, fill: false)
    page.pack_start(row, expand: false, fill: false)

    logs_row = Gtk::Box.new(:horizontal, 6)
    logs_row.pack_start(button('Open frontend logs') { safely { open_frontend_logs } }, expand: false, fill: false)
    page.pack_start(logs_row, expand: false, fill: false)


    note = Gtk::Label.new('These are the same saved logins Lich uses. Close Lich\'s login window before ' \
                          'changing them here, or saving something in that window may undo the change. ' \
                          'Passwords are checked with Simutronics before they\'re saved, and never shown or logged.')
    note.wrap = true
    note.xalign = 0
    page.pack_start(note, expand: false, fill: false)

    safely { reload_logins }
    page
  end

  # Which file a Lich folder keeps its saved logins in, e.g. "entry.yaml (passwords: plaintext), Lich 5.24.1".
  def saved_logins_kind
    kind =
      if SavedLogins.backend == :yaml
        mode = (File.exist?(SavedLogins.yaml_file) && SavedLogins.load_yaml['encryption_mode']) || 'plaintext'
        "entry.yaml (passwords: #{mode})"
      else
        'entry.dat'
      end
    ver = SavedLogins.lich_version
    "#{kind}#{ver ? ", Lich #{ver}" : ''}"
  end

  def reload_logins
    @logins_store.clear
    text = "Saved logins are in #{saved_logins_kind} in #{ChronoConfig.disp(LICH_DIR)}."
    if DR_LICH_DIR && DR_LICH_DIR != LICH_DIR
      text = "GemStone logins are in #{saved_logins_kind} in #{ChronoConfig.disp(LICH_DIR)}.\nDragonRealms logins are in " \
             "#{SavedLogins.in_folder(DR_LICH_DIR) { saved_logins_kind }} in #{ChronoConfig.disp(DR_LICH_DIR)}."
    end
    @logins_info.text = text
    return unless SavedLogins.any_saved?

    open = (@logins_open ||= {})
    SavedLogins.entries.group_by { |e| e[:user_id].to_s }
               .sort_by { |acct, _| acct.downcase }.each do |acct, list|
      a = @logins_store.append(nil)
      chars = list.map { |e| e[:char_name].to_s.downcase }.uniq.size
      a[0] = "#{acct}   (#{chars} character#{chars == 1 ? '' : 's'})"
      a[1] = ''
      a[2] = ''
      a[3] = acct
      a[4] = ''
      a[5] = ''
      a[6] = 700
      list.sort_by { |e| [*game_order(e), e[:frontend].to_s] }.each do |e|
        c = @logins_store.append(a)
        c[0] = e[:char_name].to_s
        c[1] = realm_of(e)
        c[2] = e[:frontend].to_s
        c[3] = acct
        c[4] = e[:char_name].to_s
        c[5] = e[:game_code].to_s
        c[6] = 400
      end
      @logins_view.expand_row(a.path, false) if open[acct.downcase]
    end
  end

  # Logins changed: every list that shows characters needs refreshing.
  def logins_changed
    reload_logins
    reload_characters
    refresh_status
    reload_rewards # its accounts come from the saved logins
  end

  # Runs slow work (network, Lich commands) off the window's thread. The window stays
  # responsive; done/failed are called back on the window's thread.
  def in_background(status_text, done:, failed:)
    set_busy(true, status_text)
    result = nil
    error = nil
    worker = Thread.new do
      result = yield
    rescue *ChronoWindow.app_errors => e
      error = e.message
    rescue StandardError => e
      gui_log("UNEXPECTED ERROR: #{e.class}: #{e.message}\n    #{e.backtrace.first(5).join("\n    ")}")
      error = "Unexpected error: #{e.class}: #{e.message}"
    end
    GLib::Timeout.add(150) do
      next true if worker.alive?
      set_busy(false, 'Ready.')
      safely { error ? failed.call(error) : done.call(result) }
      false
    end
  end

  def password_entry
    e = Gtk::Entry.new
    e.visibility = false
    e.input_purpose = :password
    e
  end

  # prefill: an account to add characters to (its name is filled in; the password is still
  # needed, to look up its characters with Simutronics)
  def add_logins_dialog(prefill = nil)
    d = Gtk::Dialog.new(title: prefill ? "Add characters to #{prefill}" : 'Add account',
                        parent: @win, flags: %i[modal destroy_with_parent])
    d.set_default_size(480, 460)
    d.add_button('Cancel', Gtk::ResponseType::CANCEL)
    save = d.add_button('Save', Gtk::ResponseType::OK)
    save.sensitive = false

    grid = Gtk::Grid.new
    grid.row_spacing = 8
    grid.column_spacing = 10
    grid.margin = 10
    d.content_area.pack_start(grid, expand: true, fill: true)
    label = lambda do |t|
      l = Gtk::Label.new(t)
      l.xalign = 0
      l
    end

    account = Gtk::Entry.new
    account.hexpand = true
    account.text = prefill.to_s
    password = password_entry
    grid.attach(label.call('Account:'), 0, 0, 1, 1)
    grid.attach(account, 1, 0, 1, 1)
    grid.attach(label.call('Password:'), 0, 1, 1, 1)
    grid.attach(password, 1, 1, 1, 1)
    lookup = Gtk::Button.new(label: 'Look up characters')
    grid.attach(lookup, 1, 2, 1, 1)
    status = label.call('Enter the account and password, then look up its characters.')
    status.wrap = true
    grid.attach(status, 0, 3, 2, 1)

    store = Gtk::ListStore.new(TrueClass, String, String, String, String) # pick, name, realm, note, game_code
    view = Gtk::TreeView.new(store)
    toggle = Gtk::CellRendererToggle.new
    toggle.signal_connect('toggled') do |_, path|
      it = store.get_iter(path)
      it[0] = !it[0]
    end
    view.append_column(Gtk::TreeViewColumn.new('', toggle, active: 0))
    [['Character', 1], ['Realm', 2], ['', 3]].each do |t, c|
      view.append_column(Gtk::TreeViewColumn.new(t, Gtk::CellRendererText.new, text: c))
    end
    sc = Gtk::ScrolledWindow.new
    sc.set_policy(:automatic, :automatic)
    sc.vexpand = true
    sc.add(view)
    grid.attach(sc, 0, 4, 2, 1)

    frontend = Gtk::ComboBoxText.new
    fronts = SavedLogins.frontends
    fronts.each { |f| frontend.append_text(f) }
    # start on the frontend most of the saved logins use
    usual = (SavedLogins.entries rescue []).map { |e| e[:frontend].to_s }.tally.max_by { |_, n| n }&.first
    frontend.active = fronts.index(usual) || 0
    grid.attach(label.call('Frontend:'), 0, 5, 1, 1)
    grid.attach(frontend, 1, 5, 1, 1)

    # Warlock: Lich starts it with a launch command saved with the login. Filled in from a login
    # that already uses Warlock, or Lich's own preset; editable if Warlock is somewhere else.
    warlock_cmd_label = label.call('Warlock command:')
    warlock_cmd = Gtk::Entry.new
    warlock_cmd.hexpand = true
    default_cmd = (SavedLogins.warlock_launch.first rescue '').to_s
    warlock_cmd.text = SavedLogins.with_maximized(default_cmd, false)
    warlock_note = label.call('Lich runs this to start Warlock (%port% and %key% are filled in by Lich). ' \
                              'If Warlock isn\'t found when you log in, put the full path to Warlock here, ' \
                              'in quotes if it has spaces.')
    warlock_note.wrap = true
    warlock_bits = [warlock_cmd_label, warlock_cmd, warlock_note]
    warlock_bits.each { |w| w.no_show_all = true }
    grid.attach(warlock_cmd_label, 0, 6, 1, 1)
    grid.attach(warlock_cmd, 1, 6, 1, 1)
    grid.attach(warlock_note, 0, 7, 2, 1)
    show_warlock = lambda do
      on = frontend.active_text == SavedLogins::WARLOCK
      warlock_bits.each { |w| on ? w.show : w.hide }
    end
    frontend.signal_connect('changed') { show_warlock.call }

    found = []
    checked_with = nil # [account, password] the list was looked up with
    closed = false     # the dialog was closed while a lookup was still running
    d.signal_connect('destroy') { closed = true }
    lookup.signal_connect('clicked') do
      safely do
        acct = account.text.strip
        pw = password.text
        lookup.sensitive = false
        save.sensitive = false
        status.text = 'Asking Simutronics for the characters on this account...'
        in_background('Looking up characters...',
                      done: lambda { |chars|
                        next if closed
                        lookup.sensitive = true
                        found = chars
                        checked_with = [acct, pw]
                        saved = (SavedLogins.entries rescue [])
                        store.clear
                        chars.each do |c|
                          already = saved.any? { |e| e[:char_name].casecmp?(c[:char_name]) && e[:game_code] == c[:game_code] }
                          it = store.append
                          it[0] = !already
                          it[1] = c[:char_name]
                          it[2] = GAME_TO_REALM[c[:game_code]] || c[:game_code]
                          it[3] = already ? 'already saved' : ''
                          it[4] = c[:game_code]
                        end
                        status.text = chars.empty? ? 'This account has no GemStone or DragonRealms characters in a game it\'s subscribed to.' :
                                                     'Password confirmed. Tick the characters to save.'
                        save.sensitive = !chars.empty?
                      },
                      failed: lambda { |msg|
                        next if closed
                        lookup.sensitive = true
                        status.text = msg
                      }) { ChronoEAccess.list_characters(acct, pw, data_dir: DATA_DIR, codes: ChronoEAccess::ALL_CODES) }
      end
    end
    # changing the account or password means the list must be looked up again
    [account, password].each { |w| w.signal_connect('changed') { save.sensitive = false } }
    password.signal_connect('activate') { lookup.clicked if lookup.sensitive? }

    d.show_all
    show_warlock.call
    loop do
      break unless d.run == Gtk::ResponseType::OK
      picks = []
      store.each { |_m, _p, it| picks << found.find { |c| c[:char_name] == it[1] && c[:game_code] == it[4] } if it[0] }
      if picks.empty?
        error_dialog('Tick at least one character.')
        next
      end
      acct, pw = checked_with
      fe = frontend.active_text
      launch = fe == SavedLogins::WARLOCK ? warlock_cmd.text.strip : nil
      if launch && !(launch.include?('%port%') && launch.include?('%key%') && SavedLogins.warlock_launch?(launch))
        error_dialog("The Warlock command must mention warlock and include %port% and %key%, for example:\n\n" \
                     "warlock --host localhost --port %port% --key %key%")
        next
      end
      d.destroy
      in_background("Saving logins for #{acct}...",
                    done: lambda { |n|
                      append_log("Saved #{n} login(s) for account #{acct} (frontend #{fe}).")
                      logins_changed
                    },
                    failed: ->(msg) { error_dialog("The logins weren't saved:\n\n#{msg}") }) do
        SavedLogins.add(acct, pw, picks, fe, launch: launch)
      end
      return
    end
    d.destroy
  end

  def change_password_dialog
    accounts = SavedLogins.entries.map { |e| e[:user_id] }.uniq { |a| a.downcase }.sort
    return error_dialog('There are no saved logins yet. Use "Add logins..." first.') if accounts.empty?

    d = Gtk::Dialog.new(title: 'Change password', parent: @win, flags: %i[modal destroy_with_parent])
    d.add_button('Cancel', Gtk::ResponseType::CANCEL)
    d.add_button('Check and save', Gtk::ResponseType::OK)
    grid = Gtk::Grid.new
    grid.row_spacing = 8
    grid.column_spacing = 10
    grid.margin = 10
    d.content_area.pack_start(grid, expand: true, fill: true)

    combo = Gtk::ComboBoxText.new
    accounts.each { |a| combo.append_text(a) }
    sel = @logins_view.selection.selected
    combo.active = [accounts.index { |a| sel && a.casecmp?(sel[3].to_s) } || 0, 0].max
    pw = password_entry
    pw.hexpand = true
    grid.attach(Gtk::Label.new('Account:'), 0, 0, 1, 1)
    grid.attach(combo, 1, 0, 1, 1)
    grid.attach(Gtk::Label.new('New password:'), 0, 1, 1, 1)
    grid.attach(pw, 1, 1, 1, 1)
    hint = Gtk::Label.new('Use this after changing your password on play.net. The new password is checked ' \
                          'with Simutronics first, then saved for every character on the account.')
    hint.wrap = true
    hint.xalign = 0
    grid.attach(hint, 0, 2, 2, 1)
    d.show_all
    ok = d.run == Gtk::ResponseType::OK
    acct = combo.active_text
    new_pw = pw.text
    d.destroy
    return unless ok

    in_background("Checking the new password for #{acct}...",
                  done: ->(_) { append_log("Saved the new password for account #{acct}.") },
                  failed: ->(msg) { error_dialog("The password wasn't changed:\n\n#{msg}") }) do
      ChronoEAccess.list_characters(acct, new_pw, data_dir: DATA_DIR)
      SavedLogins.change_password(acct, new_pw)
    end
  end

  # The account of the selected row (an account row, or a character's account), or nil.
  def selected_login_account
    it = @logins_view.selection.selected
    it && it[3]
  end

  # The folders a frontend usually keeps its game logs in, most likely first. Saga's comes from
  # its own settings; Warlock's is checked on a Mac, and elsewhere follows the folder library it
  # uses. Chrono doesn't know the others'.
  def frontend_log_folders(frontend)
    home = Dir.home
    case frontend.to_s.downcase
    when 'saga' then [SagaPrefs.logs_dir]
    when SavedLogins::WARLOCK
      if ChronoConfig.mac?
        [File.join(home, 'Library', 'Logs', 'WarlockFE warlock'), File.join(home, 'Library', 'Logs', 'WarlockFE')]
      elsif ChronoConfig.windows?
        local = ENV['LOCALAPPDATA'] || File.join(home, 'AppData', 'Local')
        [File.join(local, 'warlock', 'WarlockFE', 'Logs'), File.join(local, 'WarlockFE warlock', 'Logs'),
         File.join(local, 'WarlockFE', 'Logs')]
      else
        [File.join(ENV['XDG_STATE_HOME'] || File.join(home, '.local', 'state'), 'WarlockFE'),
         File.join(ENV['XDG_CACHE_HOME'] || File.join(home, '.cache'), 'WarlockFE', 'logs')]
      end
    else []
    end
  end

  # Opens the game-log folder of the selected login's frontend (with nothing selected, or an
  # account, the frontend its logins all use).
  def open_frontend_logs
    it = @logins_view.selection.selected
    entries = SavedLogins.entries
    fronts =
      if it && !it[4].to_s.empty? then [it[2].to_s]
      elsif it then entries.select { |e| e[:user_id].to_s.casecmp?(it[3].to_s) }.map { |e| e[:frontend].to_s }
      else entries.map { |e| e[:frontend].to_s }
      end.uniq
    return error_dialog('No saved logins yet.') if fronts.empty?
    return error_dialog('These logins use different frontends. Click a character first.') if fronts.size > 1

    fe = fronts.first
    name = fe.capitalize
    places = frontend_log_folders(fe)
    return error_dialog("Chrono doesn't know where #{name} keeps its logs.") if places.empty?

    dir = places.find { |d| File.directory?(d) }
    unless dir
      return error_dialog("Didn't find #{name}'s log folder. Looked in:\n\n" +
                          places.map { |d| ChronoConfig.disp(d) }.join("\n"))
    end
    open_folder(dir)
    append_log("Opened #{name}'s logs: #{ChronoConfig.disp(dir)}")
  end

  # The Frontend column: on a character row, click it for a dropdown of frontends (like Lich's).
  def frontend_choice_column
    choices = Gtk::ListStore.new(String)
    (SavedLogins.frontends rescue %w[stormfront wizard]).each { |f| choices.append[0] = f }
    cell = Gtk::CellRendererCombo.new
    cell.model = choices
    cell.text_column = 0
    cell.has_entry = false
    col = Gtk::TreeViewColumn.new('Frontend', cell, text: 2)
    col.resizable = true
    col.set_cell_data_func(cell) { |_c, r, _m, it| r.editable = !it[4].to_s.empty? }
    cell.signal_connect('edited') do |_, path, new_text|
      safely do
        it = @logins_store.get_iter(path)
        next unless it && !it[4].to_s.empty? && !new_text.to_s.empty? && new_text != it[2]

        acct, name, code, from = it[3], it[4], it[5], it[2]
        in_background("Changing #{name}'s frontend...",
                      done: lambda { |_|
                        append_log("#{name} (#{acct}) now uses #{new_text}#{new_text == SavedLogins::WARLOCK ? " (#{SavedLogins.warlock_launch.first})" : ''}.")
                        logins_changed
                      },
                      failed: ->(msg) { error_dialog("#{name}'s frontend wasn't changed:\n\n#{msg}") }) do
          SavedLogins.set_frontend(acct, name, code, from, new_text)
        end
      end
    end
    col
  end

  # The Characters tab's Frontend column: pick another frontend from its dropdown, as on the
  # Logins tab. It changes the saved login this character logs in with.
  def character_frontend_column
    choices = Gtk::ListStore.new(String)
    (SavedLogins.frontends rescue %w[stormfront wizard]).each { |f| choices.append[0] = f }
    cell = Gtk::CellRendererCombo.new
    cell.model = choices
    cell.text_column = 0
    cell.has_entry = false
    cell.editable = true
    col = Gtk::TreeViewColumn.new('Frontend', cell, text: COL_FRONTEND)
    col.resizable = true
    col.sort_column_id = COL_FRONTEND
    cell.signal_connect('edited') do |_, path, new_text|
      safely do
        it = @store.get_iter(path)
        next unless it && !new_text.to_s.empty? && new_text != it[COL_FRONTEND]

        acct, name, code, from, spec = it[COL_ACCOUNT], it[COL_NAME], it[COL_CODE], it[COL_FRONTEND], it[COL_SPEC]
        in_background("Changing #{name}'s frontend...",
                      done: lambda { |_|
                        on = (online?(who_from_spec(spec)) rescue false)
                        note = on ? ' It takes effect the next time it logs in.' : ''
                        append_log("#{name} (#{acct}) now uses #{new_text}#{new_text == SavedLogins::WARLOCK ? " (#{SavedLogins.warlock_launch.first})" : ''}.#{note}")
                        logins_changed
                      },
                      failed: ->(msg) { error_dialog("#{name}'s frontend wasn't changed:\n\n#{msg}") }) do
          SavedLogins.set_frontend(acct, name, code, from, new_text)
        end
      end
    end
    col
  end

  # Edit a saved character login: its frontend and, for Warlock, the launch command.
  def edit_login_dialog
    it = @logins_view.selection.selected
    return error_dialog('Click a character in the list first (open an account to see its characters).') unless it && !it[4].to_s.empty?

    acct, name, code, from, realm = it[3], it[4], it[5], it[2], it[1]
    entry = SavedLogins.entries.find do |e|
      e[:char_name].to_s.casecmp?(name) && e[:game_code] == code && e[:user_id].to_s.casecmp?(acct) && e[:frontend] == from
    end
    return error_dialog("#{name} isn't saved anymore. Click Refresh.") unless entry

    d = Gtk::Dialog.new(title: "Edit #{name}", parent: @win, flags: %i[modal destroy_with_parent])
    d.add_button('Cancel', Gtk::ResponseType::CANCEL)
    d.add_button('Save', Gtk::ResponseType::OK)
    grid = Gtk::Grid.new
    grid.row_spacing = 8
    grid.column_spacing = 10
    grid.margin = 14
    d.content_area.pack_start(grid, expand: true, fill: true)
    lab = ->(t) { l = Gtk::Label.new(t); l.xalign = 0; l }
    grid.attach(lab.call('Character:'), 0, 0, 1, 1)
    grid.attach(lab.call("#{name}  (#{realm}, account #{acct})"), 1, 0, 1, 1)

    frontend = Gtk::ComboBoxText.new
    choices = SavedLogins.frontends
    choices.each { |f| frontend.append_text(f) }
    frontend.active = choices.index(from) || 0
    grid.attach(lab.call('Frontend:'), 0, 1, 1, 1)
    grid.attach(frontend, 1, 1, 1, 1)

    current = entry[:frontend] == SavedLogins::WARLOCK ? entry[:custom_launch].to_s : SavedLogins.warlock_launch.first
    cmd_label = lab.call('Warlock command:')
    cmd = Gtk::Entry.new
    cmd.hexpand = true
    cmd.width_chars = 50
    cmd.text = SavedLogins.with_maximized(current, false)
    warlock_bits = [cmd_label, cmd]
    warlock_bits.each { |w| w.no_show_all = true }
    grid.attach(cmd_label, 0, 2, 1, 1)
    grid.attach(cmd, 1, 2, 1, 1)
    show = lambda do
      on = frontend.active_text == SavedLogins::WARLOCK
      warlock_bits.each do |w|
        w.no_show_all = false if on # (show_all skips a widget marked no_show_all)
        on ? w.show_all : w.hide
      end
    end
    frontend.signal_connect('changed') { show.call }
    d.show_all
    show.call

    loop do
      return d.destroy unless d.run == Gtk::ResponseType::OK

      to = frontend.active_text
      launch = nil
      if to == SavedLogins::WARLOCK
        base = cmd.text.strip
        unless base.include?('%port%') && base.include?('%key%') && SavedLogins.warlock_launch?(base)
          error_dialog("The Warlock command must mention warlock and include %port% and %key%, for example:\n\n" \
                       'warlock --host localhost --port %port% --key %key%')
          next
        end
        launch = base
      end
      d.destroy
      in_background("Saving #{name}...",
                    done: lambda { |_|
                      append_log("#{name}: saved with #{to}.")
                      logins_changed
                    },
                    failed: ->(msg) { error_dialog("#{name} wasn't changed:\n\n#{msg}") }) do
        SavedLogins.edit_login(acct, name, code, from, to, launch: launch)
      end
      return
    end
  end

  def remove_selected_login
    it = @logins_view.selection.selected
    return error_dialog('Click an account or a character in the list first.') unless it

    acct = it[3]
    if it[4].to_s.empty?
      remove_login_account(acct)
    else
      name, code, fe, realm = it[4], it[5], it[2], it[1]
      others = SavedLogins.entries.count do |e|
        e[:char_name].to_s.casecmp?(name) && e[:game_code] == code && e[:user_id].to_s.casecmp?(acct)
      end
      # the last saved login for this character: it can't be in a schedule or online
      check_removable!({ char_name: name, game_code: code, user_id: acct }) if others <= 1
      return unless confirm_dialog("Remove the saved login for #{name} (#{realm}, #{fe}, account #{acct})?\n\n" \
                                   'This only removes it from your saved logins. Nothing changes on your account.')
      in_background("Removing #{name}...",
                    done: lambda { |_|
                      append_log("Removed the saved login for #{name} (#{realm}, #{fe}).")
                      logins_changed
                    },
                    failed: ->(msg) { error_dialog("#{name} wasn't removed:\n\n#{msg}") }) do
        SavedLogins.remove(name, code, acct, frontend: fe)
      end
    end
  end

  def remove_login_account(acct)
    list = SavedLogins.entries.select { |e| e[:user_id].to_s.casecmp?(acct) }
    list.uniq { |e| [e[:char_name].to_s.downcase, e[:game_code]] }.each { |e| check_removable!(e) }
    names = list.map { |e| e[:char_name] }.uniq
    return unless confirm_dialog("Remove account #{acct} and all its saved characters (#{names.join(', ')})?\n\n" \
                                 'This only removes them from your saved logins. Nothing changes on your account. ' \
                                 'Its reward settings in Chrono are kept in case you add it back.')
    in_background("Removing #{acct}...",
                  done: lambda { |_|
                    append_log("Removed account #{acct} and its saved characters.")
                    (@logins_open ||= {}).delete(acct.downcase)
                    logins_changed
                  },
                  failed: ->(msg) { error_dialog("#{acct} wasn't removed:\n\n#{msg}") }) do
      SavedLogins.remove_account(acct)
    end
  end

  def build_settings_page
    page = Gtk::Box.new(:vertical, 10)
    page.margin = 10
    info = lambda do |title, value|
      row = Gtk::Box.new(:vertical, 2)
      t = Gtk::Label.new
      escaped = title.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      t.set_markup("<b>#{escaped}</b>")
      t.xalign = 0
      v = Gtk::Label.new(value)
      v.xalign = 0
      v.selectable = true
      v.wrap = true
      row.pack_start(t, expand: false, fill: false)
      row.pack_start(v, expand: false, fill: false)
      page.pack_start(row, expand: false, fill: false)
    end

    info.call('Appearance', 'Light or dark, and how big the text is. Changes apply right away.')
    looks = Gtk::Box.new(:horizontal, 6)
    looks.pack_start(Gtk::Label.new('Colors:'), expand: false, fill: false)
    theme_box = Gtk::ComboBoxText.new
    Appearance::THEMES.each { |id, label| theme_box.append(id, label) }
    theme_box.active_id = Appearance.theme
    theme_box.signal_connect('changed') do
      safely do
        GuiPrefs.set('theme', theme_box.active_id)
        refresh_appearance
        append_log("Colors: #{theme_box.active_text}.")
      end
    end
    looks.pack_start(theme_box, expand: false, fill: false)
    size_label = Gtk::Label.new('Text size:')
    size_label.margin_start = 12
    looks.pack_start(size_label, expand: false, fill: false)
    size_box = Gtk::ComboBoxText.new
    Appearance::SIZES.each { |pct, label| size_box.append(pct.to_s, "#{label} (#{pct}%)") }
    size_box.active_id = Appearance.text_scale.to_s
    size_box.signal_connect('changed') do
      safely do
        GuiPrefs.set('text_scale', size_box.active_id.to_i)
        refresh_appearance
        append_log("Text size: #{size_box.active_text}.")
      end
    end
    looks.pack_start(size_box, expand: false, fill: false)
    page.pack_start(looks, expand: false, fill: false)

    info.call('Lich folder', ChronoConfig.disp(LICH_DIR))
    lich_row = Gtk::Box.new(:horizontal, 6)
    change = button('Change Lich folder...') { change_lich_folder }
    @action_buttons << change
    lich_row.pack_start(change, expand: false, fill: false)
    lich_row.pack_start(button('Open Lich folder') { open_folder(LICH_DIR) }, expand: false, fill: false)
    page.pack_start(lich_row, expand: false, fill: false)

    # DragonRealms: the same Lich unless the person keeps a separate one for it
    separate = DR_LICH_DIR && DR_LICH_DIR != LICH_DIR
    dr_text =
      if DR_LICH_DIR.nil? then "Not found. #{DR_LICH_DIR_PROBLEM}"
      elsif separate then ChronoConfig.disp(DR_LICH_DIR)
      else 'The same Lich folder as above. Change it only if you keep a separate Lich for DragonRealms.'
      end
    info.call('DragonRealms Lich folder', dr_text)
    dr_row = Gtk::Box.new(:horizontal, 6)
    dr_change = button('Change DragonRealms folder...') { change_dr_lich_folder }
    @action_buttons << dr_change
    dr_row.pack_start(dr_change, expand: false, fill: false)
    dr_row.pack_start(button('Open DragonRealms folder') { open_folder(DR_LICH_DIR) }, expand: false, fill: false) if separate
    page.pack_start(dr_row, expand: false, fill: false)

    reinstall = ChronoConfig.windows? ? 'run the installer again' : 'run install.sh again'
    info.call('Ruby', "#{ChronoConfig.disp(rubyw_path)}\nThis is the Ruby that opened Chrono. To use a different one, #{reinstall}.")
    info.call('Chrono4Lich files', ChronoConfig.disp(ChronoConfig::APP_DIR))

    row = Gtk::Box.new(:horizontal, 6)
    rebuild = button('Rebuild scheduled tasks') { rebuild_tasks }
    @action_buttons << rebuild
    row.pack_start(rebuild, expand: false, fill: false)
    row.pack_start(button('Open log folder') { open_folder(STATE_DIR) }, expand: false, fill: false)
    page.pack_start(row, expand: false, fill: false)

    note = Gtk::Label.new('Use "Rebuild scheduled tasks" after moving the Chrono4Lich folder or updating Ruby, ' \
                          'so the scheduled tasks point at the new locations.')
    note.wrap = true
    note.xalign = 0
    page.pack_start(note, expand: false, fill: false)

    start = Gtk::CheckButton.new('Open Chrono (minimized) when I sign in to this computer')
    start.active = (Autostart.on? rescue false)
    start.signal_connect('toggled') do
      safely do
        start.active? ? Autostart.enable! : Autostart.disable!
        append_log(start.active? ? 'Chrono will open minimized when you sign in.' : "Chrono won't open when you sign in.")
      end
    end
    page.pack_start(start, expand: false, fill: false)

    info.call('Version', "Chrono #{CHRONO_VERSION}")
    upd = Gtk::Box.new(:horizontal, 6)
    auto = Gtk::CheckButton.new('Check for a new version when Chrono opens')
    auto.active = GuiPrefs.get('check_updates', true)
    auto.signal_connect('toggled') { GuiPrefs.set('check_updates', auto.active?) }
    upd.pack_start(auto, expand: false, fill: false)
    upd.pack_end(button('Check for updates now') { check_for_update(quiet: false) }, expand: false, fill: false)
    page.pack_start(upd, expand: false, fill: false)
    page
  end

  # A tab's page that scrolls when large text makes it taller than the window, so the
  # window never has to grow past the screen. With room to spare the page fills it as before.
  def scrollable(page)
    scroll = Gtk::ScrolledWindow.new
    scroll.set_policy(:never, :automatic)
    scroll.shadow_type = :none
    scroll.add(page)
    # give the page the height it asks for (scrolling past it) rather than squeezing its lists
    scroll.child.vscroll_policy = :natural if scroll.child.respond_to?(:vscroll_policy=)
    scroll
  end

  def open_folder(dir)
    FileUtils.mkdir_p(dir)
    opener = ChronoConfig.windows? ? 'explorer.exe' : (ChronoConfig.mac? ? 'open' : 'xdg-open')
    Process.detach(Process.spawn(opener, ChronoConfig.disp(dir), in: File::NULL, out: File::NULL, err: File::NULL))
  end

  def change_lich_folder
    dir = LichFolderPicker.browse(@win) or return
    fail! ChronoConfig.why_invalid(dir) unless ChronoConfig.valid_lich_dir?(dir)
    dir = ChronoConfig.normalize(dir)
    return if dir.casecmp?(LICH_DIR)
    unless Schedules.load.empty?
      return unless confirm_dialog('Your schedules are saved in the current Lich folder and will stay there. ' \
                                   "The new folder starts with no schedules.\n\nSwitch anyway?")
    end
    ChronoConfig.save('lich_dir' => dir)
    gui_log("Lich folder changed to #{dir}; restarting")
    Process.detach(Process.spawn(rubyw_path, File.join(ChronoConfig::APP_DIR, 'chrono_gui.rbw')))
    Gtk.main_quit
  end

  # Picks the Lich folder DragonRealms characters log in through (picking GemStone's means
  # one Lich for both), then restarts the window, since the folders are read when Chrono starts.
  def change_dr_lich_folder
    dir = LichFolderPicker.browse(@win, title: 'Pick the Lich folder you use for DragonRealms (the one with lich.rbw in it)') or return
    fail! ChronoConfig.why_invalid(dir) unless ChronoConfig.valid_lich_dir?(dir)
    dir = ChronoConfig.normalize(dir)
    dir = nil if dir.casecmp?(LICH_DIR)
    return if (dir || LICH_DIR).casecmp?(DR_LICH_DIR.to_s)

    ChronoConfig.save('dr_lich_dir' => dir)
    gui_log("DragonRealms Lich folder changed to #{dir || 'the GemStone one'}; restarting")
    Process.detach(Process.spawn(rubyw_path, File.join(ChronoConfig::APP_DIR, 'chrono_gui.rbw')))
    Gtk.main_quit
  end

  def rebuild_tasks
    list = Schedules.load
    return error_dialog('There are no schedules to rebuild.') if list.empty?
    set_busy(true, 'Rebuilding scheduled tasks...')
    begin
      list.each { |s| Schedules.install!(s) }
    ensure
      set_busy(false, 'Ready.')
    end
    append_log("Rebuilt the scheduled tasks for #{list.size} schedule(s).")
  end

  def reload_schedules
    @sched_store.clear
    Schedules.load.each do |s|
      iter = @sched_store.append
      iter[0] = s['name']
      iter[1] = Schedules.describe_days(s['days'])
      iter[2] = s['login_at']
      iter[3] = s['logout_at'] || 'after ~1 min'
      # DragonRealms characters are marked, since a name can be in both games
      iter[4] = s['characters'].map { |c| n, r = c.split(':', 2); dr_realm?(r) ? "#{n} (#{r})" : n }.join(', ')
      iter[5] = s['enabled'] == false ? 'off' : 'yes'
    end
  end

  def selected_schedule
    iter = @sched_view.selection.selected
    unless iter
      error_dialog('Click a schedule in the list first.')
      return nil
    end
    Schedules.find(iter[0])
  end

  def edit_schedule
    s = selected_schedule or return
    edit_schedule_dialog(s)
  end

  def delete_schedule
    s = selected_schedule or return
    return unless confirm_dialog("Delete the schedule '#{s['name']}'?\n\nIts scheduled #{Gem.win_platform? ? 'tasks are' : 'timers are'} removed too.")
    Schedules.uninstall!(s)
    Schedules.save(Schedules.load.reject { |x| x['name'].casecmp?(s['name']) })
    append_log("Deleted schedule '#{s['name']}'.")
    reload_schedules
  end

  def test_schedule(kind)
    s = selected_schedule or return
    run_job("Test #{kind} for '#{s['name']}'", [['run-schedule', kind, s['name']]])
  end

  def spin(max, value)
    sp = Gtk::SpinButton.new(0, max, 1)
    sp.digits = 0
    sp.numeric = true
    sp.wrap = true
    sp.value = value
    sp.signal_connect('output') do |b|
      b.text = format('%02d', b.value.to_i)
      true
    end
    sp
  end

  def time_row(time)
    h, m = (time || '06:00').split(':').map(&:to_i)
    box = Gtk::Box.new(:horizontal, 4)
    hour = spin(23, h)
    minute = spin(59, m)
    box.pack_start(hour, expand: false, fill: false)
    box.pack_start(Gtk::Label.new(':'), expand: false, fill: false)
    box.pack_start(minute, expand: false, fill: false)
    box.pack_start(Gtk::Label.new('(24-hour clock)'), expand: false, fill: false)
    [box, -> { format('%02d:%02d', hour.value.to_i, minute.value.to_i) }]
  end

  def edit_schedule_dialog(existing)
    entries = load_entries
    chars = entries.uniq { |e| [e[:game_code], e[:char_name].to_s.downcase, e[:user_id].to_s.downcase] }
                   .sort_by { |e| game_order(e) }

    d = Gtk::Dialog.new(title: existing ? "Edit schedule '#{existing['name']}'" : 'New schedule',
                        parent: @win, flags: %i[modal destroy_with_parent])
    d.add_button('Cancel', Gtk::ResponseType::CANCEL)
    d.add_button('Save', Gtk::ResponseType::OK)
    d.set_default_size(520, 560)

    grid = Gtk::Grid.new
    grid.row_spacing = 8
    grid.column_spacing = 10
    grid.margin = 10
    d.content_area.pack_start(grid, expand: true, fill: true)
    label = lambda do |text|
      l = Gtk::Label.new(text)
      l.xalign = 0
      l.yalign = 0
      l
    end

    name_entry = Gtk::Entry.new
    name_entry.text = existing ? existing['name'] : ''
    name_entry.placeholder_text = 'e.g. Morning'
    grid.attach(label.call('Name:'), 0, 0, 1, 1)
    grid.attach(name_entry, 1, 0, 1, 1)

    # characters checklist
    store = Gtk::ListStore.new(TrueClass, String, String) # checked, label, spec
    chosen = existing ? existing['characters'] : []
    chars.each do |e|
      spec = "#{e[:char_name]}:#{realm_of(e)}"
      iter = store.append
      iter[0] = chosen.any? { |c| c.casecmp?(spec) }
      iter[1] = "#{e[:char_name]}  (#{realm_of(e)}, #{e[:user_id]})"
      iter[2] = spec
    end
    view = Gtk::TreeView.new(store)
    view.headers_visible = false
    toggle = Gtk::CellRendererToggle.new
    toggle.signal_connect('toggled') do |_, path|
      it = store.get_iter(path)
      it[0] = !it[0]
    end
    view.append_column(Gtk::TreeViewColumn.new('', toggle, active: 0))
    view.append_column(Gtk::TreeViewColumn.new('Character', Gtk::CellRendererText.new, text: 1))
    char_scroll = Gtk::ScrolledWindow.new
    char_scroll.set_policy(:automatic, :automatic)
    char_scroll.set_size_request(-1, 170)
    char_scroll.vexpand = true
    char_scroll.hexpand = true
    char_scroll.add(view)
    grid.attach(label.call('Characters:'), 0, 1, 1, 1)
    grid.attach(char_scroll, 1, 1, 1, 1)

    # days
    day_box = Gtk::Box.new(:horizontal, 4)
    days = existing ? existing['days'] : %w[mon tue wed thu fri sat sun]
    day_checks = Schedules::DAYS.to_h do |day|
      cb = Gtk::CheckButton.new(day.capitalize)
      cb.active = days.include?(day)
      day_box.pack_start(cb, expand: false, fill: false)
      [day, cb]
    end
    grid.attach(label.call('Days:'), 0, 2, 1, 1)
    grid.attach(day_box, 1, 2, 1, 1)

    # times
    login_box, login_time = time_row(existing && existing['login_at'])
    grid.attach(label.call('Log in at:'), 0, 3, 1, 1)
    grid.attach(login_box, 1, 3, 1, 1)

    logout_check = Gtk::CheckButton.new('Log out at:')
    logout_check.active = existing ? !existing['logout_at'].nil? : true
    logout_box, logout_time = time_row((existing && existing['logout_at']) || '08:00')
    logout_box.sensitive = logout_check.active?
    logout_check.signal_connect('toggled') { logout_box.sensitive = logout_check.active? }
    grid.attach(logout_check, 0, 4, 1, 1)
    grid.attach(logout_box, 1, 4, 1, 1)

    scripts_entry = Gtk::Entry.new
    scripts_entry.text = existing ? existing['scripts'].to_s : ''
    scripts_entry.placeholder_text = 'optional, e.g. go2,bigshot'
    grid.attach(label.call('Start scripts:'), 0, 5, 1, 1)
    grid.attach(scripts_entry, 1, 5, 1, 1)

    enabled_check = Gtk::CheckButton.new('Schedule is on')
    enabled_check.active = existing ? existing['enabled'] != false : true
    grid.attach(enabled_check, 1, 6, 1, 1)

    hint = label.call('If the logout time is earlier than the login time, the logout happens the next day. ' \
                      'Without a logout time, it\'s a quick login: Chrono logs them out about a minute after ' \
                      'they\'re in (characters you were already playing are left alone).')
    hint.wrap = true
    grid.attach(hint, 1, 7, 1, 1)

    d.show_all
    loop do
      break unless d.run == Gtk::ResponseType::OK
      specs = []
      store.each { |_m, _p, it| specs << it[2] if it[0] }
      s = {
        'name'       => name_entry.text.strip,
        'characters' => specs,
        'days'       => day_checks.select { |_, cb| cb.active? }.keys,
        'login_at'   => login_time.call,
        'logout_at'  => logout_check.active? ? logout_time.call : nil,
        'scripts'    => scripts_entry.text.strip,
        'enabled'    => enabled_check.active?
      }
      saved = false
      safely do
        save_schedule(s, existing)
        saved = true
      end
      break if saved
    end
    d.destroy
  end

  def save_schedule(s, existing)
    list = Schedules.load
    old = existing && list.find { |x| x['name'].casecmp?(existing['name']) }
    Schedules.validate!(s, load_entries, list.reject { |x| x.equal?(old) })
    set_busy(true, 'Saving schedule...')
    begin
      Schedules.install!(s) # create the new tasks first, so a failure leaves the old ones in place
      Schedules.uninstall!(old) if old && !old['name'].casecmp?(s['name'])
    ensure
      set_busy(false, 'Ready.')
    end
    list.delete(old) if old
    list << s
    Schedules.save(list)
    append_log("Saved schedule '#{s['name']}': #{Schedules.describe_days(s['days'])}, " \
               "log in #{s['login_at']}#{s['logout_at'] ? ", log out #{s['logout_at']}" : ', log out about a minute later'}" \
               "#{s['enabled'] ? '' : ' (off)'}.")
    reload_schedules
  end

  def button(label, &block)
    b = Gtk::Button.new(label: label)
    b.signal_connect('clicked') { safely(&block) }
    b
  end

  # ---------- character list ----------

  def reload_characters
    # first load: the characters ticked last time; later reloads: whatever is ticked now
    checked = @characters_loaded ? selected_specs : Array(GuiPrefs.get('selected', []))
    @characters_loaded = true
    @store.clear
    # No saved logins yet is normal for a new user, not an error: point them at the Logins tab.
    unless SavedLogins.any_saved?
      append_log('No saved logins yet. Add your accounts on the Logins tab to get started.')
      return
    end
    entries = load_entries
    # a character saved for more than one frontend logs in with Warlock if one is Warlock (see warlock_flag)
    all = entries.group_by { |e| [e[:game_code], e[:char_name].to_s.downcase, e[:user_id].to_s.downcase] }
                 .values.map { |same| same.find { |e| e[:frontend] == SavedLogins::WARLOCK } || same.first }
    shown = all.select { |e| shown_by_filters?(e) }
    @filter_count&.text = shown.size == all.size ? "#{all.size} characters" : "#{shown.size} of #{all.size} shown"
    shown.sort_by { |e| game_order(e) }.each do |e|
      spec = "#{e[:char_name]}:#{realm_of(e)}"
      iter = @store.append
      iter[COL_CHECK]   = checked.include?(spec)
      iter[COL_NAME]    = e[:char_name].to_s
      iter[COL_REALM]   = realm_of(e)
      iter[COL_ACCOUNT] = e[:user_id].to_s
      iter[COL_STATUS]  = ''
      iter[COL_SPEC]    = spec
      iter[COL_FRONTEND] = e[:frontend].to_s
      iter[COL_CODE]     = e[:game_code].to_s
    end
    append_log("Loaded #{all.size} saved characters.") unless @loaded_message_shown
    @loaded_message_shown = true
  end

  # The Characters tab's filters. A character they hide isn't ticked: buttons act only on what's shown.
  def shown_by_filters?(entry)
    code = entry[:game_code].to_s.upcase
    return false if @hide_test&.active? && %w[GST DRT].include?(code)
    return false if @gs_only&.active? && dr_code?(code)
    return false if @dr_only&.active? && !dr_code?(code)

    true
  end

  def filters_changed
    return if @filters_syncing

    GuiPrefs.set('hide_test', @hide_test.active?)
    GuiPrefs.set('game_filter', @gs_only.active? ? 'gs' : (@dr_only.active? ? 'dr' : nil))
    reload_characters
    refresh_status
    remember_selection
  end

  def refresh_status
    @busy_refreshing = true
    @store.each do |_model, _path, iter|
      text = status_text(iter[COL_SPEC])
      iter[COL_STATUS] = text unless iter[COL_STATUS] == text # (every 3 seconds: redraw only on a change)
    end
  ensure
    @busy_refreshing = false
  end

  # spec is the row's "Name:realm"; its game says where the helper's status file is.
  def status_text(spec)
    name = spec.split(':', 2).first
    st = read_status(who_from_spec(spec))
    return 'Offline' unless st
    return 'Offline' if st['state'] == 'offline'
    unless lich_alive?(st)
      # The helper checked in recently, so Lich should be running. If the process check
      # disagrees, the check is wrong; say so instead of quietly showing Offline.
      if heartbeat_age(st) <= HEARTBEAT_STALE
        @warned_pids ||= {}
        unless @warned_pids[st['pid']]
          @warned_pids[st['pid']] = true
          gui_log("PROCESS CHECK MISMATCH: #{name} helper heartbeat #{heartbeat_age(st)}s ago but PID #{st['pid']} reported not running")
          append_log("!!! #{name}: helper is checking in, but the process check says Lich (PID #{st['pid']}) isn't running.")
        end
        return 'Online? (process check failed)'
      end
      return 'Offline'
    end
    STATE_TEXT.fetch(st['state'], st['state'].to_s)
  rescue Fail
    raise
  rescue StandardError => e
    "status unreadable (#{e.class})"
  end

  def set_all_checks(value)
    @store.each { |_m, _p, iter| iter[COL_CHECK] = value }
    remember_selection
  end

  # Ticked characters are kept for next time Chrono opens.
  def remember_selection
    GuiPrefs.set('selected', selected_specs)
  end

  def selected_specs
    specs = []
    @store.each { |_m, _p, iter| specs << iter[COL_SPEC] if iter[COL_CHECK] }
    specs
  end

  def require_selection
    specs = selected_specs
    if specs.empty?
      error_dialog('Tick at least one character first.')
      return nil
    end
    specs
  end

  # ---------- actions ----------

  def login_selected
    specs = require_selection or return
    args = ['login', *specs]
    scripts = @scripts_entry.text.strip
    args += ['--scripts', scripts] unless scripts.empty?
    run_job('Log in', [args])
  end

  # Saves the window's size (its normal size, not the maximized one) and whether it's maximized.
  def remember_window_size
    GuiPrefs.set('window_maximized', @win_maximized ? true : false)
    GuiPrefs.set('window_size', @win.size) unless @win_maximized
  rescue StandardError => e
    gui_log("couldn't save the window size: #{e.message}")
  end

  # Pictures of small real buttons with these labels, all the same width (a size group makes
  # each as wide as the widest), in the current theme.
  def row_images
    pics = row_button_images(['Log in', 'Log out'])
    { login: pics['Log in'], logout: pics['Log out'] }
  end

  # Applies the light/dark and text size settings, and redraws what doesn't follow by itself.
  def refresh_appearance
    return unless Appearance.apply!

    @row_images = row_images
    @view&.columns_autosize
    @view&.queue_draw
  end

  def row_button_images(labels)
    css = Gtk::CssProvider.new
    css.load(data: 'button { min-height: 0; padding: 1px 10px; }')
    group = Gtk::SizeGroup.new(:horizontal)
    shown = labels.map do |label|
      b = Gtk::Button.new(label: label)
      b.style_context.add_provider(css, Gtk::StyleProvider::PRIORITY_APPLICATION)
      group.add_widget(b)
      off = Gtk::OffscreenWindow.new
      off.add(b)
      off.show_all
      [label, off]
    end
    Gtk.main_iteration_do(false) while Gtk.events_pending?
    shown.each { |_, off| off.queue_resize }
    Gtk.main_iteration_do(false) while Gtk.events_pending?
    shown.to_h { |label, off| [label, off.pixbuf] }
  ensure
    shown&.each { |_, off| off.destroy }
  end

  # What the row's button does: :login when offline, :logout when online, nil while it's changing.
  def row_action(iter)
    status = iter[COL_STATUS].to_s
    return :login if status.empty? || status.start_with?('Offline')
    return :logout if status.start_with?('Online')

    nil
  end

  def row_action_clicked(spec, name, action)
    case action
    when :login
      args = ['login', spec]
      scripts = @scripts_entry.text.strip
      args += ['--scripts', scripts] unless scripts.empty?
      run_job("Log in #{name}", [args])
    when :logout
      run_job("Log out #{name}", [['logout', spec]])
    end
  end

  def logout_selected
    specs = require_selection or return
    run_job('Log out', [['logout', *specs]])
  end

  def kill_selected
    specs = require_selection or return
    names = specs.map { |s| s.split(':').first }.join(', ')
    return unless confirm_dialog("Force close Lich for #{names}?\n\n" \
                                 'This cuts the connection instead of logging out, so the character ' \
                                 'may stay linkdead in the game for a while. Use it only if a normal logout failed.')
    run_job('Force close', specs.map { |s| ['kill', s] })
  end

  # Runs chrono.rb once per argument list, one after another, in a background thread.
  def run_job(title, arg_lists)
    return error_dialog('Something is still running. Wait for it to finish.') if @busy
    set_busy(true, "#{title}...")
    @job_errors = []
    append_log("===== #{title} =====")
    ruby = rubyw_path
    Thread.new do
      failed = 0
      arg_lists.each do |args|
        reader, writer = IO.pipe
        pid = Process.spawn(ruby, CLI_SCRIPT, *args, in: File::NULL, out: writer, err: writer, chdir: __dir__)
        writer.close
        output = Thread.new do
          reader.each_line { |line| @queue << [:line, line.chomp] }
        rescue IOError
          nil # reader closed below
        end
        # Finish when chrono.rb exits, not when the pipe closes: anything it started
        # could still be holding the pipe open.
        _, status = Process.wait2(pid)
        unless output.join(1)
          # Something it started (Lich) still holds the pipe; everything chrono.rb wrote has
          # been read by now. Nothing for the window to show.
          gui_log("#{title}: output pipe still held by another process after chrono.rb exited")
          reader.close
          output.join(1)
        end
        reader.close unless reader.closed?
        failed += 1 unless status.success?
      end
      @queue << [:done, title, failed]
    rescue StandardError => e
      @queue << [:crash, title, e]
    end
  end

  def pump_queue
    if $chrono_quit_signal # see the TERM/HUP trap at the bottom: quit like the close button would
      gui_log($chrono_quit_signal == :quit_event ? 'quitting (Quit from the Dock)' :
                                                    "quitting (asked to by the system: SIG#{$chrono_quit_signal})")
      $chrono_quit_signal = nil
      remember_window_size
      Gtk.main_quit
      return
    end
    until @queue.empty?
      kind, *data = @queue.pop
      case kind
      when :line
        line = data[0]
        append_log(line)
        @job_errors << line.sub(/\A.*?!!! /, '') if line.include?('!!!')
      when :done
        title, failed = data
        set_busy(false, failed.zero? ? "#{title}: done." : "#{title}: finished with errors.")
        refresh_status
        reload_rewards
        unless failed.zero?
          details = @job_errors.empty? ? 'See the output box for details.' : @job_errors.uniq.join("\n\n")
          error_dialog("#{title} had problems:\n\n#{details}")
        end
      when :crash
        title, e = data
        set_busy(false, "#{title}: crashed.")
        gui_log("#{title} crashed: #{e.class}: #{e.message}")
        error_dialog("#{title} could not run: #{e.class}: #{e.message}")
      end
    end
  end

  def set_busy(busy, text)
    @busy = busy
    @action_buttons.each { |b| b.sensitive = !busy }
    @status_label.text = text
  end

  # ---------- output and dialogs ----------

  def append_log(text)
    buffer = @log_view.buffer
    buffer.insert(buffer.end_iter, text + "\n")
    mark = buffer.create_mark(nil, buffer.end_iter, false)
    @log_view.scroll_to_mark(mark, 0.0, false, 0.0, 1.0)
    buffer.delete_mark(mark)
  end

  def error_dialog(text)
    d = Gtk::MessageDialog.new(parent: @win, flags: :destroy_with_parent, type: :error,
                               buttons_type: :close, message: text)
    d.title = 'Chrono'
    d.run
    d.destroy
    nil
  end

  def confirm_dialog(text)
    d = Gtk::MessageDialog.new(parent: @win, flags: :destroy_with_parent, type: :warning,
                               buttons_type: :ok_cancel, message: text)
    d.title = 'Chrono'
    ok = d.run == Gtk::ResponseType::OK
    d.destroy
    ok
  end

  def confirm_close
    return true unless @busy
    confirm_dialog("Something is still running. If you close the window it will keep going, " \
                   "but you won't see the result here (it will still be in chrono.log).\n\nClose anyway?")
  end

  # Every button and timer goes through here, so no error disappears silently.
  # Errors Chrono itself raises with a message meant for the player (not crashes).
  def self.app_errors
    [Fail, ChronoEAccess::Error, ChronoGitHub::Error, ChronoCronJob::Error, ChronoUpdate::Error]
  end

  def safely
    yield
  rescue *ChronoWindow.app_errors => e
    gui_log("ERROR: #{e.message}")
    error_dialog(e.message)
  rescue StandardError => e
    gui_log("UNEXPECTED ERROR: #{e.class}: #{e.message}\n    #{e.backtrace.first(5).join("\n    ")}")
    error_dialog("Unexpected error: #{e.class}: #{e.message}\n\nDetails are in chrono.log.")
  end
end

ICON_FILE = File.join(ChronoConfig::APP_DIR, 'chrono.png')

# Window and taskbar icon. On Linux the dock matches windows to chrono.desktop by this name.
def setup_app_identity
  GLib.prgname = 'chrono' if GLib.respond_to?(:prgname=)
  GLib.application_name = 'Chrono' if GLib.respond_to?(:application_name=)
  if File.exist?(ICON_FILE)
    Gtk::Window.set_default_icon_from_file(ICON_FILE)
  else
    gui_log("Icon missing: #{ICON_FILE}")
  end
rescue StandardError => e # a missing icon must never stop the app from opening
  gui_log("Couldn't set the window icon: #{e.class}: #{e.message}")
end

# macOS: Quit in the Dock icon's menu sends the app a "quit" Apple event. GTK answers it only for
# apps built on Gtk::Application, so Chrono ignored it. Take it here and quit like the close button,
# from the window's own timer (the same way as for the signals below).
def take_mac_quit_event
  return unless ChronoConfig.mac?

  require 'fiddle'
  core = Fiddle.dlopen('/System/Library/Frameworks/CoreServices.framework/CoreServices')
  install = Fiddle::Function.new(core['AEInstallEventHandler'],
                                 [-Fiddle::TYPE_INT, -Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_CHAR],
                                 Fiddle::TYPE_SHORT)
  # kept in a global so it's never garbage-collected while macOS holds a pointer to it
  $chrono_quit_handler = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_SHORT, [Fiddle::TYPE_VOIDP] * 3) do
    $chrono_quit_signal = :quit_event
    0 # noErr: handled
  end
  err = install.call('aevt'.unpack1('N'), 'quit'.unpack1('N'), $chrono_quit_handler, nil, 0)
  gui_log("Couldn't take Quit from the Dock (error #{err})") unless err.zero?
rescue StandardError, LoadError => e # never stop the window from opening over this
  gui_log("Couldn't take Quit from the Dock: #{e.class}: #{e.message}")
end

# A crash inside Ruby itself or a library it runs (a segmentation fault) skips the crash handler
# below. Ruby then writes its own report, which names the line it was on, to standard error. When
# Chrono is opened from the Dock, Start menu or a shortcut, standard error goes nowhere, so send
# it to window_errors.log next to chrono.log. GTK's warnings land there too. Left alone in a terminal.
def keep_crash_reports
  return if $stderr.tty? || !(defined?(STATE_DIR) && STATE_DIR)

  ensure_state_dir
  path = File.join(STATE_DIR, 'window_errors.log')
  File.rename(path, "#{path}.old") if File.size?(path).to_i > 1_000_000
  $stderr.reopen(path, 'a')
  $stderr.sync = true
  $stderr.puts "===== #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}  Chrono #{CHRONO_VERSION} window opened " \
               "(PID #{Process.pid}, Ruby #{RUBY_VERSION}) ====="
rescue StandardError
  nil # only a diagnostic; never stop the window from opening over it
end

begin
  setup_app_identity
  LichFolderPicker.ensure_configured
  require_relative 'chrono'
  keep_crash_reports
  Appearance.apply! # light/dark and text size (Settings tab), before any window is built
  begin
    waiting = migrate_from_lichsched!
    unless waiting.empty?
      LichFolderPicker.message(:warning, :ok,
        "#{waiting.join(', ')} #{waiting.size == 1 ? 'is' : 'are'} still online from lichsched, Chrono's old version, " \
        "so Chrono can't log #{waiting.size == 1 ? 'that character' : 'them'} out.\n\n" \
        'Type QUIT in the game for each one, then open Chrono again. Your old schedules are brought over then.')
    end
  rescue StandardError => e # never let the carry-over stop the window from opening
    gui_log("Carry-over from lichsched failed: #{e.class}: #{e.message}")
    LichFolderPicker.message(:error, :ok, "Bringing over your schedules from lichsched failed:\n\n#{e.message}\n\n" \
                                          'Chrono will open anyway. Details are in chrono.log.')
  end
  $chrono_window = ChronoWindow.new
  # Automated tests only (needs CHRONO_DEV=1 as well): lets a test script drive the window.
  if (test_script = ChronoConfig.dev_env('CHRONO_GUI_TEST')) && File.exist?(test_script)
    load test_script
  end
  # The system asks programs to quit with a signal (macOS at log-out and shutdown, Linux at the
  # end of a session). Quit cleanly, from the window's own timer, instead of treating it as a crash.
  %w[TERM HUP].each do |sig|
    Signal.trap(sig) { $chrono_quit_signal = sig }
  rescue ArgumentError
    nil # (no HUP on Windows)
  end
  take_mac_quit_event
  Gtk.main
rescue Exception => e # rubyw has no console, so a crash would otherwise vanish
  raise if e.is_a?(SystemExit) || e.is_a?(SignalException) # (Interrupt is a SignalException)
  gui_log("CRASH: #{e.class}: #{e.message}\n    #{Array(e.backtrace).first(8).join("\n    ")}")
  begin
    d = Gtk::MessageDialog.new(type: :error, buttons_type: :close,
                               message: "Chrono crashed: #{e.class}: #{e.message}\n\nDetails are in chrono.log.")
    d.run
    d.destroy
  rescue Exception
    nil
  end
  exit 1
end
