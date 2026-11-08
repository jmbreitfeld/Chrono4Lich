# chrono_schedule.rb - saved schedules and the Windows scheduled tasks that run them.
# Loaded by chrono.rb; needs its helpers (fail!, STATE_DIR, rubyw_path, load_entries ...).
#
# Each schedule becomes up to two tasks in Task Scheduler, in a "Chrono4Lich" folder:
#   "\Chrono4Lich\<name> login"   runs: rubyw chrono.rb run-schedule login "<name>" --notify
#   "\Chrono4Lich\<name> logout"  runs: rubyw chrono.rb run-schedule logout "<name>" --notify

require 'json'
require 'open3'
require 'date'

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
    FileUtils.mkdir_p(STATE_DIR)
    tmp = FILE + '.tmp'
    File.write(tmp, JSON.pretty_generate(list.sort_by { |s| s['name'].downcase }))
    File.rename(tmp, FILE)
  end

  def find(name)
    load.find { |s| s['name'].casecmp?(name) } or fail! "No schedule named '#{name}'."
  end

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
    Gem.win_platform? ? win_install!(s) : linux_install!(s)
  end

  def uninstall!(s)
    Gem.win_platform? ? win_uninstall!(s) : linux_uninstall!(s)
  end

  def scheduler_name
    Gem.win_platform? ? 'Task Scheduler' : 'systemd timers'
  end

  # Chrono used to be called lichsched. Remove a schedule's tasks or timers made under the
  # old name, so it doesn't log characters in twice.
  def remove_legacy!(s)
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
    script = File.expand_path('chrono.rb', __dir__)
    exec = [rubyw_path, script, *job[:args]].map { |a| sd_quote(a) }.join(' ')
    <<~UNIT
      [Unit]
      Description=#{job[:description].gsub('%', '%%')}

      [Service]
      Type=oneshot
      WorkingDirectory=#{__dir__.gsub('%', '%%')}
      ExecStart=#{exec}
      TimeoutStartSec=12h
    UNIT
  end

  def timer_unit(base, job)
    day_list = DAYS.select { |d| job[:days].include?(d) }.map { |d| SYSTEMD_DAYS[d] }.join(',')
    <<~UNIT
      [Unit]
      Description=#{job[:description].gsub('%', '%%')} (timer)

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
    FileUtils.mkdir_p(STATE_DIR)
    path = File.join(STATE_DIR, 'task.xml')
    File.binwrite(path, "\uFEFF#{xml}".encode('UTF-16LE'))
    out, status = schtasks('/Create', '/F', '/TN', tn, '/XML', path.tr('/', '\\'))
    fail! "Windows refused to create the scheduled task '#{tn}':\n#{out}" unless status.success?
    log "SCHEDULE task saved: #{tn}"
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def delete_task(tn)
    return unless task_exists?(tn)
    out, status = schtasks('/Delete', '/F', '/TN', tn)
    fail! "Windows refused to delete the scheduled task '#{tn}':\n#{out}" unless status.success?
    log "SCHEDULE task deleted: #{tn}"
  end

  def xml_escape(text)
    text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
  end

  # Windows command-line quoting for one argument.
  def win_quote(arg)
    arg.to_s.match?(/[\s"]/) || arg.to_s.empty? ? %("#{arg.to_s.gsub('"', '\\"')}") : arg.to_s
  end

  def task_xml(job)
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
end
