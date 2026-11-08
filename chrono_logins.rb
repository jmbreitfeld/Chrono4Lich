# chrono_logins.rb - reads and changes Lich's saved logins.
# Loaded by chrono.rb; needs its helpers (fail!, log, DATA_DIR, LICH_DIR, STATE_DIR, rubyw_path).
#
# Lich keeps saved logins in one of two files:
#   entry.yaml  newer Lich (5.13+). Passwords may be encrypted, possibly with a master password
#               in the system keychain, so Chrono changes it only through Lich's own commands
#               (lich.rbw --add-account / --add-character / --change-account-password), except
#               removing a character, which doesn't touch passwords.
#   entry.dat   older Lich. Chrono writes it directly, in the same format elogin does.
# When both exist, Lich uses entry.yaml, so Chrono does too.
# Every change is preceded by a backup in data/chrono/backups.

require 'yaml'
require 'open3'

module SavedLogins
  GAME_NAMES = { 'GS3' => 'GemStone IV', 'GSX' => 'GemStone IV Platinum',
                 'GSF' => 'GemStone IV Shattered', 'GST' => 'GemStone IV Test' }.freeze
  KEEP_BACKUPS = 10
  # Warlock isn't one of Lich's frontends: Lich runs it as a "custom launch" command saved with
  # the login (frontend stormfront, since Warlock speaks Stormfront's protocol). Chrono shows such
  # logins as "warlock" and offers it as a frontend choice.
  WARLOCK = 'warlock'
  WARLOCK_BASE_FRONTEND = 'stormfront'

  module_function

  def yaml_file = File.join(DATA_DIR, 'entry.yaml')
  def dat_file  = File.join(DATA_DIR, 'entry.dat')

  # :yaml or :dat - which file Lich reads (or, with neither, which one a new login goes into).
  def backend
    return :yaml if File.exist?(yaml_file)
    return :dat if File.exist?(dat_file)
    lich_has_cli? ? :yaml : :dat
  end

  def lich_has_cli?
    File.exist?(File.join(LICH_DIR, 'lib', 'common', 'cli', 'cli_orchestration.rb'))
  end

  def lich_version
    src = File.read(File.join(LICH_DIR, 'lib', 'version.rb')) rescue nil
    src && src[/LICH_VERSION\s*=\s*['"]([^'"]+)/, 1]
  end

  # Frontends this Lich accepts for new logins (read from Lich itself when it says), plus Warlock.
  def frontends
    helpers = File.join(LICH_DIR, 'lib', 'common', 'authentication', 'login_helpers.rb')
    list = (File.read(helpers)[/VALID_FRONTENDS\s*=\s*%w\[([^\]]*)\]/, 1] rescue nil)&.split
    list = %w[stormfront wizard avalon] if list.nil? || list.empty?
    # the ones already in use come first, most used first
    used = entries.map { |e| e[:frontend].to_s }.reject(&:empty?).tally.sort_by { |_, n| -n }.map(&:first)
    (used + list + [WARLOCK]).uniq
  end

  def warlock_launch?(custom_launch) = custom_launch.to_s.downcase.include?(WARLOCK)

  # What Chrono shows as a login's frontend: "warlock" for a Warlock custom launch.
  def shown_frontend(frontend, custom_launch)
    warlock_launch?(custom_launch) ? WARLOCK : frontend.to_s
  end

  # The command Lich runs to start Warlock, and the folder to run it in: copied from a login that
  # already uses Warlock (so it matches what works on this computer), otherwise Lich's own
  # preset for this system. [command, folder or nil]
  def warlock_launch
    used = entries.select { |e| e[:frontend] == WARLOCK }
                  .map { |e| [e[:custom_launch].to_s, e[:custom_launch_dir].to_s.empty? ? nil : e[:custom_launch_dir].to_s] }
    return used.tally.max_by { |_, n| n }.first unless used.empty?
    cmd =
      if Gem.win_platform? then 'warlock'
      elsif RUBY_PLATFORM.include?('darwin') then '/Applications/Warlock.app/Contents/MacOS/Warlock'
      else '/usr/bin/warlock'
      end
    ["#{cmd} --host localhost --port %port% --key %key%", nil]
  end

  # Saved GemStone logins without passwords:
  #   [{char_name:, game_code:, game_name:, user_id:, frontend:, custom_launch:, custom_launch_dir:}]
  # frontend is the one Chrono shows ("warlock" for a Warlock custom launch).
  # (Lich also saves DragonRealms logins; Chrono leaves those alone.)
  def entries
    list =
      case backend
      when :yaml then File.exist?(yaml_file) ? yaml_entries : []
      else
        (File.exist?(dat_file) ? dat_entries : []).map do |e|
          e.reject { |k, _| k == :password }.merge(frontend: shown_frontend(e[:frontend], e[:custom_launch]))
        end
      end
    list.select { |e| GAME_NAMES.key?(e[:game_code].to_s) }
  end

  def yaml_entries
    data = load_yaml
    (data['accounts'] || {}).flat_map do |account, info|
      Array(info && info['characters']).map do |c|
        { char_name: c['char_name'].to_s, game_code: c['game_code'].to_s, game_name: c['game_name'].to_s,
          user_id: account.to_s, frontend: shown_frontend(c['frontend'], c['custom_launch']),
          custom_launch: c['custom_launch'], custom_launch_dir: c['custom_launch_dir'] }
      end
    end
  end

  def load_yaml
    data = YAML.safe_load_file(yaml_file, permitted_classes: [Symbol])
    fail! "#{yaml_file} isn't in the format Chrono expects." unless data.is_a?(Hash)
    data
  rescue Psych::Exception => e
    fail! "Couldn't read #{yaml_file}: #{e.message}"
  end

  def dat_entries
    data = Marshal.load(File.binread(dat_file).unpack1('m'))
    fail! "#{dat_file} did not contain a list of characters." unless data.is_a?(Array)
    data
  rescue Fail
    raise
  rescue StandardError => e
    fail! "Couldn't read #{dat_file}: #{e.class}: #{e.message}"
  end

  # ---------- backups and writing ----------

  def backup!(file)
    return unless File.exist?(file)
    dir = File.join(STATE_DIR, 'backups')
    FileUtils.mkdir_p(dir)
    FileUtils.cp(file, File.join(dir, "#{File.basename(file)}.#{Time.now.strftime('%Y%m%d-%H%M%S-%L')}"))
    old = Dir.glob(File.join(dir, "#{File.basename(file)}.*")).sort
    old.first([old.size - KEEP_BACKUPS, 0].max).each { |f| File.delete(f) }
  end

  def write_atomically(file, content)
    tmp = "#{file}.chrono-tmp"
    File.binwrite(tmp, content)
    File.rename(tmp, file)
  end

  def write_dat(list)
    backup!(dat_file)
    write_atomically(dat_file, [Marshal.dump(list)].pack('m'))
  end

  # Runs one of Lich's account commands. The password, if any, is passed as Lich expects it.
  def run_lich(*args, secret: nil)
    fail! "This Lich has no command for changing saved logins (needs Lich 5.13 or newer; found #{lich_version || 'unknown'})." unless lich_has_cli?
    backup!(yaml_file)
    cmd = [rubyw_path, File.join(LICH_DIR, 'lich.rbw'), *args]
    out, status = Open3.capture2e(*cmd, chdir: LICH_DIR, stdin_data: '')
    out = out.force_encoding(Encoding::UTF_8).scrub
    out = out.gsub(secret, '********') if secret && !secret.empty?
    [out.strip, status]
  end

  def lich_error(out, what)
    line = out.lines.map(&:strip).find { |l| l.start_with?('error:') } || out.lines.last.to_s.strip
    fail! "Lich couldn't #{what}: #{line.sub(/\Aerror:\s*/, '')}"
  end

  # ---------- changes ----------

  # Saves the picked characters (from ChronoEAccess.list_characters) for an account.
  # picked: [{game_code:, game_name:, char_name:}]
  # frontend "warlock" saves a Warlock custom launch: launch (the command) and launch_dir default
  # to warlock_launch.
  def add(account, password, picked, frontend, launch: nil, launch_dir: nil)
    fail! 'Pick at least one character.' if picked.empty?
    account = account.strip
    custom = nil
    if frontend == WARLOCK
      default_cmd, default_dir = warlock_launch
      cmd = launch.to_s.strip.empty? ? default_cmd : launch.to_s.strip
      dir = launch_dir.nil? ? default_dir : (launch_dir.to_s.strip.empty? ? nil : launch_dir.to_s.strip)
      unless cmd.include?('%port%') && cmd.include?('%key%')
        fail! 'The Warlock command must include %port% and %key% (Lich fills them in when the game starts).'
      end
      fail! 'The Warlock command must mention warlock, so Lich and Chrono can tell it apart.' unless warlock_launch?(cmd)
      custom = [cmd, dir]
    end
    if backend == :yaml
      add_yaml(account, password, picked, frontend, custom)
    else
      add_dat(account, password, picked, frontend, custom)
    end
  end

  def add_dat(account, password, picked, frontend, launch = nil)
    list = File.exist?(dat_file) ? dat_entries : []
    added = 0
    picked.each do |c|
      next if list.any? do |e|
        e[:char_name].to_s.casecmp?(c[:char_name]) && e[:game_code] == c[:game_code] &&
          shown_frontend(e[:frontend], e[:custom_launch]) == frontend
      end
      list << { char_name: c[:char_name].capitalize, game_code: c[:game_code],
                game_name: GAME_NAMES[c[:game_code]] || c[:game_name], user_id: account.downcase,
                password: password, frontend: launch ? WARLOCK_BASE_FRONTEND : frontend,
                custom_launch: launch&.first, custom_launch_dir: launch&.last }
      added += 1
    end
    # one password per account: keep every saved character on this account in step
    list.each { |e| e[:password] = password if e[:user_id].to_s.casecmp?(account) }
    write_dat(list)
    log "LOGINS saved #{added} character(s) for account #{account} in entry.dat"
    added
  end

  def add_yaml(account, password, picked, frontend, launch = nil)
    lich_frontend = launch ? WARLOCK_BASE_FRONTEND : frontend
    existing = File.exist?(yaml_file) ? (load_yaml['accounts'] || {}) : {}
    key = existing.keys.find { |k| k.to_s.casecmp?(account) }
    if key
      # account already saved: refresh its password (just checked with Simutronics), then add characters
      out, status = run_lich('--change-account-password', key, password, secret: password)
      lich_error(out, 'update the password') unless status.success?
      stored = yaml_entries.select { |e| e[:user_id].casecmp?(key) }
      todo = picked.reject { |c| stored.any? { |e| e[:char_name].casecmp?(c[:char_name]) && e[:game_code] == c[:game_code] && e[:frontend] == frontend } }
      if launch
        # Lich's add-character command can't save a custom launch, so Chrono adds these the way
        # Lich's own account manager does: a new character record, no passwords involved.
        add_yaml_characters(key, todo, launch) unless todo.empty?
      else
        todo.each do |c|
          out, status = run_lich('--add-character', key, c[:char_name], '--game-code', c[:game_code], '--frontend', lich_frontend)
          lich_error(out, "add #{c[:char_name]}") unless status.success?
        end
      end
      added = todo.size
    else
      # new account: Lich saves every character on it, then the ones not picked are removed
      out, status = run_lich('--add-account', account, password, '--frontend', lich_frontend, secret: password)
      lich_error(out, 'add the account') unless status.success?
      key = (load_yaml['accounts'] || {}).keys.find { |k| k.to_s.casecmp?(account) } or
        fail! "Lich reported success, but account #{account} isn't in entry.yaml."
      keep = picked.map { |c| [c[:char_name].downcase, c[:game_code]] }
      remove_yaml_characters(key) { |c| !keep.include?([c['char_name'].to_s.downcase, c['game_code']]) }
      set_yaml_launch(key, launch) if launch
      added = picked.size
    end
    log "LOGINS saved #{added} character(s) for account #{account} through Lich"
    added
  end

  def change_password(account, password)
    if backend == :yaml
      key = (load_yaml['accounts'] || {}).keys.find { |k| k.to_s.casecmp?(account) } or
        fail! "Account #{account} isn't saved."
      out, status = run_lich('--change-account-password', key, password, secret: password)
      lich_error(out, 'change the password') unless status.success?
    else
      list = dat_entries
      hits = list.select { |e| e[:user_id].to_s.casecmp?(account) }
      fail! "Account #{account} isn't saved." if hits.empty?
      hits.each { |e| e[:password] = password }
      write_dat(list)
    end
    log "LOGINS changed the saved password for account #{account}"
    Rewards.github_password_changed(account) if defined?(Rewards)
  end

  # Removes every saved login for this character in this game (all frontends).
  def remove(char_name, game_code, account)
    if backend == :yaml
      key = (load_yaml['accounts'] || {}).keys.find { |k| k.to_s.casecmp?(account) } or
        fail! "Account #{account} isn't saved."
      n = remove_yaml_characters(key) { |c| c['char_name'].to_s.casecmp?(char_name) && c['game_code'] == game_code }
    else
      list = dat_entries
      before = list.size
      list.reject! { |e| e[:char_name].to_s.casecmp?(char_name) && e[:game_code] == game_code && e[:user_id].to_s.casecmp?(account) }
      n = before - list.size
      write_dat(list) if n.positive?
    end
    fail! "#{char_name} isn't saved for account #{account}." if n.zero?
    log "LOGINS removed #{char_name} (#{game_code}) from account #{account}"
    n
  end

  # Adds character records with a custom launch to an account in entry.yaml (same fields Lich writes).
  def add_yaml_characters(account_key, picked, launch)
    edit_yaml do |data|
      chars = (data['accounts'][account_key]['characters'] ||= [])
      picked.each do |c|
        chars << { 'char_name' => c[:char_name].to_s.strip.split.map(&:capitalize).join(' '),
                   'game_code' => c[:game_code], 'game_name' => GAME_NAMES[c[:game_code]] || c[:game_name],
                   'frontend' => WARLOCK_BASE_FRONTEND, 'custom_launch' => launch[0], 'custom_launch_dir' => launch[1] }
      end
    end
  end

  # Gives every character on the account the custom launch (used right after adding a new account).
  def set_yaml_launch(account_key, launch)
    edit_yaml do |data|
      (data.dig('accounts', account_key, 'characters') || []).each do |c|
        c['frontend'] = WARLOCK_BASE_FRONTEND
        c['custom_launch'] = launch[0]
        c['custom_launch_dir'] = launch[1]
      end
    end
  end

  def edit_yaml
    data = load_yaml
    yield data
    backup!(yaml_file)
    write_atomically(yaml_file, YAML.dump(data))
  end

  # Removing a character doesn't touch passwords or encryption settings, so Chrono edits
  # entry.yaml directly, keeping everything else exactly as it was.
  def remove_yaml_characters(account_key)
    data = load_yaml
    chars = data.dig('accounts', account_key, 'characters') || []
    before = chars.size
    chars.reject! { |c| yield(c) }
    removed = before - chars.size
    if removed.positive?
      backup!(yaml_file)
      write_atomically(yaml_file, YAML.dump(data))
    end
    removed
  end
end
