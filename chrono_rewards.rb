# chrono_rewards.rb - claims Simutronics rewards: the monthly subscription SimuCoins from the
# store, and (optionally, per account) each Prime character's daily login reward.
# Loaded by chrono.rb; needs its helpers (fail!, log, STATE_DIR, DATA_DIR, LICH_DIR, online?).
#
# Works the way elanthia-online's simu-rewards does (credit: Ondreian), with Chrono's own code:
#   SimuCoins: sign in to store.play.net, and press Claim if a reward is waiting. Checked daily,
#     so a missed day is caught up; "Next Subscription Bonus..." means nothing is due yet.
#   Daily login reward: get a one-time game key for the character from the login service,
#     enter the game just long enough to see the reward, then QUIT.
# Passwords come from Lich's saved logins, are held in memory for the run, and are sent only
# to Simutronics (the store and the login service, both encrypted). Never logged or written.

require 'json'
require 'net/http'
require 'uri'
require 'socket'
require 'open3'
require 'timeout'

module Rewards
  FILE      = STATE_DIR && File.join(STATE_DIR, 'rewards.json')
  STORE     = ENV['CHRONO_STORE_URL'] || 'https://store.play.net' # override for testing only
  SIGN_IN   = '/Account/SignIn?returnURL=%2Fstore%2Fpurchase%2Fgs'
  CLAIM     = '/Store/ClaimReward'
  DAILY_GAME = 'GS3' # daily login rewards: GemStone Prime characters
  USER_AGENT = 'Chrono4Lich (Lich login scheduler)'
  TASK_NAME  = 'Daily rewards'
  UNIT_BASE  = 'chrono-rewards'

  module_function

  # ---------- settings and results (rewards.json) ----------

  def load
    data = File.exist?(FILE) ? JSON.parse(File.read(FILE)) : {}
    data = {} unless data.is_a?(Hash)
    data['enabled'] = false unless data.key?('enabled')
    data['accounts'] ||= {}
    data['last'] ||= {}
    unless data['time']
      # spread everyone's runs out, as simu-rewards asks: a random evening time, never :00 or :30.
      # Picked once and kept.
      data['time'] = format('%02d:%02d', 19 + rand(3), [rand(1..28), rand(31..58)].sample)
      save(data)
    end
    data
  rescue JSON::ParserError => e
    fail! "#{FILE} is damaged and can't be read: #{e.message}"
  end

  def save(data)
    FileUtils.mkdir_p(STATE_DIR)
    tmp = "#{FILE}.tmp"
    File.write(tmp, JSON.pretty_generate(data))
    File.rename(tmp, FILE)
  end

  # Accounts from the saved logins, with their reward settings.
  # SimuCoins are claimed for every account unless turned off; daily login rewards are off
  # unless turned on.
  def accounts(data = load)
    names = (load_entries rescue []).map { |e| e[:user_id].to_s.upcase }.uniq.sort
    names.map do |a|
      cfg = data['accounts'][a] || {}
      { name: a, coins: cfg.fetch('coins', true), daily: cfg.fetch('daily', false),
        where: cfg.fetch('where', 'pc'), last: data['last'][a] }
    end
  end

  def set_account(name, coins: nil, daily: nil, where: nil)
    data = load
    cfg = (data['accounts'][name.upcase] ||= {})
    cfg['coins'] = coins unless coins.nil?
    cfg['daily'] = daily unless daily.nil?
    unless where.nil?
      fail! "Claim on must be 'pc' or 'github', not '#{where}'." unless %w[pc github].include?(where)
      cfg['where'] = where
    end
    save(data)
  end

  # ---------- GitHub (see chrono_github.rb) ----------

  # Accounts that should be on GitHub (claim on GitHub, with something turned on).
  def github_accounts(data = load)
    accounts(data).select { |a| a[:where] == 'github' && (a[:coins] || a[:daily]) }
  end

  # What GitHub was last set up with, to tell when it needs updating.
  # (Exact timing changes the workflow too: GitHub's schedule becomes the backup.)
  def github_signature(data = load)
    sig = [github_accounts(data).map { |a| [a[:name], a[:daily]] }, data['time']]
    sig << 'exact' if exact_state(data)
    JSON.generate(sig)
  end

  # nil when not set up; otherwise {'repo', 'login', 'accounts', 'time', 'at', 'stale', 'signature'}
  def github_state(data = load) = data['github']

  # Why GitHub needs updating, or nil if it's current.
  def github_needs_update(data = load)
    gh = github_state(data)
    wanted = github_accounts(data)
    return wanted.empty? ? nil : 'not set up yet' unless gh && !gh['stopped']
    return 'a saved password changed since it was set up' if gh['stale']
    return 'accounts, the time or exact timing changed since it was set up' if gh['signature'] != github_signature(data)
    nil
  end

  def github_synced(result)
    data = load
    data['github'] = { 'repo' => result[:repo], 'login' => result[:login], 'accounts' => result[:accounts],
                       'time' => result[:time], 'cron' => result[:cron], 'branch' => result[:branch], 'at' => Time.now.to_i,
                       'signature' => github_signature(data), 'stale' => false }
    save(data)
  end

  # ---------- exact timing (cron-job.org starts the GitHub run) ----------

  # nil when off; otherwise {'job_id', 'time', 'tz', 'repo', 'at'}
  def exact_state(data = load) = data['exact']

  # Why the cron-job.org job needs updating (only its time can drift), or nil.
  def exact_needs_update(data = load)
    ex = exact_state(data)
    return nil unless ex
    return 'the claim time changed' if ex['time'] != data['time']
    nil
  end

  # Time zone name for cron-job.org, and the time to give it. Without a known zone name, UTC
  # (the time then shifts by an hour with daylight saving time, like GitHub's own schedule).
  def exact_zone(local_time)
    tz = ChronoCronJob.local_timezone
    return [tz, local_time] if tz

    h, m = local_time.split(':').map(&:to_i)
    now = Time.now
    t = Time.local(now.year, now.month, now.day, h, m).utc
    ['UTC', format('%02d:%02d', t.hour, t.min)]
  end

  # token: the fine-grained GitHub token the user made; key: their cron-job.org API key.
  # Neither is saved. Afterwards GitHub needs updating (its schedule becomes the backup).
  def exact_setup!(key, token, progress: ->(_) {})
    data = load
    gh = github_state(data)
    fail! 'Set up GitHub first (Claim on GitHub, then "Set up GitHub...").' unless gh && gh['repo'] && !gh['stopped']
    progress.call('Checking the GitHub token...')
    ChronoGitHub.check_run_token(token, gh['repo'])
    progress.call("The token can start runs in #{gh['repo']} (no run was started).")
    tz, at = exact_zone(data['time'])
    progress.call('Setting up the daily job on cron-job.org...')
    id = ChronoCronJob.setup!(key, gh['repo'], gh['branch'] || 'main', token, at, tz)
    progress.call("cron-job.org will start the run every day at #{at} (#{tz}).")
    data = load
    data['exact'] = { 'job_id' => id, 'time' => data['time'], 'tz' => tz, 'repo' => gh['repo'], 'at' => Time.now.to_i }
    save(data)
    log "EXACT set up cron-job.org job #{id} for #{gh['repo']} at #{at} #{tz}"
    id
  rescue ChronoGitHub::Error, ChronoCronJob::Error => e
    fail! e.message
  end

  # After the claim time changed: moves the cron-job.org job to the new time.
  def exact_update_time!(key)
    data = load
    ex = exact_state(data) or fail!('Exact timing isn\'t set up.')
    tz, at = exact_zone(data['time'])
    ChronoCronJob.set_time!(key, ex['job_id'], at, tz)
    data['exact'] = ex.merge('time' => data['time'], 'tz' => tz, 'at' => Time.now.to_i)
    save(data)
    log "EXACT moved cron-job.org job #{ex['job_id']} to #{at} #{tz}"
  rescue ChronoCronJob::Error => e
    fail! e.message
  end

  # Removes the cron-job.org job (key nil: just forget it, the user deletes it on cron-job.org).
  def exact_stop!(key)
    data = load
    ex = exact_state(data)
    ChronoCronJob.delete!(key, ex['job_id']) if ex && key
    data.delete('exact')
    save(data)
    log "EXACT turned off#{key ? ' (cron-job.org job deleted)' : ' (job left on cron-job.org)'}"
  rescue ChronoCronJob::Error => e
    fail! e.message
  end

  def github_stopped
    data = load
    data['github'] = (data['github'] || {}).merge('stopped' => true, 'at' => Time.now.to_i)
    save(data)
  end

  # Called when a saved password changes: GitHub's copy is now out of date.
  def github_password_changed(account)
    data = load
    gh = data['github']
    return unless gh && !gh['stopped'] && Array(gh['accounts']).any? { |a| a.casecmp?(account) }
    gh['stale'] = true
    save(data)
  end

  # Signs in has already happened (token in hand): pushes the GitHub accounts and schedule.
  def github_sync!(token, progress: ->(_) {})
    data = load
    wanted = github_accounts(data)
    fail! 'No accounts are set to claim on GitHub. Set "Claim on" to GitHub for at least one account.' if wanted.empty?
    pw = passwords
    missing = wanted.reject { |a| pw[a[:name]].to_s != '' }
    fail! "No saved password for: #{missing.map { |a| a[:name] }.join(', ')}." unless missing.empty?
    result = ChronoGitHub.sync!(token, wanted.map { |a| { name: a[:name], password: pw[a[:name]], daily: a[:daily] } },
                                data['time'], exact: !exact_state(data).nil?,
                                first_run: !(github_state(data) && !github_state(data)['stopped']), progress: progress)
    github_synced(result)
    result
  end

  def github_stop!(token)
    gh = github_state
    fail! 'GitHub was never set up from this computer.' unless gh && gh['repo']
    ChronoGitHub.stop!(token, gh['repo'])
    github_stopped
    # those accounts are claimed on this computer again
    data = load
    data['accounts'].each_value { |cfg| cfg['where'] = 'pc' if cfg['where'] == 'github' }
    save(data)
  end

  # Turns the daily run on (at HH:MM) or off, and creates or removes its scheduled task.
  def set_schedule(enabled, time = nil)
    data = load
    if time
      fail! "'#{time}' isn't a valid HH:MM time." unless time.match?(Schedules::TIME_RE)
      data['time'] = time
    end
    data['enabled'] = enabled
    install_task!(data)
    save(data)
    data
  end

  def job(data)
    { description: 'Chrono: claim SimuCoins and daily login rewards',
      args: ['run-rewards', '--notify'], time: data['time'], days: Schedules::DAYS,
      enabled: true, catch_up: true } # if the computer was off at that time, run when it's back
  end

  def install_task!(data = load)
    if Gem.win_platform?
      tn = "#{Schedules::TASK_FOLDER}#{TASK_NAME}"
      data['enabled'] ? Schedules.create_task(tn, Schedules.task_xml(job(data))) : Schedules.delete_task(tn)
    elsif data['enabled']
      Schedules.linux_prepare!
      Schedules.linux_write_units(UNIT_BASE, job(data))
      Schedules.systemctl!('daemon-reload')
      Schedules.linux_activate!(UNIT_BASE, true)
    elsif Schedules.linux_remove_base(UNIT_BASE)
      Schedules.systemctl!('daemon-reload')
    end
  end

  def uninstall_task!
    if Gem.win_platform?
      Schedules.delete_task("#{Schedules::TASK_FOLDER}#{TASK_NAME}")
    elsif Schedules.linux_remove_base(UNIT_BASE)
      Schedules.systemctl!('daemon-reload')
    end
  end

  # ---------- passwords from Lich's saved logins ----------

  # {ACCOUNT => password}
  def passwords
    if SavedLogins.backend == :dat
      SavedLogins.dat_entries.to_h { |e| [e[:user_id].to_s.upcase, e[:password].to_s] }
    else
      data = SavedLogins.load_yaml
      mode = (data['encryption_mode'] || 'plaintext').to_s
      return (data['accounts'] || {}).to_h { |a, info| [a.to_s.upcase, info['password'].to_s] } if mode == 'plaintext'
      lich_passwords
    end
  end

  # Encrypted entry.yaml: let Lich's own code decrypt (see chrono_lich_passwords.rb).
  # Tries up to 3 times: when Lich is open it can be rewriting entry.yaml at that moment, and
  # then Lich's code reads nothing.
  def lich_passwords(tries: 3)
    attempt = 0
    begin
      attempt += 1
      lich_passwords_once
    rescue Fail => e
      raise if attempt >= tries || e.message.start_with?('Lich took too long')
      log "Asking Lich for its saved passwords didn't work (try #{attempt} of #{tries}): #{e.message}"
      sleep 5
      retry
    end
  end

  def lich_passwords_once
    script = File.join(__dir__, 'chrono_lich_passwords.rb')
    out = +''
    err = +''
    status = nil
    Open3.popen3(rubyw_path, script, LICH_DIR, chdir: LICH_DIR) do |stdin, stdout, stderr, thr|
      stdin.close
      readers = [Thread.new { out << stdout.read }, Thread.new { err << stderr.read }]
      unless thr.join(60)
        Process.kill('KILL', thr.pid) rescue nil
        fail! 'Lich took too long to open its saved passwords. If Lich asks for a master password, ' \
              'log in once with Lich so it can save it to the system keychain, then try again.'
      end
      readers.each(&:join)
      status = thr.value
    end
    # What Lich itself printed (its own messages; never the passwords, which only appear
    # between the markers on standard output). Used to explain failures.
    out = out.b.force_encoding(Encoding::UTF_8)
    said = (err + out.sub(/CHRONO-PASSWORDS-BEGIN.*CHRONO-PASSWORDS-END/m, ''))
           .force_encoding(Encoding::UTF_8).scrub
           .lines.map(&:strip).reject(&:empty?).reject { |l| l.start_with?('from ') }
           .map { |l| l =~ /\A\S+:\d+:in [^:]*:\s*(.+?)(?: \(([\w:]+)\))?\z/ ? "#{Regexp.last_match(1)}#{Regexp.last_match(2) ? " (#{Regexp.last_match(2)})" : ''}" : l }
    # Lich's own log lines (passed through by the helper): its errors and warnings explain best
    lich_said = said.select { |l| l.start_with?('LICH-LOG ') }.map { |l| l.delete_prefix('LICH-LOG ') }
    said = said.reject { |l| l.start_with?('LICH-LOG ') }
    lich_said.each { |l| log "  Lich: #{l[0, 300]}" }
    reason = (lich_said.find { |l| l.match?(/\A(error|warn)/i) } || said.first || lich_said.last).to_s[0, 200]
    unless status.success?
      log "Lich's saved-password check failed. Lich said: #{said.first(5).join(' | ')[0, 600]}", $stderr
      fail! "Couldn't open Lich's encrypted saved passwords#{reason.empty? ? '' : ": #{reason}"}"
    end
    # (Windows line endings tolerated: older Chrono versions wrote "\r\n" there.)
    json = out[/CHRONO-PASSWORDS-BEGIN\r?\n(.*?)\r?\nCHRONO-PASSWORDS-END/m, 1]
    unless json
      # never log the output itself: it may hold passwords
      log "Lich's saved-password check gave no result (exit #{status.exitstatus}, #{out.bytesize} bytes, " \
          "begin marker #{out.include?('CHRONO-PASSWORDS-BEGIN') ? 'found' : 'missing'}, " \
          "end marker #{out.include?('CHRONO-PASSWORDS-END') ? 'found' : 'missing'}). " \
          "Lich said: #{said.first(5).join(' | ')[0, 600]}", $stderr
      fail! "Lich didn't return its saved passwords#{reason.empty? ? '.' : ". Lich said: #{reason}"}"
    end
    result = JSON.parse(json)
    if result.empty?
      fail! "Lich returned no saved passwords#{reason.empty? ? '. Open Lich once to check that your saved logins load.' : ". Lich said: #{reason}"}"
    end
    result
  rescue JSON::ParserError
    fail! 'Lich returned something unexpected when asked for its saved passwords.'
  end

  # ---------- SimuCoins from the store ----------

  # A tiny browser: keeps cookies, follows redirects.
  class Browser
    def initialize(base)
      @base = URI(base)
      @cookies = {}
    end

    def get(path) = request(Net::HTTP::Get.new(path))

    def post(path, form)
      req = Net::HTTP::Post.new(path)
      req.set_form_data(form)
      request(req)
    end

    private

    def request(req, redirects = 0)
      req['User-Agent'] = USER_AGENT
      req['Cookie'] = @cookies.map { |k, v| "#{k}=#{v}" }.join('; ') unless @cookies.empty?
      res = Net::HTTP.start(@base.host, @base.port, use_ssl: @base.scheme == 'https',
                            open_timeout: 15, read_timeout: 30) { |http| http.request(req) }
      Array(res.get_fields('set-cookie')).each do |c|
        name, value = c.split(';', 2).first.split('=', 2)
        @cookies[name.strip] = value.to_s.strip if name
      end
      if res.is_a?(Net::HTTPRedirection) && res['location']
        raise Rewards::StoreError, 'The store redirected too many times.' if redirects > 5
        target = URI.join(@base, res['location'])
        return request(Net::HTTP::Get.new(target.request_uri), redirects + 1)
      end
      raise Rewards::StoreError, "The store answered #{res.code} #{res.message}." unless res.is_a?(Net::HTTPSuccess)
      res.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
      raise Rewards::StoreError, "Couldn't reach the SimuCoin store: #{e.message}"
    end
  end

  class StoreError < StandardError; end

  # Text inside the first element whose opening tag matches attr (e.g. id="login"), tags removed.
  def element_text(html, attr)
    open_tag = html.match(/<(\w+)\b[^>]*#{attr}[^>]*>/im) or return nil
    tag = open_tag[1].downcase
    pos = open_tag.end(0)
    depth = 1
    scanner = /<(\/?)#{tag}\b[^>]*>/im
    while (m = scanner.match(html, pos))
      depth += m[1].empty? ? 1 : -1
      if depth.zero?
        inner = html[open_tag.end(0)...m.begin(0)]
        return inner.gsub(/<[^>]*>/, ' ').gsub('&nbsp;', ' ').gsub('&amp;', '&').gsub('&lt;', '<')
                    .gsub('&gt;', '>').gsub('&quot;', '"').gsub('&#39;', "'").gsub(/\s+/, ' ').strip
      end
      pos = m.end(0)
    end
    nil
  end

  def class_attr(name) = %(class\\s*=\\s*"[^"]*\\b#{name}\\b[^"]*")

  def store_state(html)
    balance_html = html[/<(\w+)\b[^>]*#{class_attr('balance')}[^>]*>.*?<span\b[^>]*>(.*?)<\/span>/im, 2]
    { login: element_text(html, %(id\\s*=\\s*"login")).to_s,
      reward: element_text(html, class_attr('RewardMessage')).to_s,
      balance: balance_html.to_s.gsub(/<[^>]*>/, '').strip,
      claim_form: html.match?(%r{<form\b[^>]*action\s*=\s*"/Store/ClaimReward"}i) }
  end

  # Returns {status: 'claimed'|'not_due'|'none', message:, balance:}.
  def claim_coins(account, password)
    browser = Browser.new(STORE)
    page = browser.get(SIGN_IN)
    token = page[/<input\b[^>]*name\s*=\s*"__RequestVerificationToken"[^>]*>/i].to_s[/value\s*=\s*"([^"]*)"/i, 1]
    raise StoreError, 'The store\'s sign-in page looks different than expected (it may be down for maintenance).' unless token

    state = store_state(browser.post(SIGN_IN, 'UserName' => account, 'Password' => password,
                                                '__RequestVerificationToken' => token))
    unless state[:login].downcase.include?(account.downcase)
      raise StoreError, "The store didn't accept the password for #{account}." if state[:login].downcase.include?('sign in')
      raise StoreError, "Signing in to the store as #{account} didn't work."
    end

    if state[:reward].downcase.start_with?('next subscription bonus')
      return { status: 'not_due', message: state[:reward], balance: state[:balance] }
    end
    if state[:reward].empty? && !state[:claim_form]
      return { status: 'none', message: 'The store shows no subscription reward for this account.', balance: state[:balance] }
    end

    after = store_state(browser.post(CLAIM, 'game' => 'GS'))
    unless after[:reward].downcase.start_with?('claimed')
      raise StoreError, "The store didn't confirm the claim#{after[:reward].empty? ? '' : " (it said: #{after[:reward][0, 100]})"}."
    end
    { status: 'claimed', message: after[:reward], balance: after[:balance] }
  end

  # ---------- daily login rewards ----------

  def game_host_override = ENV['CHRONO_GAME_HOST'] # testing only

  # Enters the game with a one-time key, waits for the login reward (or the game prompt if it
  # was already claimed today), then quits. Returns the reward text or 'already claimed today'.
  def enter_and_quit(otp, timeout: 60)
    sock = Socket.tcp(game_host_override || otp[:host], otp[:port], connect_timeout: 10)
    begin
      sock.write("#{otp[:key]}\n/FE:STORMFRONT /VERSION:1.0.1.22 /XML\n")
      buf = +''
      reward = nil
      prompt_at = nil
      deadline = Time.now + timeout
      loop do
        raise StoreError, 'the game didn\'t answer in time' if Time.now > deadline
        # once the prompt shows, give the reward message a moment to arrive, then stop
        break if prompt_at && (reward || Time.now - prompt_at > 2)
        next unless sock.wait_readable(0.5)

        chunk = sock.read_nonblock(16_384, exception: false)
        break if chunk.nil? # game closed the connection
        next if chunk == :wait_readable

        buf << chunk.force_encoding(Encoding::BINARY)
        sock.write("<c>\r\n<c>\r\n") if chunk.include?('<settingsInfo ')
        reward ||= buf[/You have earned the following reward: (.*?)!/, 1]
        reward ||= buf[/consecutive days, you have earned (.*?)[!.]/, 1]
        prompt_at ||= Time.now if buf.include?('<prompt time=')
        buf = buf[-4096..] if buf.bytesize > 65_536
      end
      raise StoreError, 'the game closed the connection before the login finished' unless prompt_at || reward

      # log out properly rather than leaving the character linkdead
      sock.write("<c>quit\r\n") rescue nil
      quit_by = Time.now + 5
      while Time.now < quit_by && sock.wait_readable(0.5)
        break if sock.read_nonblock(16_384, exception: false).nil?
      end
      reward ? reward.force_encoding(Encoding::UTF_8).scrub.strip : 'already claimed today'
    ensure
      sock.close rescue nil
    end
  rescue SocketError, SystemCallError, IOError => e
    raise StoreError, "couldn't connect to the game: #{e.message}"
  end

  # Returns [[character, result-or-error, ok?], ...]
  def daily_logins(account, password)
    chars = ChronoEAccess.list_characters(account, password, data_dir: DATA_DIR)
                         .select { |c| c[:game_code] == DAILY_GAME }.map { |c| c[:char_name] }
    return [['(none)', 'no Prime characters on this account', true]] if chars.empty?

    chars.each_with_index.map do |name, i|
      sleep 1 if i.positive?
      attempt = 0
      begin
        attempt += 1
        otp = ChronoEAccess.launch_key(account, password, DAILY_GAME, name, data_dir: DATA_DIR)
        [name, enter_and_quit(otp), true]
      rescue ChronoEAccess::Error, StoreError => e
        if attempt < 3
          sleep 3
          retry
        end
        [name, e.message, false]
      end
    end
  end

  # ---------- one run ----------

  # Claims for the given accounts (default: every account with anything turned on).
  # Returns true when nothing failed.
  def run(only = nil)
    data = load
    named = Array(only).reject(&:empty?) # accounts asked for by name ("Claim now for selected")
    list = accounts(data)
    list = list.select { |a| named.any? { |o| o.casecmp?(a[:name]) } } unless named.empty?
    unknown = named.reject { |o| list.any? { |a| a[:name].casecmp?(o) } }
    fail! "No saved login for account(s): #{unknown.join(', ')}." unless unknown.empty?
    list = list.select { |a| (a[:coins] || a[:daily]) && a[:where] != 'github' } if named.empty?
    if list.empty?
      log 'REWARDS nothing to do here: every account has rewards turned off or claims on GitHub.'
      return true
    end

    pw = passwords
    all_ok = true
    list.each do |acct|
      name = acct[:name]
      result = { 'at' => Time.now.to_i, 'ok' => true }
      password = pw[name]
      unless password && !password.empty?
        result.merge!('ok' => false, 'error' => 'no saved password for this account')
        log "!!! REWARDS #{name}: no saved password for this account", $stderr
      else
        if acct[:coins] || !named.empty? # an account claimed by name always gets its SimuCoins checked
          begin
            c = claim_coins(name, password)
            result['coins'] = c.transform_keys(&:to_s)
            log "REWARDS #{name}: SimuCoins #{c[:status].tr('_', ' ')} - #{c[:message]}#{c[:balance].to_s.empty? ? '' : " (balance #{c[:balance]})"}"
          rescue StoreError => e
            result['coins'] = { 'status' => 'error', 'message' => e.message }
            result['ok'] = false
            log "!!! REWARDS #{name}: SimuCoins failed - #{e.message}", $stderr
          end
        end
        if acct[:daily]
          busy = (load_entries rescue []).select { |e| e[:user_id].to_s.casecmp?(name) && online?(e[:char_name].to_s) }
          if busy.any?
            msg = "skipped: #{busy.map { |e| e[:char_name] }.join(', ')} online (a login reward run would disconnect them)"
            result['logins'] = [['(account)', msg, true]]
            log "REWARDS #{name}: daily login rewards #{msg}"
          else
            begin
              rows = daily_logins(name, password)
              result['logins'] = rows
              rows.each do |char, text, ok|
                if ok
                  log "REWARDS #{name}: #{char} - #{text}"
                else
                  result['ok'] = false
                  log "!!! REWARDS #{name}: #{char} daily login reward failed - #{text}", $stderr
                end
              end
            rescue ChronoEAccess::Error => e
              result['logins'] = [['(account)', e.message, false]]
              result['ok'] = false
              log "!!! REWARDS #{name}: daily login rewards failed - #{e.message}", $stderr
            end
          end
        end
      end
      all_ok &&= result['ok']
      fresh = load
      fresh['last'][name] = result
      save(fresh)
    end
    all_ok
  end

  # One line for the window's "Last result" column.
  def summary(last)
    return 'never run' unless last
    when_s = Time.at(last['at']).strftime('%b %-d %-I:%M %p')
    parts = []
    parts << (last['error'] || '') if last['error']
    if (c = last['coins'])
      parts << case c['status']
               when 'claimed' then "SimuCoins claimed#{c['balance'].to_s.empty? ? '' : " (balance #{c['balance']})"}"
               when 'not_due' then c['message']
               when 'none' then 'no SimuCoin reward offered'
               else "SimuCoins FAILED: #{c['message']}"
               end
    end
    if (l = last['logins'])
      ok = l.count { |row| row[2] }
      parts << (l.size == 1 && l[0][0].start_with?('(') ? "daily: #{l[0][1]}" : "daily: #{ok}/#{l.size} characters ok")
    end
    "#{when_s}: #{parts.reject(&:empty?).join('; ')}"
  end
end
