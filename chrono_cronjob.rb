# chrono_cronjob.rb - "exact timing" for rewards claimed on GitHub. Loaded by chrono.rb.
#
# GitHub's own timer often starts scheduled runs late (sometimes hours) or skips them. So Chrono
# can set up a free cron-job.org job that, at the chosen time each day, asks GitHub to start the
# rewards run - the same thing as clicking "Run workflow". GitHub starts those within a minute.
#
# The job holds a GitHub fine-grained token the user creates, limited to the chrono4lich-rewards
# repository and to starting runs (Actions: read and write). It can't read the stored logins.
# Chrono uses the user's cron-job.org API key to create, change or remove the job, then forgets
# it: neither the key nor the token is saved on this computer.

require 'json'
require 'net/http'
require 'uri'

module ChronoCronJob
  API   = ENV['CHRONO_CRONJOB_API'] || 'https://api.cron-job.org' # override for testing only
  WEB   = 'https://console.cron-job.org'
  KEY_PAGE = "#{WEB}/settings"
  TITLE = 'Chrono4Lich rewards'
  USER_AGENT = 'Chrono4Lich'

  class Error < StandardError; end

  module_function

  def request(method, path, key, body = nil)
    key = key.to_s.strip
    raise Error, 'Paste your cron-job.org API key (cron-job.org > Settings > API).' if key.empty?

    uri = URI("#{API}#{path}")
    req = Net::HTTP.const_get(method.capitalize).new(uri)
    req['User-Agent'] = USER_AGENT
    req['Authorization'] = "Bearer #{key}"
    if body
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(body)
    end
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 15, read_timeout: 30) do |h|
      h.request(req)
    end
    data = res.body.to_s.empty? ? {} : (JSON.parse(res.body) rescue { 'error' => res.body.to_s[0, 200] })
    code = res.code.to_i
    return data if code == 200

    raise Error, case code
                 when 401 then "cron-job.org didn't accept that API key. Check you copied all of it, or create a new one."
                 when 403 then 'cron-job.org refused the API key from this computer. If you limited the key to certain ' \
                               'IP addresses, add this one or remove the limit.'
                 when 404 then 'not found'
                 when 429 then 'cron-job.org says the API key has been used too often today. Try again tomorrow.'
                 else "cron-job.org answered #{code}: #{data['error'] || data['message']}"
                 end
  rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
    raise Error, "Couldn't reach cron-job.org: #{e.message}"
  end

  def schedule(local_time, tz)
    h, m = local_time.split(':').map(&:to_i)
    { timezone: tz, expiresAt: 0, hours: [h], minutes: [m], mdays: [-1], months: [-1], wdays: [-1] }
  end

  # The job: a POST to GitHub's "run workflow" address, with the token, daily at local_time.
  def job(repo, branch, token, local_time, tz)
    { title: TITLE, enabled: true, saveResponses: true,
      url: ChronoGitHub.dispatch_url(repo), requestMethod: 1, requestTimeout: 30,
      schedule: schedule(local_time, tz),
      extendedData: {
        headers: { 'Authorization' => "Bearer #{token.strip}", 'Accept' => 'application/vnd.github+json',
                   'X-GitHub-Api-Version' => '2022-11-28', 'Content-Type' => 'application/json',
                   'User-Agent' => USER_AGENT },
        body: JSON.generate(ref: branch)
      },
      # email the cron-job.org account if GitHub refuses to start the run (e.g. the token was deleted)
      notification: { onFailure: true, onFailureCount: 1, onSuccess: true, onDisable: true } }
  end

  # Chrono's job on this cron-job.org account, if there is one: its id or nil.
  def find(key)
    Array(request(:get, '/jobs', key)['jobs']).find { |j| j['title'] == TITLE }&.dig('jobId')
  end

  # Creates the job, or replaces Chrono's existing one (so setting up twice never makes two).
  # Returns the job id.
  def setup!(key, repo, branch, token, local_time, tz)
    payload = { job: job(repo, branch, token, local_time, tz) }
    if (id = find(key))
      request(:patch, "/jobs/#{id}", key, payload)
      id
    else
      request(:put, '/jobs', key, payload)['jobId'] or raise Error, "cron-job.org didn't return the new job's number."
    end
  end

  def set_time!(key, id, local_time, tz)
    request(:patch, "/jobs/#{id}", key, { job: { schedule: schedule(local_time, tz) } })
  rescue Error => e
    raise unless e.message == 'not found'

    raise Error, "Chrono's job is gone from cron-job.org (deleted there?). Set up exact timing again."
  end

  def delete!(key, id)
    request(:delete, "/jobs/#{id}", key)
  rescue Error => e
    raise unless e.message == 'not found'
  end

  # When the job runs next (Time) and how its last run went, for showing in the window.
  def status(key, id)
    d = request(:get, "/jobs/#{id}", key)['jobDetails'] || {}
    d = d.first if d.is_a?(Array)
    { next: d['nextExecution'] && Time.at(d['nextExecution']), last_status: d['lastStatus'] }
  end

  # ---------- this computer's time zone, by name (so daylight saving time is handled) ----------

  # Windows zone names -> IANA names cron-job.org understands (the common ones; from CLDR).
  WINDOWS_ZONES = {
    'Hawaiian Standard Time' => 'Pacific/Honolulu', 'Alaskan Standard Time' => 'America/Anchorage',
    'Pacific Standard Time' => 'America/Los_Angeles', 'US Mountain Standard Time' => 'America/Phoenix',
    'Mountain Standard Time' => 'America/Denver', 'Central Standard Time' => 'America/Chicago',
    'Eastern Standard Time' => 'America/New_York', 'US Eastern Standard Time' => 'America/Indiana/Indianapolis',
    'Atlantic Standard Time' => 'America/Halifax', 'Newfoundland Standard Time' => 'America/St_Johns',
    'Canada Central Standard Time' => 'America/Regina', 'Pacific Standard Time (Mexico)' => 'America/Tijuana',
    'Central Standard Time (Mexico)' => 'America/Mexico_City', 'Mountain Standard Time (Mexico)' => 'America/Mazatlan',
    'SA Pacific Standard Time' => 'America/Bogota', 'E. South America Standard Time' => 'America/Sao_Paulo',
    'Argentina Standard Time' => 'America/Buenos_Aires', 'UTC' => 'UTC', 'GMT Standard Time' => 'Europe/London',
    'Greenwich Standard Time' => 'Atlantic/Reykjavik', 'W. Europe Standard Time' => 'Europe/Berlin',
    'Romance Standard Time' => 'Europe/Paris', 'Central Europe Standard Time' => 'Europe/Budapest',
    'Central European Standard Time' => 'Europe/Warsaw', 'GTB Standard Time' => 'Europe/Bucharest',
    'FLE Standard Time' => 'Europe/Kiev', 'E. Europe Standard Time' => 'Europe/Chisinau',
    'Russian Standard Time' => 'Europe/Moscow', 'South Africa Standard Time' => 'Africa/Johannesburg',
    'Israel Standard Time' => 'Asia/Jerusalem', 'Arabian Standard Time' => 'Asia/Dubai',
    'India Standard Time' => 'Asia/Calcutta', 'SE Asia Standard Time' => 'Asia/Bangkok',
    'China Standard Time' => 'Asia/Shanghai', 'Singapore Standard Time' => 'Asia/Singapore',
    'Taipei Standard Time' => 'Asia/Taipei', 'Tokyo Standard Time' => 'Asia/Tokyo', 'Korea Standard Time' => 'Asia/Seoul',
    'W. Australia Standard Time' => 'Australia/Perth', 'Cen. Australia Standard Time' => 'Australia/Adelaide',
    'AUS Central Standard Time' => 'Australia/Darwin', 'E. Australia Standard Time' => 'Australia/Brisbane',
    'AUS Eastern Standard Time' => 'Australia/Sydney', 'Tasmania Standard Time' => 'Australia/Hobart',
    'New Zealand Standard Time' => 'Pacific/Auckland'
  }.freeze

  # IANA name like "America/Los_Angeles", or nil if it can't be told.
  def local_timezone
    return ENV['CHRONO_TZ'] if ENV['CHRONO_TZ'].to_s.include?('/') # override
    if Gem.win_platform?
      name = `tzutil /g 2>NUL`.to_s.strip.sub(/_dstoff\z/, '')
      return WINDOWS_ZONES[name]
    end
    tz = ENV['TZ'].to_s.sub(/\A:/, '')
    return tz if tz.include?('/') && !tz.start_with?('/')
    tz = (File.read('/etc/timezone').strip rescue '')
    return tz if tz.include?('/')
    link = (File.realpath('/etc/localtime') rescue '')
    return link.split('zoneinfo/', 2).last if link.include?('zoneinfo/')
    tz = `timedatectl show -p Timezone --value 2>/dev/null`.to_s.strip
    tz.include?('/') ? tz : nil
  rescue StandardError
    nil
  end
end
