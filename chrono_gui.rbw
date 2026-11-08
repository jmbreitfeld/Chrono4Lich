# chrono_gui.rbw - window for logging GemStone IV characters in and out through Lich5
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

  def browse(parent = nil)
    d = Gtk::FileChooserDialog.new(title: 'Pick your Lich folder (the one with lich.rbw in it)',
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
  File.open(File.join(dir, 'chrono.log'), 'a') do |f|
    f.puts "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}  GUI: #{msg}"
  end
rescue StandardError
  nil # the log is a convenience; never let it hide the real error
end

class ChronoWindow
  COL_CHECK   = 0
  COL_NAME    = 1
  COL_REALM   = 2
  COL_ACCOUNT = 3
  COL_STATUS  = 4
  COL_SPEC    = 5

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
    safely { reload_characters }
    safely { refresh_status }
    GLib::Timeout.add(200) { safely { pump_queue }; true }
    GLib::Timeout.add_seconds(3) { safely { refresh_status unless @busy_refreshing }; true }
    @win.show_all
  end

  # ---------- layout ----------

  def build_window
    @win = Gtk::Window.new('Chrono')
    @win.set_default_size(760, 620)
    @win.signal_connect('delete-event') { !confirm_close }
    @win.signal_connect('destroy') { Gtk.main_quit }

    root = Gtk::Box.new(:vertical, 8)
    root.margin = 10
    @win.add(root)

    notebook = Gtk::Notebook.new
    notebook.append_page(build_characters_page, Gtk::Label.new('Characters'))
    notebook.append_page(build_schedules_page, Gtk::Label.new('Schedules'))
    notebook.append_page(build_rewards_page, Gtk::Label.new('Rewards'))
    notebook.append_page(build_logins_page, Gtk::Label.new('Logins'))
    notebook.append_page(build_settings_page, Gtk::Label.new('Settings'))
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

    @status_label = Gtk::Label.new('Ready.')
    @status_label.xalign = 0
    root.pack_start(@status_label, expand: false, fill: false)
  end

  def build_characters_page
    outer = Gtk::Box.new(:vertical, 8)
    outer.margin = 6

    # character list
    @store = Gtk::ListStore.new(TrueClass, String, String, String, String, String)
    @view = Gtk::TreeView.new(@store)
    toggle = Gtk::CellRendererToggle.new
    toggle.signal_connect('toggled') do |_, path|
      iter = @store.get_iter(path)
      iter[COL_CHECK] = !iter[COL_CHECK]
    end
    @view.append_column(Gtk::TreeViewColumn.new('', toggle, active: COL_CHECK))
    [['Character', COL_NAME], ['Realm', COL_REALM], ['Account', COL_ACCOUNT], ['Status', COL_STATUS]].each do |title, col|
      column = Gtk::TreeViewColumn.new(title, Gtk::CellRendererText.new, text: col)
      column.resizable = true
      column.sort_column_id = col
      @view.append_column(column)
    end
    list_scroll = Gtk::ScrolledWindow.new
    list_scroll.set_policy(:automatic, :automatic)
    list_scroll.add(@view)
    outer.pack_start(list_scroll, expand: true, fill: true)

    # selection buttons
    row1 = Gtk::Box.new(:horizontal, 6)
    row1.pack_start(button('Select all') { set_all_checks(true) }, expand: false, fill: false)
    row1.pack_start(button('Select none') { set_all_checks(false) }, expand: false, fill: false)
    row1.pack_end(button('Reload characters') { reload_characters; refresh_status }, expand: false, fill: false)
    outer.pack_start(row1, expand: false, fill: false)

    # start scripts
    row2 = Gtk::Box.new(:horizontal, 6)
    row2.pack_start(Gtk::Label.new('Start scripts after login (comma-separated):'), expand: false, fill: false)
    @scripts_entry = Gtk::Entry.new
    @scripts_entry.placeholder_text = 'optional, e.g. go2,bigshot'
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

    # account, simucoins, daily, last result
    # account, simucoins, daily, last result, claim on GitHub
    @rewards_store = Gtk::ListStore.new(String, TrueClass, TrueClass, String, TrueClass)
    @rewards_view = Gtk::TreeView.new(@rewards_store)
    @rewards_view.append_column(Gtk::TreeViewColumn.new('Account', Gtk::CellRendererText.new, text: 0))
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
      @rewards_view.append_column(Gtk::TreeViewColumn.new(title, toggle, active: col))
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
    @rewards_view.append_column(Gtk::TreeViewColumn.new('Claim on GitHub', gh_toggle, active: 4))
    last = Gtk::TreeViewColumn.new('Last result', Gtk::CellRendererText.new, text: 3)
    last.expand = true
    @rewards_view.append_column(last)
    @rewards_view.tooltip_column = 3 # hover a row to see the whole result
    scroll = Gtk::ScrolledWindow.new
    scroll.set_policy(:automatic, :automatic)
    scroll.add(@rewards_view)
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
    Rewards.accounts(data).each do |a|
      it = @rewards_store.append
      it[0] = a[:name]
      it[1] = a[:coins]
      it[2] = a[:daily]
      it[3] = a[:where] == 'github' ? 'claimed on GitHub (see "Open results on GitHub")' : Rewards.summary(a[:last])
      it[4] = a[:where] == 'github'
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
  end

  def open_url(url)
    cmd = Gem.win_platform? ? ['rundll32', 'url.dll,FileProtocolHandler', url] : ['xdg-open', url]
    Process.detach(Process.spawn(*cmd, in: File::NULL, out: File::NULL, err: File::NULL))
  rescue SystemCallError => e
    error_dialog("Couldn't open the browser (#{e.message}). Open this address yourself:\n\n#{url}")
  end

  # Signs in to GitHub with a code, then sets up/updates (:sync) or turns off (:stop) GitHub claiming.
  # The sign-in is used for this one job and forgotten.
  def github_dialog(purpose)
    data = Rewards.load
    if purpose == :sync
      wanted = Rewards.github_accounts(data)
      return error_dialog('Tick "Claim on GitHub" for at least one account first.') if wanted.empty?
      return unless confirm_dialog(
        "This stores the Simutronics logins for #{wanted.map { |a| a[:name] }.join(', ')} as encrypted secrets in a " \
        "private repository on your GitHub account (#{ChronoGitHub::REPO_NAME}), and claims rewards there every day " \
        "at about #{data['time']}.\n\nOnly GitHub can decrypt them, to run the claim. Chrono doesn't keep the " \
        'GitHub sign-in; you\'ll sign in again only when changing something.'
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
            append_log(purpose == :sync ? "GitHub set up: #{lines.last}" : 'GitHub claiming turned off.')
          else
            intro.text = "That didn't work:\n#{val}"
            append_log("!!! GitHub: #{val}")
          end
          close_btn.label = 'Close'
          safely { reload_rewards }
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

    # character, realm, account, frontend, game_code
    @logins_store = Gtk::ListStore.new(String, String, String, String, String)
    @logins_view = Gtk::TreeView.new(@logins_store)
    [['Character', 0], ['Realm', 1], ['Account', 2], ['Frontend', 3]].each do |title, col|
      column = Gtk::TreeViewColumn.new(title, Gtk::CellRendererText.new, text: col)
      column.resizable = true
      column.sort_column_id = col
      @logins_view.append_column(column)
    end
    scroll = Gtk::ScrolledWindow.new
    scroll.set_policy(:automatic, :automatic)
    scroll.add(@logins_view)
    page.pack_start(scroll, expand: true, fill: true)

    row = Gtk::Box.new(:horizontal, 6)
    add_btn = button('Add logins...') { add_logins_dialog }
    pw_btn  = button('Change password...') { change_password_dialog }
    rm_btn  = button('Remove selected...') { remove_selected_login }
    @action_buttons.push(add_btn, pw_btn, rm_btn)
    row.pack_start(add_btn, expand: false, fill: false)
    row.pack_start(pw_btn, expand: false, fill: false)
    row.pack_end(rm_btn, expand: false, fill: false)
    page.pack_start(row, expand: false, fill: false)

    note = Gtk::Label.new('These are the same saved logins Lich uses. Close Lich\'s login window before ' \
                          'changing them here, or saving something in that window may undo the change. ' \
                          'Passwords are checked with Simutronics before they\'re saved, and never shown or logged.')
    note.wrap = true
    note.xalign = 0
    page.pack_start(note, expand: false, fill: false)

    safely { reload_logins }
    page
  end

  def reload_logins
    @logins_store.clear
    kind =
      if SavedLogins.backend == :yaml
        mode = (File.exist?(SavedLogins.yaml_file) && SavedLogins.load_yaml['encryption_mode']) || 'plaintext'
        "entry.yaml (passwords: #{mode})"
      else
        'entry.dat'
      end
    ver = SavedLogins.lich_version
    @logins_info.text = "Saved logins are in #{kind}#{ver ? ", Lich #{ver}" : ''}."
    return unless File.exist?(SavedLogins.yaml_file) || File.exist?(SavedLogins.dat_file)
    groups = SavedLogins.entries.group_by { |e| [e[:game_code], e[:char_name].downcase, e[:user_id].downcase] }
    groups.values.map(&:first).sort_by { |e| [e[:user_id].downcase, e[:game_code], e[:char_name]] }.each do |e|
      iter = @logins_store.append
      iter[0] = e[:char_name]
      iter[1] = realm_of(e)
      iter[2] = e[:user_id]
      # every frontend this character is saved for, e.g. "warlock, wrayth"
      iter[3] = groups[[e[:game_code], e[:char_name].downcase, e[:user_id].downcase]].map { |x| x[:frontend] }.uniq.join(', ')
      iter[4] = e[:game_code]
    end
  end

  # Logins changed: every list that shows characters needs refreshing.
  def logins_changed
    reload_logins
    reload_characters
    refresh_status
  end

  # Runs slow work (network, Lich commands) off the window's thread. The window stays
  # responsive; done/failed are called back on the window's thread.
  def in_background(status_text, done:, failed:)
    set_busy(true, status_text)
    result = nil
    error = nil
    worker = Thread.new do
      result = yield
    rescue Fail, ChronoEAccess::Error => e
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

  def add_logins_dialog
    d = Gtk::Dialog.new(title: 'Add logins', parent: @win, flags: %i[modal destroy_with_parent])
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
    SavedLogins.frontends.each { |f| frontend.append_text(f) }
    frontend.active = 0
    grid.attach(label.call('Frontend:'), 0, 5, 1, 1)
    grid.attach(frontend, 1, 5, 1, 1)

    # Warlock: Lich starts it with a launch command saved with the login. Filled in from a login
    # that already uses Warlock, or Lich's own preset; editable if Warlock is somewhere else.
    warlock_cmd_label = label.call('Warlock command:')
    warlock_cmd = Gtk::Entry.new
    warlock_cmd.hexpand = true
    warlock_cmd.text = (SavedLogins.warlock_launch.first rescue '')
    warlock_note = label.call('Lich runs this to start Warlock (%port% and %key% are filled in by Lich). ' \
                              'If Warlock isn\'t found when you log in, put the full path to Warlock here, ' \
                              'in quotes if it has spaces.')
    warlock_note.wrap = true
    [warlock_cmd_label, warlock_cmd, warlock_note].each { |w| w.no_show_all = true }
    grid.attach(warlock_cmd_label, 0, 6, 1, 1)
    grid.attach(warlock_cmd, 1, 6, 1, 1)
    grid.attach(warlock_note, 0, 7, 2, 1)
    show_warlock = lambda do
      on = frontend.active_text == SavedLogins::WARLOCK
      [warlock_cmd_label, warlock_cmd, warlock_note].each { |w| on ? w.show : w.hide }
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
                        status.text = chars.empty? ? 'This account has no GemStone characters in a game it\'s subscribed to.' :
                                                     'Password confirmed. Tick the characters to save.'
                        save.sensitive = !chars.empty?
                      },
                      failed: lambda { |msg|
                        next if closed
                        lookup.sensitive = true
                        status.text = msg
                      }) { ChronoEAccess.list_characters(acct, pw, data_dir: DATA_DIR) }
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
    combo.active = [accounts.index { |a| sel && a.casecmp?(sel[2]) } || 0, 0].max
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

  def remove_selected_login
    it = @logins_view.selection.selected
    return error_dialog('Click a login in the list first.') unless it
    name, realm, acct, _fe, code = it[0], it[1], it[2], it[3], it[4]
    entry = { char_name: name, game_code: code, user_id: acct }
    check_removable!(entry)
    return unless confirm_dialog("Remove the saved login for #{name} (#{realm}, account #{acct})?\n\n" \
                                 'This only removes it from your saved logins. Nothing changes on your account.')
    in_background("Removing #{name}...",
                  done: lambda { |_|
                    append_log("Removed the saved login for #{name} (#{realm}).")
                    logins_changed
                  },
                  failed: ->(msg) { error_dialog("#{name} wasn't removed:\n\n#{msg}") }) do
      SavedLogins.remove(name, code, acct)
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

    info.call('Lich folder', ChronoConfig.disp(LICH_DIR))
    lich_row = Gtk::Box.new(:horizontal, 6)
    change = button('Change Lich folder...') { change_lich_folder }
    @action_buttons << change
    lich_row.pack_start(change, expand: false, fill: false)
    lich_row.pack_start(button('Open Lich folder') { open_folder(LICH_DIR) }, expand: false, fill: false)
    page.pack_start(lich_row, expand: false, fill: false)

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
    page
  end

  def open_folder(dir)
    FileUtils.mkdir_p(dir)
    opener = ChronoConfig.windows? ? 'explorer.exe' : 'xdg-open'
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
      iter[3] = s['logout_at'] || '-'
      iter[4] = s['characters'].map { |c| c.split(':').first }.join(', ')
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
                   .sort_by { |e| [e[:game_code].to_s, e[:char_name].to_s] }

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

    hint = label.call('If the logout time is earlier than the login time, the logout happens the next day.')
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
               "log in #{s['login_at']}#{s['logout_at'] ? ", log out #{s['logout_at']}" : ''}" \
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
    checked = selected_specs
    @store.clear
    # No saved logins yet is normal for a new user, not an error: point them at the Logins tab.
    unless File.exist?(SavedLogins.yaml_file) || File.exist?(SavedLogins.dat_file)
      append_log('No saved logins yet. Add your accounts on the Logins tab to get started.')
      return
    end
    entries = load_entries
    shown = entries.uniq { |e| [e[:game_code], e[:char_name].to_s.downcase, e[:user_id].to_s.downcase] }
    shown.sort_by { |e| [e[:game_code].to_s, e[:char_name].to_s] }.each do |e|
      spec = "#{e[:char_name]}:#{realm_of(e)}"
      iter = @store.append
      iter[COL_CHECK]   = checked.include?(spec)
      iter[COL_NAME]    = e[:char_name].to_s
      iter[COL_REALM]   = realm_of(e)
      iter[COL_ACCOUNT] = e[:user_id].to_s
      iter[COL_STATUS]  = ''
      iter[COL_SPEC]    = spec
    end
    append_log("Loaded #{shown.size} saved characters.") if checked.empty?
  end

  def refresh_status
    @busy_refreshing = true
    @store.each do |_model, _path, iter|
      iter[COL_STATUS] = status_text(iter[COL_NAME])
    end
  ensure
    @busy_refreshing = false
  end

  def status_text(name)
    st = read_status(name)
    return 'Offline' unless st
    return 'Offline' if st['state'] == 'offline'
    unless pid_alive?(st['pid'])
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
        unless output.join(3)
          @queue << [:line, '(output pipe was still held open by another process; stopped reading it)']
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
  def safely
    yield
  rescue Fail => e
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

begin
  setup_app_identity
  LichFolderPicker.ensure_configured
  require_relative 'chrono'
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
  # Automated tests only: lets a test script drive the window. Unused in normal runs.
  load ENV['CHRONO_GUI_TEST'] if ENV['CHRONO_GUI_TEST'] && File.exist?(ENV['CHRONO_GUI_TEST'])
  Gtk.main
rescue Exception => e # rubyw has no console, so a crash would otherwise vanish
  raise if e.is_a?(SystemExit) || e.is_a?(Interrupt)
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
