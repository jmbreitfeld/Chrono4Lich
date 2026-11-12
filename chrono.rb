# chrono.rb - command-line login/logout for one or more Lich5 characters
# (also loaded by chrono_gui.rbw for its helpers)
#
# Usage (run with the same Ruby that runs Lich, or through chrono.bat):
#   chrono list
#   chrono status
#   chrono login  Name [Name2 ...] [--realm prime|platinum|shattered] [--scripts a,b] [--timeout 120] [--gap 2]
#   chrono logout Name [Name2 ...] | all   [--timeout 90]
#   chrono kill   Name        (force-closes Lich; character may stay linkdead in game)
#   chrono config             (shows which Lich folder and Ruby are used)
#   chrono set-lich-dir "C:\path\to\Lich5"
#
# A name can carry its realm, e.g. Peggyanne:platinum. Without one, the realm is
# found from entry.dat; --realm is only needed when a name is saved in more than one realm.
#
# chrono_helper.lic (kept next to this file) is copied into the Lich scripts folder
# automatically whenever it's missing or out of date.

require 'json'
require 'fileutils'
require 'rbconfig'

# Chrono's version. The GitHub release build stamps the release's version here.
CHRONO_VERSION = '1.8.0'
require 'optparse'
require_relative 'chrono_config'

begin
  LICH_DIR = ChronoConfig.lich_dir
  LICH_DIR_PROBLEM = LICH_DIR ? nil : 'Chrono doesn\'t know where Lich is installed yet.'
rescue RuntimeError => e
  LICH_DIR = nil
  LICH_DIR_PROBLEM = e.message
end
DATA_DIR   = LICH_DIR && File.join(LICH_DIR, 'data')
SCRIPT_DIR = LICH_DIR && File.join(LICH_DIR, 'scripts')
STATE_DIR  = LICH_DIR && File.join(DATA_DIR, 'chrono')
require_relative 'chrono_eaccess'
require_relative 'chrono_logins'
HELPER     = 'chrono_helper'
HEARTBEAT_STALE = 45 # seconds
ACK_TIMEOUT     = 20 # seconds for the helper to pick up a logout request

# realm => [game code in entry.dat, extra lich.rbw flags]
REALMS = {
  'prime'     => ['GS3', []],
  'platinum'  => ['GSX', ['--platinum']],
  'shattered' => ['GSF', ['--shattered']],
  'test'      => ['GST', ['--test']]
}.freeze
GAME_TO_REALM = REALMS.map { |realm, (code, _)| [code, realm] }.to_h

class Fail < StandardError; end

def fail!(msg)
  raise Fail, msg
end

ERRORS_SEEN = [] # every error logged this run, for the --notify pop-up

def log(msg, io = $stdout)
  line = "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}  #{msg}"
  if STATE_DIR
    FileUtils.mkdir_p(STATE_DIR)
    File.open(File.join(STATE_DIR, 'chrono.log'), 'a') { |f| f.puts line }
  end
  ERRORS_SEEN << msg.sub(/\A!!! /, '') if io == $stderr
  begin
    io.puts line
  rescue IOError, SystemCallError
    nil # no console (scheduled run under rubyw); the log file above has it
  end
end

# Pop-up for scheduled runs, so a failure at 6 AM isn't silent.
def notify_box(title, text)
  return notify_linux(title, text) unless Gem.win_platform?
  require 'fiddle'
  box = Fiddle::Function.new(Fiddle.dlopen('user32')['MessageBoxW'],
                             [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
                             Fiddle::TYPE_INT)
  wtext  = "#{text}\0".encode('UTF-16LE')
  wtitle = "#{title}\0".encode('UTF-16LE')
  box.call(Fiddle::NULL, wtext, wtitle, 0x10 | 0x10000 | 0x40000) # error icon, foreground, topmost
end

# Linux: a desktop notification that stays until dismissed; zenity as a fallback.
def notify_linux(title, text)
  tools = [
    ['notify-send', '--urgency=critical', '--app-name=Chrono', title, text],
    ['zenity', '--error', '--no-wrap', "--title=#{title}", "--text=#{text}"]
  ]
  tools.each do |cmd|
    next unless system('sh', '-c', "command -v #{cmd.first} >/dev/null 2>&1")
    pid = Process.spawn(*cmd, in: File::NULL, out: File::NULL, err: File::NULL)
    Process.detach(pid)
    return
  end
  log 'Could not show a notification: neither notify-send nor zenity is installed.', $stderr
end

# ---------- saved logins ----------

# Saved logins without passwords, from entry.yaml (newer Lich) or entry.dat (older Lich).
def load_entries
  unless File.exist?(SavedLogins.yaml_file) || File.exist?(SavedLogins.dat_file)
    fail! "No saved logins in #{ChronoConfig.disp(DATA_DIR)} yet. Add them on Chrono's Logins tab " \
          '(or "chrono add-login ACCOUNT"), or save them in Lich\'s login window.'
  end
  SavedLogins.entries
end

def realm_of(entry)
  GAME_TO_REALM[entry[:game_code]] || entry[:game_code].to_s
end

# spec is "Name" or "Name:realm"
def resolve_entry(entries, spec, default_realm)
  name, realm = spec.split(':', 2)
  realm = (realm || default_realm)&.downcase
  if realm && !REALMS.key?(realm)
    fail! "Unknown realm '#{realm}' for #{name}. Use prime, platinum or shattered."
  end
  matches = entries.select { |d| d[:char_name].to_s.casecmp?(name) }
  fail! "#{name} isn't in your saved logins. Run 'list' to see them, or add it on the Logins tab." if matches.empty?
  realms = matches.map { |m| realm_of(m) }.uniq
  if realm
    fail! "#{name} is saved, but not for #{realm} (saved for: #{realms.join(', ')})." unless realms.include?(realm)
  elsif realms.size > 1
    fail! "#{name} is saved in more than one realm (#{realms.join(', ')}). " \
          "Write it as #{name}:#{realms.first}, for example."
  else
    realm = realms.first
  end
  same_realm = matches.select { |m| realm_of(m) == realm }
  # The same character saved more than once (e.g. once per frontend) is fine if it's
  # the same account. Lich's --login picks the entry itself.
  accounts = same_realm.map { |m| m[:user_id].to_s.downcase }.uniq
  if accounts.size > 1
    fail! "#{name} (#{realm}) is saved more than once under different accounts (#{accounts.join(', ')}). " \
          "Remove the wrong one in Lich's login window."
  end
  same_realm.first
end

# ---------- status files written by the helper ----------

def status_path(name)
  File.join(STATE_DIR, "#{name.capitalize}.status.json")
end

def cmd_path(name)
  File.join(STATE_DIR, "#{name.capitalize}.cmd")
end

def read_status(name)
  path = status_path(name)
  return nil unless File.exist?(path)
  attempts = 0
  begin
    JSON.parse(File.read(path))
  rescue Errno::EACCES, Errno::ENOENT, JSON::ParserError
    attempts += 1
    raise if attempts >= 5
    sleep 0.2
    retry
  end
end

# Asks Windows directly whether a process is running and is Ruby (Lich).
# Avoids shelling out to tasklist, which flashes a console window when run from the GUI.
module WinProc
  require 'fiddle'
  K32 = Fiddle.dlopen('kernel32')
  VP = Fiddle::TYPE_VOIDP
  IN = Fiddle::TYPE_INT
  OpenProcess        = Fiddle::Function.new(K32['OpenProcess'], [IN, IN, IN], VP)
  GetExitCodeProcess = Fiddle::Function.new(K32['GetExitCodeProcess'], [VP, VP], IN)
  QueryImageName     = Fiddle::Function.new(K32['QueryFullProcessImageNameW'], [VP, IN, VP, VP], IN)
  CloseHandle        = Fiddle::Function.new(K32['CloseHandle'], [VP], IN)
  QUERY_LIMITED = 0x1000
  STILL_ACTIVE  = 259

  def self.ruby_running?(pid)
    handle = OpenProcess.call(QUERY_LIMITED, 0, pid)
    return false if handle.null? # no such process (or not ours)
    begin
      code = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
      fail! "GetExitCodeProcess failed for PID #{pid}." if GetExitCodeProcess.call(handle, code).zero?
      return false unless code[0, 4].unpack1('L') == STILL_ACTIVE
      buf  = Fiddle::Pointer.malloc(2048, Fiddle::RUBY_FREE)
      size = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
      size[0, 4] = [1024].pack('L')
      fail! "QueryFullProcessImageNameW failed for PID #{pid}." if QueryImageName.call(handle, 0, buf, size).zero?
      path = buf[0, size[0, 4].unpack1('L') * 2].force_encoding('UTF-16LE').encode('UTF-8')
      File.basename(path).match?(/ruby/i)
    ensure
      CloseHandle.call(handle)
    end
  end
end if Gem.win_platform?

def pid_alive?(pid)
  return false unless pid.is_a?(Integer) && pid > 0
  return WinProc.ruby_running?(pid) if defined?(WinProc)
  return linux_ruby_running?(pid) unless Gem.win_platform?
  out = `tasklist /FI "PID eq #{pid}" /NH /FO CSV 2>NUL`
  out.lines.any? do |l|
    cols = l.strip.delete_prefix('"').split('","')
    cols[1].to_i == pid && cols[0] =~ /ruby/i
  end
end

# Linux: the process exists, isn't a finished (zombie) process, and is Ruby.
def linux_ruby_running?(pid)
  stat = File.read("/proc/#{pid}/stat")
  return false if stat.sub(/\A.*\)\s*/m, '').start_with?('Z')
  args = File.binread("/proc/#{pid}/cmdline").split("\0")
  args.first(2).any? { |a| File.basename(a).match?(/\Aruby/) } || args.any? { |a| a.end_with?('lich.rbw') }
rescue Errno::ENOENT, Errno::ESRCH
  false
end

def online?(name)
  st = read_status(name)
  st && st['state'] != 'offline' && pid_alive?(st['pid'])
end

def heartbeat_age(st)
  Time.now.to_i - st['heartbeat'].to_i
end

def online_names
  Dir.glob(File.join(STATE_DIR, '*.status.json')).map { |f| File.basename(f, '.status.json') }.select { |n| online?(n) }
end

# ---------- launching ----------

def rubyw_path
  c = RbConfig::CONFIG
  exe = c['RUBYW_INSTALL_NAME'].to_s.empty? ? c['RUBY_INSTALL_NAME'] : c['RUBYW_INSTALL_NAME']
  path = File.join(c['bindir'], exe + c['EXEEXT'])
  fail! "Can't find Ruby at #{path}." unless File.exist?(path)
  path
end

# Print a summary and return true if everything succeeded.
def summarize(action, results)
  return results.values.all?(&:nil?) if results.size <= 1
  puts
  puts "#{action} summary:"
  results.each do |name, err|
    puts format('  %-16s %s', name, err ? "FAILED - #{err}" : 'ok')
  end
  failed = results.count { |_, e| e }
  log "#{action.upcase} SUMMARY: #{results.size - failed} ok, #{failed} failed", failed > 0 ? $stderr : $stdout
  failed.zero?
end

# ---------- commands ----------

def cmd_list
  entries = load_entries
  if entries.empty?
    puts 'No characters are saved yet.'
    return
  end
  puts format('%-16s %-10s %-20s %-16s %s', 'Character', 'Realm', 'Account', 'Frontend', 'Online')
  groups = entries.group_by { |e| [e[:game_code], e[:char_name].to_s.downcase, e[:user_id].to_s.downcase] }
  groups.values.map(&:first).sort_by { |e| [e[:game_code].to_s, e[:char_name].to_s] }.each do |e|
    fronts = groups[[e[:game_code], e[:char_name].to_s.downcase, e[:user_id].to_s.downcase]].map { |x| x[:frontend] }.uniq
    puts format('%-16s %-10s %-20s %-16s %s', e[:char_name], realm_of(e), e[:user_id], fronts.join(','),
                online?(e[:char_name].to_s) ? 'yes' : '')
  end
end

# ---------- saved-login commands (passwords are typed at a prompt, never on the command line) ----------

def ask_password(prompt)
  require 'io/console'
  fail! 'This command needs a terminal to type the password into.' unless $stdin.tty?
  $stdout.print prompt
  pw = $stdin.noecho(&:gets).to_s.chomp
  $stdout.puts
  pw
end

def cmd_add_login(account, frontend)
  fail! 'Use: chrono add-login ACCOUNT [--frontend NAME]' unless account
  password = ask_password("Password for #{account}: ")
  puts 'Asking Simutronics for the characters on this account...'
  chars = ChronoEAccess.list_characters(account, password, data_dir: DATA_DIR)
  fail! "Account #{account} has no GemStone characters in a game it's subscribed to." if chars.empty?
  saved = load_entries rescue []
  chars.each_with_index do |c, i|
    already = saved.any? { |e| e[:char_name].casecmp?(c[:char_name]) && e[:game_code] == c[:game_code] }
    puts format('  %2d) %-16s %-10s%s', i + 1, c[:char_name], GAME_TO_REALM[c[:game_code]] || c[:game_code],
                already ? ' (already saved)' : '')
  end
  $stdout.print 'Which to save? Numbers separated by spaces, or "all": '
  answer = $stdin.gets.to_s.strip.downcase
  picked = answer == 'all' ? chars : answer.split(/[\s,]+/).map { |n| chars[Integer(n) - 1] rescue nil }.compact
  fail! 'Nothing picked, nothing saved.' if picked.empty?
  frontend ||= SavedLogins.frontends.first
  unless SavedLogins.frontends.include?(frontend)
    fail! "Unknown frontend '#{frontend}'. Choose from: #{SavedLogins.frontends.join(', ')}"
  end
  n = SavedLogins.add(account, password, picked, frontend)
  puts "Saved #{n} character(s) with frontend #{frontend}."
  true
end

def cmd_change_password(account)
  fail! 'Use: chrono change-password ACCOUNT' unless account
  password = ask_password("New password for #{account}: ")
  puts 'Checking it with Simutronics...'
  ChronoEAccess.list_characters(account, password, data_dir: DATA_DIR)
  SavedLogins.change_password(account, password)
  puts "Saved the new password for #{account}."
  true
end

# Refuses to remove a saved login that a schedule uses or that's online right now.
def check_removable!(entry)
  spec = "#{entry[:char_name]}:#{realm_of(entry)}"
  in_use = Schedules.load.select { |s| s['characters'].any? { |c| c.casecmp?(spec) } }
  unless in_use.empty?
    fail! "#{entry[:char_name]} is in the schedule(s) #{in_use.map { |s| s['name'] }.join(', ')}. " \
          'Take them out of those schedules first.'
  end
  fail! "#{entry[:char_name]} is online. Log them out first." if online?(entry[:char_name])
end

def cmd_remove_login(spec)
  fail! 'Use: chrono remove-login Name[:realm]' unless spec
  entry = resolve_entry(load_entries, spec, nil)
  check_removable!(entry)
  SavedLogins.remove(entry[:char_name], entry[:game_code], entry[:user_id])
  puts "Removed #{entry[:char_name]} (#{realm_of(entry)})."
  true
end

def cmd_status
  files = Dir.glob(File.join(STATE_DIR, '*.status.json'))
  if files.empty?
    puts 'No characters have been started by Chrono yet.'
    return
  end
  puts format('%-16s %-14s %-8s %-8s %s', 'Character', 'State', 'PID', 'Process', 'Heartbeat')
  files.sort.each do |f|
    st = JSON.parse(File.read(f))
    alive = pid_alive?(st['pid'])
    beat = alive ? "#{heartbeat_age(st)}s ago" : '-'
    puts format('%-16s %-14s %-8s %-8s %s', st['name'], st['state'], st['pid'], alive ? 'running' : 'gone', beat)
    puts "    #{st['detail']}" if st['detail']
  end
end

def check_account_conflicts(entries, selected)
  # Two selected characters on the same account: refuse before launching anything.
  selected.group_by { |e| [e[:game_code], e[:user_id].to_s.downcase] }.each do |(_, acct), group|
    next if group.size < 2
    fail! "#{group.map { |e| e[:char_name] }.join(' and ')} are on the same account (#{acct}). " \
          'Only one can be online at a time, so pick one.'
  end
  # A selected character whose account already has someone else online.
  selected.each do |entry|
    entries.each do |other|
      next if other.equal?(entry) || selected.include?(other)
      next if other[:char_name].to_s.casecmp?(entry[:char_name].to_s) # duplicate save of the same character
      next unless other[:game_code] == entry[:game_code]
      next unless other[:user_id].to_s.casecmp?(entry[:user_id].to_s)
      if online?(other[:char_name].to_s)
        fail! "#{other[:char_name]} is online on the same account as #{entry[:char_name]} (#{entry[:user_id]}). " \
              "Logging in #{entry[:char_name]} would kick it off. Log #{other[:char_name]} out first."
      end
    end
  end
end

# A character saved both for Warlock and for another frontend: Lich would pick one of them
# itself, so ask it for the Warlock one. (With only one saved login, nothing extra is needed.)
def warlock_flag(entry)
  same = (load_entries rescue []).select do |e|
    e[:char_name].to_s.casecmp?(entry[:char_name].to_s) && e[:game_code] == entry[:game_code]
  end
  fronts = same.map { |e| e[:frontend] }.uniq
  fronts.include?(SavedLogins::WARLOCK) && fronts.size > 1 ? ['--custom-launch=warlock'] : []
end

# Starts Lich for one character and returns its PID; doesn't wait for it to come online.
def start_login(entry, scripts)
  name = entry[:char_name]
  realm = realm_of(entry)
  fail! "#{name} is already online (Lich PID #{read_status(name)['pid']})." if online?(name)

  [cmd_path(name), status_path(name)].each { |p| File.delete(p) if File.exist?(p) }
  start_scripts = ([HELPER] + scripts).uniq.join(',')
  args = [rubyw_path, File.join(LICH_DIR, 'lich.rbw'), '--gemstone', *REALMS[realm][1],
          '--login', name, *warlock_flag(entry), "--start-scripts=#{start_scripts}"]

  log "LOGIN  #{name} (#{realm}): starting Lich"
  # Lich must not inherit our stdout/stderr: if they are a pipe (the GUI), Lich would hold
  # it open for as long as the character is online and the GUI would wait forever.
  group = Gem.win_platform? ? { new_pgroup: true } : { pgroup: true }
  # On Linux, a scheduled run is a systemd service, and systemd stops everything the
  # service started once it finishes. Starting Lich in its own scope keeps it running.
  if !Gem.win_platform? && ENV['INVOCATION_ID']
    fail! 'systemd-run is missing, so a scheduled login could not keep Lich running.' unless
      system('sh', '-c', 'command -v systemd-run >/dev/null 2>&1')
    args = ['systemd-run', '--user', '--scope', '--quiet', '--collect',
            "--unit=chrono-lich-#{name.downcase}-#{Time.now.to_i}", *args]
  end
  pid = Process.spawn(*args, chdir: LICH_DIR, **group,
                      in: File::NULL, out: File::NULL, err: File::NULL)
  Process.detach(pid)
  pid
end

# nil while still logging in, :online, or raises Fail
def login_progress(name, pid, deadline, timeout)
  st = read_status(name)
  if st && st['state'] == 'online'
    log "LOGIN  #{name}: online (Lich PID #{st['pid']})"
    return :online
  end
  unless pid_alive?(pid)
    fail! "Lich exited before #{name} came online. Check Lich's debug log in #{File.join(LICH_DIR, 'temp')}."
  end
  return nil if Time.now < deadline
  fail! "did not report online within #{timeout}s. Lich (PID #{pid}) is still running, " \
        "so the login may be stuck or the helper didn't start. Check that character's game window."
end

def cmd_login(specs, default_realm, scripts, timeout, gap, skip_online: false)
  entries = load_entries
  selected = specs.map { |s| resolve_entry(entries, s, default_realm) }.uniq
  fail! "lich.rbw not found at #{File.join(LICH_DIR, 'lich.rbw')}." unless File.exist?(File.join(LICH_DIR, 'lich.rbw'))
  ensure_helper!
  check_account_conflicts(entries, selected)
  FileUtils.mkdir_p(STATE_DIR)

  # All characters log in at the same time, like ticking several in Lich's login window:
  # each Lich is started a few seconds after the previous one (so they don't all hit
  # Simutronics' login server and Lich's own files at the same instant), without waiting
  # for the previous one to finish logging in. Then Chrono waits for all of them.
  results = {}
  waiting = {} # name => [pid, deadline]
  check = lambda do
    waiting.to_a.each do |name, (pid, deadline)|
      next unless login_progress(name, pid, deadline, timeout)
      results[name] = nil
      waiting.delete(name)
    rescue Fail => e
      log "!!! LOGIN #{name} FAILED: #{e.message}", $stderr
      results[name] = e.message
      waiting.delete(name)
    end
  end
  launched = 0
  selected.each do |entry|
    name = entry[:char_name]
    if skip_online && online?(name.to_s)
      log "LOGIN  #{name}: already online, skipped"
      results[name] = nil
      next
    end
    if launched > 0
      gap.times { check.call; sleep 1 }
    end
    launched += 1
    begin
      waiting[name] = [start_login(entry, scripts), Time.now + timeout]
    rescue Fail => e
      log "!!! LOGIN #{name} FAILED: #{e.message}", $stderr
      results[name] = e.message
    end
  end
  until waiting.empty?
    check.call
    sleep 1 unless waiting.empty?
  end
  # summary in the order the characters were picked
  summarize('Login', selected.map { |e| e[:char_name] }.select { |n| results.key?(n) }.to_h { |n| [n, results[n]] })
end

def request_logout(name)
  st = read_status(name)
  fail! "no status. It wasn't started by Chrono, or the helper never ran." unless st
  fail! "Lich process (PID #{st['pid']}) isn't running. Last known state: #{st['state']}." unless pid_alive?(st['pid'])
  unless %w[online logout_failed].include?(st['state'])
    fail! "state is '#{st['state']}', not online. If the helper was stopped, restart it with ;#{HELPER} in that character's window."
  end
  if heartbeat_age(st) > HEARTBEAT_STALE
    fail! "helper hasn't checked in for #{heartbeat_age(st)}s. Restart it with ;#{HELPER} in that character's window."
  end
  tmp = cmd_path(name) + '.tmp'
  File.write(tmp, 'logout')
  File.rename(tmp, cmd_path(name))
  log "LOGOUT #{name}: logout requested"
  st
end

def cmd_logout(specs, timeout, skip_offline: false)
  names =
    if specs.map(&:downcase) == ['all']
      online_names.tap { |n| fail! 'No characters started by Chrono are online.' if n.empty? }
    else
      specs.map { |s| s.split(':', 2).first.capitalize }.uniq
    end

  results = {}
  pending = {}
  names.each do |name|
    if skip_offline && !online?(name)
      log "LOGOUT #{name}: already offline, skipped"
      results[name] = nil
      next
    end
    pending[name] = { st: request_logout(name), sent: Time.now }
  rescue Fail => e
    log "!!! LOGOUT #{name} FAILED: #{e.message}", $stderr
    results[name] = e.message
  end

  deadline = Time.now + timeout
  until pending.empty? || Time.now > deadline
    pending.dup.each do |name, info|
      err = nil
      if !pid_alive?(info[:st]['pid'])
        log "LOGOUT #{name}: logged out"
      elsif (cur = read_status(name)) && cur['state'] == 'logout_failed' && !File.exist?(cmd_path(name))
        err = "could not log out. #{cur['detail']}"
      elsif File.exist?(cmd_path(name)) && Time.now - info[:sent] > ACK_TIMEOUT
        File.delete(cmd_path(name))
        err = "helper didn't pick up the logout request within #{ACK_TIMEOUT}s."
      else
        next
      end
      log("!!! LOGOUT #{name} FAILED: #{err}", $stderr) if err
      results[name] = err
      pending.delete(name)
    end
    sleep 1
  end
  pending.each_key do |name|
    err = "still connected after #{timeout}s. Last helper note: #{read_status(name)&.fetch('detail', nil)}"
    log "!!! LOGOUT #{name} FAILED: #{err}", $stderr
    results[name] = err
  end
  summarize('Logout', names.to_h { |n| [n, results[n]] })
end

def cmd_kill(name)
  name = name.split(':', 2).first.capitalize
  st = read_status(name)
  fail! "No status for #{name}." unless st
  fail! "#{name}'s Lich process (PID #{st['pid']}) isn't running." unless pid_alive?(st['pid'])
  log "KILL   #{name}: force-closing Lich PID #{st['pid']} and its frontend. The character may stay linkdead in game."
  if Gem.win_platform?
    ok = system('taskkill', '/PID', st['pid'].to_s, '/T', '/F')
    fail! "taskkill failed for PID #{st['pid']}." unless ok
  else
    kill_linux(st['pid'])
  end
  log "KILL   #{name}: done"
  true
end

# Lich runs in its own process group, so signal the whole group (Lich and its frontend).
def kill_linux(pid)
  target = Process.getpgid(pid) == pid ? -pid : pid
  Process.kill('TERM', target)
  10.times do
    return unless pid_alive?(pid)
    sleep 0.5
  end
  Process.kill('KILL', target)
  sleep 0.5
  fail! "PID #{pid} is still running after a forced kill." if pid_alive?(pid)
rescue Errno::ESRCH
  nil # already gone
rescue Errno::EPERM
  fail! "Not allowed to stop PID #{pid}; it may belong to another user."
end

# ---------- main ----------

# Keeps the Lich scripts folder's copy of the helper the same as the one shipped with Chrono.
def ensure_helper!
  bundled = File.join(ChronoConfig::APP_DIR, "#{HELPER}.lic")
  target  = File.join(SCRIPT_DIR, "#{HELPER}.lic")
  fail! "Lich's scripts folder is missing: #{SCRIPT_DIR}" unless File.directory?(SCRIPT_DIR)
  if File.exist?(bundled)
    return if File.exist?(target) && File.binread(target) == File.binread(bundled)
    FileUtils.cp(bundled, target)
    log "Installed #{HELPER}.lic into #{SCRIPT_DIR}"
  elsif !File.exist?(target)
    fail! "#{HELPER}.lic is missing. It should be in #{ChronoConfig::APP_DIR}, next to chrono.rb."
  end
end

def require_lich_dir!
  return if LICH_DIR
  fail! "#{LICH_DIR_PROBLEM} Open the Chrono window to pick the Lich folder, or run: " \
        "chrono set-lich-dir \"#{ChronoConfig.example_lich_dir}\""
end

def cmd_config
  puts "Lich folder:  #{LICH_DIR ? ChronoConfig.disp(LICH_DIR) : "(not set) #{LICH_DIR_PROBLEM}"}"
  puts "Ruby:         #{ChronoConfig.disp(rubyw_path)}"
  puts "Config file:  #{ChronoConfig.disp(ChronoConfig::CONFIG_FILE)}"
  found = ChronoConfig.detect
  puts "Lich folders found on this PC: #{found.empty? ? 'none' : ''}"
  found.each { |d| puts "  #{ChronoConfig.disp(d)}" }
  true
end

def cmd_set_lich_dir(dir)
  fail! "Use: chrono set-lich-dir \"#{ChronoConfig.example_lich_dir}\"" unless dir
  fail! ChronoConfig.why_invalid(dir) unless ChronoConfig.valid_lich_dir?(dir)
  ChronoConfig.save('lich_dir' => ChronoConfig.normalize(dir))
  puts "Lich folder set to #{ChronoConfig.disp(ChronoConfig.normalize(dir))}"
  true
end

# Used by the installer after an upgrade, so tasks point at the current Ruby and files.
def cmd_rebuild_tasks
  return (puts('No Lich folder set yet, so there are no schedules to rebuild.') || true) unless LICH_DIR
  list = Schedules.load
  list.each { |s| Schedules.install!(s) }
  rewards = Rewards.load
  Rewards.install_task!(rewards) if rewards['enabled']
  log "Rebuilt the scheduled tasks for #{list.size} schedule(s)#{rewards['enabled'] ? ' and daily rewards' : ''}."
  true
end

# Used by the uninstaller. Schedules stay saved in the Lich data folder, so a reinstall
# followed by "Rebuild scheduled tasks" brings them back.
def cmd_remove_tasks
  return (puts('No Lich folder set, so there are no schedules to remove.') || true) unless LICH_DIR
  list = Schedules.load
  list.each { |s| Schedules.uninstall!(s) }
  Rewards.uninstall_task!
  log "Removed the scheduled tasks for #{list.size} schedule(s) and daily rewards."
  true
end

# ---------- rewards commands ----------

def cmd_run_rewards(accounts)
  log "REWARDS run starting#{accounts.empty? ? '' : " for #{accounts.join(', ')}"}"
  ok = Rewards.run(accounts)
  log(ok ? 'REWARDS run finished.' : '!!! REWARDS run finished with problems (details above).', ok ? $stdout : $stderr)
  ok
end

def cmd_rewards
  data = Rewards.load
  puts "Daily rewards: #{data['enabled'] ? "on, every day at #{data['time']}" : "off (would run at #{data['time']})"}"
  list = Rewards.accounts(data)
  puts 'No saved accounts yet.' if list.empty?
  list.each do |a|
    puts format('  %-16s SimuCoins %-4s Daily logins %-4s Claim on %-7s %s', a[:name], a[:coins] ? 'on' : 'off',
                a[:daily] ? 'on' : 'off', a[:where] == 'github' ? 'GitHub' : 'this PC',
                a[:where] == 'github' ? '' : Rewards.summary(a[:last]))
  end
  gh = Rewards.github_state(data)
  if gh && !gh['stopped']
    puts "GitHub: github.com/#{gh['repo']} (#{Array(gh['accounts']).join(', ')}), set up #{Time.at(gh['at']).strftime('%b %-d %-I:%M %p')}. " \
         "Results: #{ChronoGitHub.actions_url(gh['repo'])}"
  end
  if (ex = Rewards.exact_state(data))
    puts "Exact timing: cron-job.org starts the GitHub run at #{ex['time']} (#{ex['tz']}); GitHub's own schedule is a backup " \
         "at #{ChronoGitHub.backup_time(ex['time'])}."
  end
  why = Rewards.github_needs_update(data)
  puts "GitHub needs updating: #{why}. Run: chrono github-setup" if why
  why = Rewards.exact_needs_update(data)
  puts "Exact timing needs updating: #{why}. Run: chrono exact-setup" if why
  true
end

def ask_line(prompt)
  fail! 'This command needs a terminal to type into.' unless $stdin.tty?
  $stdout.print prompt
  $stdin.gets.to_s.strip
end

# chrono exact-setup: sets up (or, after the time changed, updates) cron-job.org starting the
# GitHub run at the exact time. Asks for the GitHub token and the cron-job.org API key.
def cmd_exact_setup
  gh = Rewards.github_state
  fail! 'Set up GitHub first: chrono github-setup' unless gh && gh['repo'] && !gh['stopped']
  if Rewards.exact_state && Rewards.exact_needs_update
    key = ask_password('cron-job.org API key (cron-job.org > Settings > API): ')
    Rewards.exact_update_time!(key)
    puts "cron-job.org now starts the run at #{Rewards.load['time']}."
  else
    puts 'Exact timing: cron-job.org (free) starts your GitHub rewards run at the exact time each day.'
    puts
    puts '1. Create a GitHub token for it. Open this page (already filled in):'
    puts "   #{ChronoGitHub.run_token_url}"
    puts "   Under Repository access choose \"Only select repositories\" and pick #{ChronoGitHub::REPO_NAME}."
    puts '   Click "Generate token" and copy it.'
    token = ask_password('   Paste the token: ')
    puts '2. Make a free account at https://cron-job.org, then Settings > API > create an API key.'
    key = ask_password('   Paste the API key: ')
    Rewards.exact_setup!(key, token, progress: ->(line) { puts "  #{line}" })
  end
  if Rewards.github_needs_update
    puts 'Now updating GitHub, so its own schedule becomes the backup:'
    Rewards.github_sync!(github_sign_in_cli, progress: ->(line) { puts "  #{line}" })
  end
  puts 'Done.'
  true
end

def cmd_exact_stop
  fail! 'Exact timing isn\'t set up.' unless Rewards.exact_state
  key = ask_password('cron-job.org API key, to delete the job (leave empty to delete it on cron-job.org yourself): ')
  Rewards.exact_stop!(key.empty? ? nil : key)
  puts key.empty? ? 'Exact timing off. Delete the "Chrono4Lich rewards" job on cron-job.org.' : 'Exact timing off.'
  puts 'Also delete the "Chrono4Lich exact timing" token on GitHub (Settings > Developer settings > Personal access tokens).'
  if Rewards.github_needs_update
    puts 'Now updating GitHub, so its own schedule runs at the claim time again:'
    Rewards.github_sync!(github_sign_in_cli, progress: ->(line) { puts "  #{line}" })
  end
  true
end

# Prints the code to enter on GitHub and waits for approval. Returns the token (not saved).
def github_sign_in_cli
  device = ChronoGitHub.start_sign_in
  puts
  puts "  1. Open #{device[:verification_uri]}"
  puts "  2. Enter the code:  #{device[:user_code]}"
  puts '  3. Approve Chrono4Lich.'
  puts
  puts 'Waiting for you to approve on GitHub...'
  ChronoGitHub.wait_for_token(device)
end

def cmd_github_setup
  wanted = Rewards.github_accounts
  fail! 'No accounts are set to claim on GitHub. Use: chrono rewards-set ACCOUNT where github' if wanted.empty?
  puts "This stores the Simutronics logins for #{wanted.map { |a| a[:name] }.join(', ')} as encrypted secrets"
  puts 'in a private repository on your GitHub account, and claims rewards there every day.'
  token = github_sign_in_cli
  Rewards.github_sync!(token, progress: ->(line) { puts "  #{line}" })
  gh = Rewards.github_state
  puts "Done. Watch the first run at #{ChronoGitHub.actions_url(gh['repo'])}"
  true
end

def cmd_github_stop
  gh = Rewards.github_state
  fail! 'GitHub was never set up from this computer.' unless gh && gh['repo']
  puts "This turns off the schedule in github.com/#{gh['repo']} and deletes the stored logins there."
  token = github_sign_in_cli
  Rewards.github_stop!(token)
  puts "Done. The repository itself is still on GitHub; delete it there if you like (Settings, at the bottom)."
  if Rewards.exact_state
    key = ask_password('Exact timing was on. cron-job.org API key, to delete its job (leave empty to delete it yourself): ')
    Rewards.exact_stop!(key.empty? ? nil : key)
    puts 'Delete the "Chrono4Lich rewards" job on cron-job.org.' if key.empty?
    puts 'Also delete the "Chrono4Lich exact timing" token on GitHub (Settings > Developer settings > Personal access tokens).'
  end
  true
end

# chrono rewards-set on|off [HH:MM]   or   chrono rewards-set ACCOUNT coins|daily on|off
def cmd_rewards_set(args)
  usage = 'Use: chrono rewards-set on [HH:MM] | off | ACCOUNT coins on|off | ACCOUNT daily on|off | ACCOUNT where pc|github'
  case args.map(&:downcase)
  in ['on'] | ['on', _]
    d = Rewards.set_schedule(true, args[1])
    puts "Daily rewards on, every day at #{d['time']}."
  in ['off']
    Rewards.set_schedule(false)
    puts 'Daily rewards off.'
  in [_, 'where', ('pc' | 'github') => where]
    unless Rewards.accounts.any? { |a| a[:name].casecmp?(args[0]) }
      fail! "No saved login for account #{args[0]}."
    end
    Rewards.set_account(args[0], where: where)
    puts "#{args[0].upcase}: claims on #{where == 'github' ? 'GitHub' : 'this PC'}."
    puts 'Run "chrono github-setup" to update GitHub.' if Rewards.github_needs_update
  in [_, ('coins' | 'daily') => what, ('on' | 'off') => value]
    acct = args[0]
    unless Rewards.accounts.any? { |a| a[:name].casecmp?(acct) }
      fail! "No saved login for account #{acct}."
    end
    Rewards.set_account(acct, what.to_sym => value == 'on')
    puts "#{acct.upcase}: #{what == 'coins' ? 'SimuCoins' : 'daily login rewards'} #{value}."
  else
    fail! usage
  end
  true
end

QUICK_STAY = (ENV['CHRONO_QUICK_STAY'] || 45).to_i # seconds a quick (no logout time) scheduled login stays in once the game confirms it

def cmd_run_schedule(kind, name)
  fail! 'Use: run-schedule login|logout "Schedule name"' unless %w[login logout].include?(kind) && name
  s = Schedules.find(name)
  log "SCHEDULE #{s['name']}: scheduled #{kind} starting"
  if kind == 'login'
    if !Gem.win_platform? && ENV['DISPLAY'].to_s.empty? && ENV['WAYLAND_DISPLAY'].to_s.empty?
      fail! 'The scheduled login has no desktop to open the game on (DISPLAY and WAYLAND_DISPLAY are not set). ' \
            'Make sure you are logged in to your desktop, then open Chrono and click ' \
            '"Rebuild scheduled tasks" on the Settings tab.'
    end
    scripts = s['scripts'].to_s.split(',').map(&:strip).reject(&:empty?)
    # characters already online (someone is playing them) are skipped, and never logged out here
    already = s['characters'].select { |spec| online?(spec.split(':').first) }
    ok = cmd_login(s["characters"], nil, scripts, 120, 2, skip_online: true)
    return ok if s['logout_at'] # logs out at its set time

    # No logout time: a quick login, as a safety limit. Once the game confirms they're in, stay
    # QUICK_STAY seconds (long enough to count as a login, e.g. for the daily reward), then log out.
    ours = (s['characters'] - already).select { |spec| online?(spec.split(':').first) }
    return ok if ours.empty?

    log "SCHEDULE #{s['name']}: no logout time, so logging out #{ours.join(', ')} in #{QUICK_STAY}s (quick login)"
    sleep QUICK_STAY
    cmd_logout(ours, 90, skip_offline: true) && ok
  else
    cmd_logout(s['characters'], 90, skip_offline: true)
  end
end

require_relative 'chrono_schedule'
require_relative 'chrono_rewards'
require_relative 'chrono_github'
require_relative 'chrono_cronjob'

# ---------- carrying over from lichsched (Chrono's old name) ----------

LEGACY_STATE_DIR = LICH_DIR && File.join(DATA_DIR, 'lichsched')
LEGACY_DONE_MARKER = 'MOVED_TO_CHRONO.txt'

# Copies lichsched's data (schedules, log) into Chrono's data folder, swaps the old scheduled
# tasks/timers for Chrono's, and removes the old helper. Runs once; does nothing afterwards.
# Files are copied rather than the folder renamed, because Windows refuses to rename a folder
# that anything has open (an Explorer window, antivirus, the old lichsched window).
# Returns the names of characters still online under the old helper. While any are, nothing
# is moved, because their sessions still write to the old folder.
def migrate_from_lichsched!
  return [] unless LICH_DIR && File.directory?(LEGACY_STATE_DIR)
  return [] if File.exist?(File.join(LEGACY_STATE_DIR, LEGACY_DONE_MARKER))
  # Nothing worth carrying over (e.g. an empty folder Windows wouldn't let us delete): tidy up.
  if Dir.glob(File.join(LEGACY_STATE_DIR, '{schedules.json,lichsched.log,*.status.json}')).empty?
    FileUtils.rm_rf(LEGACY_STATE_DIR)
    return []
  end
  still_online = Dir.glob(File.join(LEGACY_STATE_DIR, '*.status.json')).filter_map do |f|
    st = (JSON.parse(File.read(f)) rescue nil)
    st && st['state'] != 'offline' && pid_alive?(st['pid']) ? st['name'] : nil
  end
  unless still_online.empty?
    log "Not carrying over lichsched's data yet: #{still_online.join(', ')} still online under lichsched. " \
        'Quit them in the game (QUIT), then open Chrono again.'
    return still_online
  end

  FileUtils.mkdir_p(STATE_DIR)
  # Schedules: take lichsched's unless Chrono already has its own.
  old_sched = File.join(LEGACY_STATE_DIR, 'schedules.json')
  new_sched = File.join(STATE_DIR, 'schedules.json')
  FileUtils.cp(old_sched, new_sched) if File.exist?(old_sched) && !File.exist?(new_sched)
  # Log: lichsched's history first, then anything Chrono has logged so far.
  old_log = File.join(LEGACY_STATE_DIR, 'lichsched.log')
  new_log = File.join(STATE_DIR, 'chrono.log')
  if File.exist?(old_log)
    merged = File.read(old_log) + (File.exist?(new_log) ? File.read(new_log) : '')
    File.write("#{new_log}.tmp", merged)
    File.rename("#{new_log}.tmp", new_log)
  end
  # (status files from the old helper are useless to Chrono, so they aren't copied)

  # Mark the old folder as done first, so this never runs twice even if it can't be deleted.
  File.write(File.join(LEGACY_STATE_DIR, LEGACY_DONE_MARKER),
             "lichsched's data was copied to #{ChronoConfig.disp(STATE_DIR)} on #{Time.now}.\n" \
             "This folder can be deleted.\n")
  FileUtils.rm_rf(LEGACY_STATE_DIR) # quietly leaves it if Windows still has it open
  if File.directory?(LEGACY_STATE_DIR)
    log "Couldn't delete the old folder #{ChronoConfig.disp(LEGACY_STATE_DIR)} (something has it open). " \
        'Everything is copied, so you can delete it yourself later.'
  end

  list = Schedules.load
  list.each do |s|
    Schedules.remove_legacy!(s)
    Schedules.install!(s)
  end
  old_helper = File.join(SCRIPT_DIR, 'lichsched_helper.lic')
  File.delete(old_helper) if File.exist?(old_helper)
  log "Carried over from lichsched: data moved to #{ChronoConfig.disp(STATE_DIR)}, " \
      "#{list.size} schedule(s) moved to #{Schedules.scheduler_name}."
  []
rescue SystemCallError => e
  fail! "Couldn't bring lichsched's data over from #{ChronoConfig.disp(LEGACY_STATE_DIR)}: #{e.message}. " \
        'Close any window showing that folder, and the old lichsched window if it\'s still open, ' \
        'then open Chrono again. Nothing has been lost.'
end

# The GUI loads this file for its helpers; only run the command line when started directly.
return unless __FILE__ == $PROGRAM_NAME

$stdout.sync = true
$stderr.sync = true

opts = { realm: nil, scripts: [], timeout: nil, gap: 2 }
parser = OptionParser.new do |o|
  o.banner = 'Usage: chrono <list|status|login|logout|kill|add-login|change-password|remove-login|rewards|rewards-set|run-rewards|github-setup|github-stop|exact-setup|exact-stop|config|set-lich-dir> [Name ...|all] [options]'
  o.on('--realm REALM', 'Realm for names saved in more than one realm') { |v| opts[:realm] = v.downcase }
  o.on('--scripts LIST', 'Comma-separated scripts to start after login') do |v|
    opts[:scripts] = v.split(',').map(&:strip).reject(&:empty?)
  end
  o.on('--timeout SECONDS', Integer, 'How long to wait per character (login 120, logout 90)') { |v| opts[:timeout] = v }
  o.on('--gap SECONDS', Integer, 'Seconds between starting each login (default 2); they log in at the same time') { |v| opts[:gap] = v }
  o.on('--notify', 'Show a Windows pop-up if anything fails (used by scheduled tasks)') { opts[:notify] = true }
  o.on('--frontend NAME', 'Frontend for add-login (default: the one your saved logins use most)') { |v| opts[:frontend] = v.downcase }
end

# A plain title for the pop-up, e.g. "Claiming rewards" or "The scheduled login for 'Morning'".
friendly_task = lambda do
  case ARGV.first
  when 'run-rewards' then 'Claiming rewards'
  when 'run-schedule' then "The scheduled #{ARGV[1]} for '#{ARGV[2]}'"
  else "chrono #{ARGV.reject { |a| a == '--notify' }.first(3).join(' ')}"
  end
end

notify_failure = lambda do |what|
  next unless opts[:notify]
  details = ERRORS_SEEN.uniq.reject { |e| e.start_with?('LOGIN SUMMARY', 'LOGOUT SUMMARY', 'REWARDS run finished') }
                       .map { |e| e.sub(/\AREWARDS /, '') }.first(10).join("\n\n")
  notify_box('Chrono', "#{what} had problems:\n\n#{details}\n\nDetails are in chrono.log.")
end

begin
  # Started by Task Scheduler under rubyw there is no console; printing would fail.
  if Gem.win_platform?
    require 'fiddle'
    get_std = Fiddle::Function.new(Fiddle.dlopen('kernel32')['GetStdHandle'], [Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
    { -11 => $stdout, -12 => $stderr }.each do |id, io|
      handle = get_std.call(id).to_i
      io.reopen(File::NULL, 'w') if [0, -1, 2**64 - 1, 2**32 - 1].include?(handle)
    end
  end

  command, *names = parser.parse(ARGV)
  needs_name = %w[login logout kill run-schedule].include?(command)
  if command.nil? || (needs_name && names.empty?)
    puts parser
    exit 2
  end
  require_lich_dir! unless %w[config set-lich-dir rebuild-tasks remove-tasks].include?(command)
  waiting = LICH_DIR && !%w[config set-lich-dir remove-tasks].include?(command) ? migrate_from_lichsched! : []
  ok =
    case command
    when 'config'        then cmd_config
    when 'rebuild-tasks' then cmd_rebuild_tasks
    when 'remove-tasks'  then cmd_remove_tasks
    when 'set-lich-dir' then cmd_set_lich_dir(names.first)
    when 'run-rewards'     then cmd_run_rewards(names)
    when 'github-setup'    then cmd_github_setup
    when 'github-stop'     then cmd_github_stop
    when 'exact-setup'     then cmd_exact_setup
    when 'exact-stop'      then cmd_exact_stop
    when 'rewards'         then cmd_rewards
    when 'rewards-set'     then cmd_rewards_set(names)
    when 'add-login'       then cmd_add_login(names.first, opts[:frontend])
    when 'change-password' then cmd_change_password(names.first)
    when 'remove-login'    then cmd_remove_login(names.first)
    when 'list'   then cmd_list || true
    when 'version', '--version' then puts("Chrono #{CHRONO_VERSION}") || true
    when 'check-update'
      rel = ChronoGitHub.latest_release
      if rel.nil? then puts "Couldn't check for updates right now."
      elsif ChronoGitHub.newer?(rel[:version], CHRONO_VERSION) then puts "Chrono #{rel[:version]} is available (you have #{CHRONO_VERSION}): #{rel[:url]}"
      else puts "Chrono #{CHRONO_VERSION} is the latest version."
      end
      true
    when 'status' then cmd_status || true
    when 'login'  then cmd_login(names, opts[:realm], opts[:scripts], opts[:timeout] || 120, opts[:gap])
    when 'logout' then cmd_logout(names, opts[:timeout] || 90)
    when 'kill'
      fail! 'kill takes exactly one name.' unless names.size == 1
      cmd_kill(names.first)
    when 'run-schedule'
      cmd_run_schedule(names[0], names[1])
    else
      puts parser
      exit 2
    end
  notify_failure.call(friendly_task.call) unless ok
  # tells the installers that lichsched's schedules are waiting on characters still online
  exit 3 if ok && command == 'rebuild-tasks' && !waiting.empty?
  exit(ok ? 0 : 1)
rescue Errno::EPIPE
  exit 0 # output was cut short (e.g. piped into head); nothing went wrong
rescue Fail, ChronoEAccess::Error, ChronoGitHub::Error, OptionParser::ParseError => e
  log "!!! ERROR: #{e.message}", $stderr
  notify_failure.call(friendly_task.call)
  exit 1
rescue => e
  log "!!! UNEXPECTED ERROR: #{e.class}: #{e.message}", $stderr
  begin
    e.backtrace.first(5).each { |l| $stderr.puts "    #{l}" }
  rescue IOError, SystemCallError
    nil
  end
  notify_failure.call(friendly_task.call)
  exit 1
end
