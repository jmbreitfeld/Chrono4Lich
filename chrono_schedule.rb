# chrono_schedule.rb - saved schedules and the Windows scheduled tasks that run them.
# Loaded by chrono.rb; needs its helpers (fail!, STATE_DIR, rubyw_path, load_entries ...).
#
# Each schedule becomes up to two tasks in Task Scheduler, in a "Chrono4Lich" folder:
#   "\Chrono4Lich\<name> login"   runs: rubyw chrono.rb run-schedule login "<name>" --notify
#   "\Chrono4Lich\<name> logout"  runs: rubyw chrono.rb run-schedule logout "<name>" --notify

require 'json'
require 'open3'
require 'fileutils'
require 'date'
require 'tmpdir'

module Schedules
  FILE        = STATE_DIR && File.join(STATE_DIR, 'schedules.json')
  TASK_FOLDER = '\\Chrono4Lich\\'
  DAYS        = %w[sun mon tue wed thu fri sat].freeze
  DAY_XML     = { 'sun' => 'Sunday', 'mon' => 'Monday', 'tue' => 'Tuesday', 'wed' => 'Wednesday',
                  'thu' => 'Thursday', 'fri' => 'Friday', 'sat' => 'Saturday' }.freeze
  NAME_RE     = /\A[A-Za-z0-9][A-Za-z0-9 _-]{0,39}\z/
  TIME_RE     = /\A([01]\d|2[0-3]):([0-5]\d)\z/

  module_function

  # ---------- saved schedules ----------

  def load
    return [] unless File.exist?(FILE)
    data = JSON.parse(File.read(FILE))
    fail! "#{FILE} is not a list of schedules." unless data.is_a?(Array)
    data
  rescue JSON::ParserError => e
    fail! "#{FILE} is damaged and can't be read: #{e.message}"
  end

  def save(list)
    ensure_state_dir
    tmp = FILE + '.tmp'
    File.write(tmp, JSON.pretty_generate(list.sort_by { |s| s['name'].downcase }))
    File.rename(tmp, FILE)
  end

  def find(name)
    load.find { |s| s['name'].casecmp?(name) } or fail! "No schedule named '#{name}'."
  end

  # The checks that don't need Lich's saved logins. Run every time a schedule is installed (not
  # only when it's saved from the window), since its values go into task, timer and plist files.
  def check_fields!(s)
    fail! 'A saved schedule is damaged (not a schedule).' unless s.is_a?(Hash)
    fail! "The schedule name #{s['name'].to_s[0, 40].inspect} isn't allowed (letters, numbers, spaces, - and _; up to 40 characters)." unless s['name'].to_s.match?(NAME_RE)
    days = s['days']
    fail! "Schedule '#{s['name']}': its days are damaged." unless days.is_a?(Array) && !days.empty? && (days - DAYS).empty?
    fail! "Schedule '#{s['name']}': login time #{s['login_at'].to_s[0, 10].inspect} isn't HH:MM." unless s['login_at'].to_s.match?(TIME_RE)
    if s['logout_at'] && !s['logout_at'].to_s.match?(TIME_RE)
      fail! "Schedule '#{s['name']}': logout time #{s['logout_at'].to_s[0, 10].inspect} isn't HH:MM."
    end
    chars = s['characters']
    unless chars.is_a?(Array) && !chars.empty? && chars.all? { |c| c.is_a?(String) && c.match?(/\A[^\x00-\x1f\x7f]{1,80}\z/) }
      fail! "Schedule '#{s['name']}': its characters are damaged."
    end
  end

  # Every job written to a scheduler: times and days in the expected form only.
  def check_job!(job)
    fail! "A scheduled job's time #{job[:time].to_s[0, 10].inspect} isn't HH:MM." unless job[:time].to_s.match?(TIME_RE)
    fail! "A scheduled job's days are damaged." unless job[:days].is_a?(Array) && (job[:days] - DAYS).empty?
  end

  # Text for task, timer and plist files: one line, no control characters.
  def one_line(text) = text.to_s.gsub(/[\x00-\x1f\x7f]+/, ' ')

  def validate!(s, entries, others)
    fail! 'Give the schedule a name (letters, numbers, spaces, - and _; up to 40 characters).' unless s['name'].to_s.match?(NAME_RE)
    if others.any? { |o| o['name'].casecmp?(s['name']) }
      fail! "There is already a schedule named '#{s['name']}'."
    end
    # On Linux, names become file names like chrono-morning-run-login.timer.
    if (twin = others.find { |o| slug(o['name']) == slug(s['name']) })
      fail! "'#{s['name']}' is too close to the existing schedule '#{twin['name']}'. Pick a more different name."
    end
    fail! 'Tick at least one character.' if s['characters'].empty?
    fail! 'Tick at least one day.' if s['days'].empty?
    bad_days = s['days'] - DAYS
    fail! "Unknown days: #{bad_days.join(', ')}" unless bad_days.empty?
    fail! "Login time '#{s['login_at']}' isn't a valid HH:MM time." unless s['login_at'].to_s.match?(TIME_RE)
    if s['logout_at']
      fail! "Logout time '#{s['logout_at']}' isn't a valid HH:MM time." unless s['logout_at'].match?(TIME_RE)
      fail! 'Login and logout times are the same.' if s['logout_at'] == s['login_at']
    end
    selected = s['characters'].map { |spec| resolve_entry(entries, spec, nil) }
    selected.group_by { |e| [e[:game_code], e[:user_id].to_s.downcase] }.each do |(_, acct), group|
      next if group.size < 2
      fail! "#{group.map { |e| e[:char_name] }.join(' and ')} are on the same account (#{acct}). " \
            'Only one can be online at a time, so pick one.'
    end
  end

  # When logout is earlier in the day than login (e.g. log in 22:00, log out 02:00),
  # the logout happens the next day.
  def logout_days(s)
    return s['days'] unless s['logout_at'] && s['logout_at'] < s['login_at']
    s['days'].map { |d| DAYS[(DAYS.index(d) + 1) % 7] }
  end

  def describe_days(days)
    return 'Every day' if days.size == 7
    return 'Weekdays' if days.sort == %w[fri mon thu tue wed].sort
    return 'Weekends' if days.sort == %w[sat sun]
    DAYS.select { |d| days.include?(d) }.map(&:capitalize).join(', ')
  end

  # ---------- which scheduler ----------

  def install!(s)
    check_fields!(s)
    return win_install!(s) if Gem.win_platform?
    return mac_install!(s) if ChronoConfig.mac?

    linux_install!(s)
  end

  def uninstall!(s)
    return win_uninstall!(s) if Gem.win_platform?
    return mac_uninstall!(s) if ChronoConfig.mac?

    linux_uninstall!(s)
  end

  def scheduler_name
    return 'Task Scheduler' if Gem.win_platform?
    return 'launchd' if ChronoConfig.mac?

    'systemd timers'
  end

  # Chrono used to be called lichsched. Remove a schedule's tasks or timers made under the
  # old name, so it doesn't log characters in twice.
  def remove_legacy!(s)
    return if ChronoConfig.mac? # lichsched never ran on a Mac
    if Gem.win_platform?
      %w[login logout].each { |kind| delete_task("\\lichsched\\#{s['name']} #{kind}") }
    else
      changed = %w[login logout].map { |kind| linux_remove_base("lichsched-#{slug(s['name'])}-#{kind}") }.any?
      systemctl!('daemon-reload') if changed
    end
  end

  # ---------- Linux: systemd user timers ----------
  # Each schedule gets ~/.config/systemd/user/chrono-<slug>-login.{service,timer}
  # (and -logout when it has a logout time).

  UNIT_DIR = File.join(ENV['XDG_CONFIG_HOME'] || File.join(Dir.home, '.config'), 'systemd', 'user')
  SYSTEMD_DAYS = { 'sun' => 'Sun', 'mon' => 'Mon', 'tue' => 'Tue', 'wed' => 'Wed',
                   'thu' => 'Thu', 'fri' => 'Fri', 'sat' => 'Sat' }.freeze

  def slug(name)
    name.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')
  end

  def unit_base(s, kind)
    "chrono-#{slug(s['name'])}-#{kind}"
  end

  def systemctl(*args)
    out, status = Open3.capture2e('systemctl', '--user', *args)
    [out.strip, status]
  rescue Errno::ENOENT
    fail! "Couldn't run systemctl. Chrono's schedules need systemd, which Pop!_OS, Ubuntu, Fedora and most desktop Linux systems have."
  end

  def systemctl!(*args)
    out, status = systemctl(*args)
    fail! "systemctl --user #{args.join(' ')} failed:\n#{out}" unless status.success?
    out
  end

  # Quote one argument for an ExecStart= line. % starts a systemd specifier, so double it.
  def sd_quote(arg)
    %("#{arg.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub('%', '%%')}")
  end

  # A "job" is one thing to run on a timer: chrono.rb with job[:args], at job[:time] on job[:days].
  # job[:catch_up] runs it as soon as possible if the computer was off at that time.
  def schedule_job(s, kind)
    time, days = kind == 'login' ? [s['login_at'], s['days']] : [s['logout_at'], logout_days(s)]
    { description: "Chrono: #{kind} for schedule '#{s['name']}' (#{s['characters'].join(', ')})",
      args: ['run-schedule', kind, s['name'], '--notify'], time: time, days: days,
      enabled: s['enabled'] != false, catch_up: false }
  end

  def service_unit(job)
    check_job!(job)
    script = File.expand_path('chrono.rb', __dir__)
    exec = [rubyw_path, script, *job[:args]].map { |a| sd_quote(one_line(a)) }.join(' ')
    <<~UNIT
      [Unit]
      Description=#{one_line(job[:description]).gsub('%', '%%')}

      [Service]
      Type=oneshot
      WorkingDirectory=#{one_line(__dir__).gsub('%', '%%')}
      ExecStart=#{exec}
      TimeoutStartSec=12h
    UNIT
  end

  def timer_unit(base, job)
    check_job!(job)
    day_list = DAYS.select { |d| job[:days].include?(d) }.map { |d| SYSTEMD_DAYS[d] }.join(',')
    <<~UNIT
      [Unit]
      Description=#{one_line(job[:description]).gsub('%', '%%')} (timer)

      [Timer]
      OnCalendar=#{day_list} *-*-* #{job[:time]}:00
      AccuracySec=1s
      Persistent=#{job[:catch_up] ? 'true' : 'false'}
      Unit=#{base}.service

      [Install]
      WantedBy=timers.target
    UNIT
  end

  def linux_write_units(base, job)
    File.write(File.join(UNIT_DIR, "#{base}.service"), service_unit(job))
    File.write(File.join(UNIT_DIR, "#{base}.timer"), timer_unit(base, job))
    base
  end

  # Scheduled logins open game windows, so systemd needs this desktop session's display.
  def linux_prepare!
    FileUtils.mkdir_p(UNIT_DIR)
    vars = %w[DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS].select { |v| ENV[v] }
    systemctl!('import-environment', *vars) unless vars.empty?
  end

  def linux_activate!(base, enabled)
    if enabled
      systemctl!('enable', "#{base}.timer")
      systemctl!('restart', "#{base}.timer")
    else
      systemctl('disable', '--now', "#{base}.timer")
    end
    log "SCHEDULE timer saved: #{base}#{enabled ? '' : ' (off)'}"
  end

  def linux_remove_units(s, kind)
    linux_remove_base(unit_base(s, kind))
  end

  def linux_remove_base(base)
    timer = File.join(UNIT_DIR, "#{base}.timer")
    service = File.join(UNIT_DIR, "#{base}.service")
    return false unless File.exist?(timer) || File.exist?(service)
    systemctl('disable', '--now', "#{base}.timer") # fine if it was never enabled
    [timer, service].each { |f| File.delete(f) if File.exist?(f) }
    log "SCHEDULE timer removed: #{base}"
    true
  end

  def linux_install!(s)
    linux_prepare!
    kinds = s['logout_at'] ? %w[login logout] : %w[login]
    bases = kinds.map { |kind| linux_write_units(unit_base(s, kind), schedule_job(s, kind)) }
    linux_remove_units(s, 'logout') unless s['logout_at']
    systemctl!('daemon-reload')
    bases.each { |base| linux_activate!(base, s['enabled'] != false) }
  end

  def linux_uninstall!(s)
    changed = %w[login logout].map { |kind| linux_remove_units(s, kind) }.any?
    systemctl!('daemon-reload') if changed
  end

  # ---------- Windows scheduled tasks ----------

  def task_name(s, kind)
    "#{TASK_FOLDER}#{s['name']} #{kind}"
  end

  def win_install!(s)
    create_task(task_name(s, 'login'), task_xml(schedule_job(s, 'login')))
    if s['logout_at']
      create_task(task_name(s, 'logout'), task_xml(schedule_job(s, 'logout')))
    else
      delete_task(task_name(s, 'logout'))
    end
  end

  def win_uninstall!(s)
    delete_task(task_name(s, 'login'))
    delete_task(task_name(s, 'logout'))
  end

  def schtasks(*args)
    out, status = Open3.capture2e('schtasks', *args)
    [out.force_encoding(Encoding::BINARY).encode('UTF-8', invalid: :replace, undef: :replace).strip, status]
  rescue Errno::ENOENT
    fail! "Couldn't run schtasks.exe. It's part of Windows and should be in C:\\Windows\\System32."
  end

  def task_exists?(tn)
    _, status = schtasks('/Query', '/TN', tn)
    status.success?
  end

  def create_task(tn, xml)
    Dir.mktmpdir('chrono-task') do |dir| # a fresh private folder each time, removed afterwards
      path = File.join(dir, 'task.xml')
      File.binwrite(path, "\uFEFF#{xml}".encode('UTF-16LE'))
      out, status = schtasks('/Create', '/F', '/TN', tn, '/XML', path.tr('/', '\\'))
      fail! "Windows refused to create the scheduled task '#{tn}':\n#{out}" unless status.success?
    end
    log "SCHEDULE task saved: #{tn}"
  end

  def delete_task(tn)
    return unless task_exists?(tn)
    out, status = schtasks('/Delete', '/F', '/TN', tn)
    fail! "Windows refused to delete the scheduled task '#{tn}':\n#{out}" unless status.success?
    log "SCHEDULE task deleted: #{tn}"
  end

  def xml_escape(text)
    one_line(text).gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
  end

  # Windows command-line quoting for one argument.
  def win_quote(arg)
    arg.to_s.match?(/[\s"]/) || arg.to_s.empty? ? %("#{arg.to_s.gsub('"', '\\"')}") : arg.to_s
  end

  def task_xml(job)
    check_job!(job)
    command = rubyw_path.tr('/', '\\')
    script  = File.expand_path('chrono.rb', __dir__).tr('/', '\\')
    args    = [%("#{script}"), *job[:args].map { |a| win_quote(a) }].join(' ')
    user    = [ENV['USERDOMAIN'], ENV['USERNAME']].compact.join('\\')
    day_tags = DAYS.select { |d| job[:days].include?(d) }.map { |d| "<#{DAY_XML[d]} />" }.join
    time = job[:time]
    <<~XML
      <?xml version="1.0" encoding="UTF-16"?>
      <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
        <RegistrationInfo>
          <Description>#{xml_escape(job[:description])}</Description>
        </RegistrationInfo>
        <Triggers>
          <CalendarTrigger>
            <StartBoundary>#{Date.today.iso8601}T#{time}:00</StartBoundary>
            <Enabled>true</Enabled>
            <ScheduleByWeek>
              <DaysOfWeek>#{day_tags}</DaysOfWeek>
              <WeeksInterval>1</WeeksInterval>
            </ScheduleByWeek>
          </CalendarTrigger>
        </Triggers>
        <Principals>
          <Principal id="Author">
            <UserId>#{xml_escape(user)}</UserId>
            <LogonType>InteractiveToken</LogonType>
            <RunLevel>LeastPrivilege</RunLevel>
          </Principal>
        </Principals>
        <Settings>
          <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
          <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
          <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
          <AllowHardTerminate>true</AllowHardTerminate>
          <StartWhenAvailable>#{job[:catch_up] ? 'true' : 'false'}</StartWhenAvailable>
          <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
          <Enabled>#{job[:enabled] ? 'true' : 'false'}</Enabled>
          <Hidden>false</Hidden>
          <RunOnlyIfIdle>false</RunOnlyIfIdle>
          <WakeToRun>true</WakeToRun>
          <ExecutionTimeLimit>PT12H</ExecutionTimeLimit>
        </Settings>
        <Actions Context="Author">
          <Exec>
            <Command>#{xml_escape(command)}</Command>
            <Arguments>#{xml_escape(args)}</Arguments>
            <WorkingDirectory>#{xml_escape(__dir__.tr('/', '\\'))}</WorkingDirectory>
          </Exec>
        </Actions>
      </Task>
    XML
  end

  # ---------- Mac: launchd agents ----------
  # Each job is ~/Library/LaunchAgents/net.chrono4lich.<base>.plist, loaded into this user's
  # session (so a scheduled login can open game windows). launchd runs a job missed while the Mac
  # slept as soon as it wakes: wanted for rewards (catch_up); schedules pass --scheduled-for so a
  # late login or logout skips itself (see too_late? in chrono.rb).

  AGENT_DIR = File.join(Dir.home, 'Library', 'LaunchAgents')
  LABEL_PREFIX = 'net.chrono4lich.'
  LAUNCHD_DAYS = { 'sun' => 0, 'mon' => 1, 'tue' => 2, 'wed' => 3, 'thu' => 4, 'fri' => 5, 'sat' => 6 }.freeze
  MAC_PATH = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'

  def mac_label(base) = "#{LABEL_PREFIX}#{base}"
  def mac_plist_path(base) = File.join(AGENT_DIR, "#{mac_label(base)}.plist")

  # A property list (Apple's XML settings format) from a Hash of strings, numbers,
  # true/false, arrays and hashes.
  def plist_xml(hash)
    esc = ->(v) { one_line(v).gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;') }
    val = lambda do |v, ind|
      pad = '  ' * ind
      case v
      when Hash
        inner = v.map { |k, x| "#{pad}  <key>#{esc.call(k)}</key>\n#{val.call(x, ind + 1)}" }.join("\n")
        "#{pad}<dict>\n#{inner}\n#{pad}</dict>"
      when Array then "#{pad}<array>\n#{v.map { |x| val.call(x, ind + 1) }.join("\n")}\n#{pad}</array>"
      when true then "#{pad}<true/>"
      when false then "#{pad}<false/>"
      when Integer then "#{pad}<integer>#{v}</integer>"
      else "#{pad}<string>#{esc.call(v)}</string>"
      end
    end
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      #{val.call(hash, 0)}
      </plist>
    XML
  end

  def mac_job_plist(base, job)
    check_job!(job)
    h, m = job[:time].split(':').map(&:to_i)
    script = File.expand_path('chrono.rb', __dir__)
    args = [RbConfig.ruby, script, *job[:args]]
    args += ['--scheduled-for', job[:time]] unless job[:catch_up]
    plist_xml(
      'Label' => mac_label(base),
      'Comment' => job[:description],
      'ProgramArguments' => args,
      'WorkingDirectory' => __dir__,
      'EnvironmentVariables' => { 'PATH' => MAC_PATH, 'LANG' => ENV['LANG'] || 'en_US.UTF-8' },
      'StartCalendarInterval' => DAYS.select { |d| job[:days].include?(d) }
                                     .map { |d| { 'Weekday' => LAUNCHD_DAYS[d], 'Hour' => h, 'Minute' => m } },
      'ProcessType' => 'Interactive',
      'AbandonProcessGroup' => true, # Lich, started by a scheduled login, keeps running after it
      'StandardOutPath' => '/dev/null',
      'StandardErrorPath' => '/dev/null'
    )
  end

  def launchctl(*args)
    out, status = Open3.capture2e('launchctl', *args)
    [out.strip, status]
  rescue SystemCallError
    fail! "Couldn't run launchctl, which schedules jobs on a Mac."
  end

  def mac_unload(base)
    launchctl('bootout', "gui/#{Process.uid}/#{mac_label(base)}") # fine if it wasn't loaded
    launchctl('unload', mac_plist_path(base)) # (older macOS)
  end

  # Writes the job and, if enabled, loads it. A disabled job's file is removed, because macOS
  # loads every file in LaunchAgents at sign-in.
  def mac_write_job(base, job)
    mac_unload(base)
    path = mac_plist_path(base)
    unless job[:enabled]
      File.delete(path) if File.exist?(path)
      log "SCHEDULE launchd job off: #{mac_label(base)}"
      return base
    end
    FileUtils.mkdir_p(AGENT_DIR)
    File.write(path, mac_job_plist(base, job))
    out, status = launchctl('bootstrap', "gui/#{Process.uid}", path)
    unless status.success?
      out2, status2 = launchctl('load', '-w', path) # older macOS
      fail! "launchctl couldn't load #{File.basename(path)}:\n#{out}\n#{out2}" unless status2.success?
    end
    log "SCHEDULE launchd job saved: #{mac_label(base)}"
    base
  end

  def mac_remove(base)
    path = mac_plist_path(base)
    return false unless File.exist?(path)

    mac_unload(base)
    File.delete(path)
    log "SCHEDULE launchd job removed: #{mac_label(base)}"
    true
  end

  def mac_install!(s)
    kinds = s['logout_at'] ? %w[login logout] : %w[login]
    kinds.each { |kind| mac_write_job(unit_base(s, kind), schedule_job(s, kind)) }
    mac_remove(unit_base(s, 'logout')) unless s['logout_at']
  end

  def mac_uninstall!(s)
    %w[login logout].each { |kind| mac_remove(unit_base(s, kind)) }
  end

end
