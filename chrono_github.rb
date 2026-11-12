# chrono_github.rb - sets up elanthia-online's simu-rewards on GitHub for the user, so rewards
# are claimed even while the computer is off. Loaded by chrono.rb (needs fail!, log).
#
# Sign-in is GitHub's device flow: Chrono shows a short code, the user enters it at
# github.com/login/device. The token is used for that one setup, then forgotten: never saved.
# Then, through GitHub's API:
#   - a private repository (chrono4lich-rewards) is created if it doesn't exist,
#   - each account and password is stored as an encrypted repository secret
#     (ACCOUNT1/PASSWORD1, ...; encrypted on this computer with the repository's public key),
#   - .github/workflows/rewards.yml runs simu-rewards' action daily, plus a step that stops
#     GitHub from pausing the schedule after 60 days without activity,
#   - a first run is started so the user can see it work.
#
# Exact timing (optional, see chrono_cronjob.rb): GitHub's own timer often starts runs late or skips
# them. With exact timing, cron-job.org starts the run at the chosen time, and GitHub's own
# schedule becomes a backup a few hours later that only claims if the day's run didn't succeed.

require 'json'
require 'net/http'
require 'uri'
require 'base64'
require_relative 'chrono_sealedbox'

module ChronoGitHub
  CLIENT_ID = 'Ov23likZ92yTQPZrZmg1' # Chrono4Lich's GitHub OAuth app (public by design; no secret)
  WEB       = ENV['CHRONO_GITHUB_WEB'] || 'https://github.com'     # override for testing only
  API       = ENV['CHRONO_GITHUB_API'] || 'https://api.github.com' # override for testing only
  SCOPES    = 'repo workflow'
  REPO_NAME = 'chrono4lich-rewards'
  # Where Chrono itself is published (for the update check). Override for testing only.
  PROJECT_REPO = ENV['CHRONO_PROJECT_REPO'] || 'jmbreitfeld/Chrono4Lich'
  PROJECT_URL  = "#{WEB}/#{PROJECT_REPO}"
  WORKFLOW  = 'rewards.yml'
  ACTION    = 'elanthia-online/simu-rewards@v1'
  USER_AGENT = 'Chrono4Lich'

  class Error < StandardError; end

  module_function

  # ---------- HTTP ----------

  def http(method, url, body: nil, token: nil, form: false)
    uri = URI(url)
    req = Net::HTTP.const_get(method.capitalize).new(uri)
    req['User-Agent'] = USER_AGENT
    req['Accept'] = token ? 'application/vnd.github+json' : 'application/json'
    req['X-GitHub-Api-Version'] = '2022-11-28' if token
    req['Authorization'] = "Bearer #{token}" if token
    if body
      if form
        req.set_form_data(body)
      else
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
      end
    end
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 15, read_timeout: 30) do |h|
      h.request(req)
    end
    data = res.body.to_s.empty? ? {} : (JSON.parse(res.body) rescue { 'message' => res.body.to_s[0, 200] })
    [res.code.to_i, data]
  rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
    raise Error, "Couldn't reach GitHub: #{e.message}"
  end

  # Calls the API; raises a readable Error unless the status is one of ok.
  def api(method, path, token, body = nil, ok: [200, 201, 204])
    code, data = http(method, "#{API}#{path}", body: body, token: token)
    return data if ok.include?(code)

    msg = data.is_a?(Hash) ? data['message'].to_s : ''
    raise Error, case code
                 when 401 then 'GitHub says the sign-in has expired or was revoked. Sign in again.'
                 when 403 then "GitHub refused (#{msg}). If it mentions scopes or permissions, sign in again and approve all requested access."
                 when 404 then "GitHub couldn't find #{path.split('?').first} (#{msg})."
                 else "GitHub answered #{code}: #{msg}"
                 end
  end

  # ---------- device sign-in ----------

  # Returns {device_code:, user_code:, verification_uri:, interval:, expires_at:}
  def start_sign_in
    code, data = http(:post, "#{WEB}/login/device/code", body: { client_id: CLIENT_ID, scope: SCOPES }, form: true)
    unless code == 200 && data['user_code']
      raise Error, "GitHub didn't start the sign-in: #{data['error_description'] || data['error'] || data['message'] || code}"
    end
    { device_code: data['device_code'], user_code: data['user_code'],
      verification_uri: data['verification_uri'] || "#{WEB}/login/device",
      interval: (data['interval'] || 5).to_i, expires_at: Time.now + (data['expires_in'] || 900).to_i }
  end

  # Waits until the user approves (or declines) in the browser. Returns the token.
  # cancelled: a lambda; when it returns true, waiting stops.
  def wait_for_token(device, cancelled: -> { false })
    interval = device[:interval]
    loop do
      raise Error, 'Sign-in cancelled.' if cancelled.call
      raise Error, 'The code expired before it was entered. Start the sign-in again.' if Time.now > device[:expires_at]

      sleep interval
      raise Error, 'Sign-in cancelled.' if cancelled.call
      _, data = http(:post, "#{WEB}/login/oauth/access_token",
                     body: { client_id: CLIENT_ID, device_code: device[:device_code],
                             grant_type: 'urn:ietf:params:oauth:grant-type:device_code' }, form: true)
      return data['access_token'] if data['access_token']

      case data['error']
      when 'authorization_pending' then next
      when 'slow_down' then interval = (data['interval'] || interval + 5).to_i
      when 'expired_token' then raise Error, 'The code expired before it was entered. Start the sign-in again.'
      when 'access_denied' then raise Error, 'The sign-in was declined on GitHub.'
      else raise Error, "GitHub sign-in failed: #{data['error_description'] || data['error'] || 'unknown reply'}"
      end
    end
  end

  # ---------- the workflow ----------

  BACKUP_DELAY = 3 * 3600 + 7 * 60 # backup run: 3h07m after the chosen time (off the busy top of the hour)
  CHECK_REF = 'chrono4lich-token-check' # a branch that doesn't exist; see check_run_token

  # local "HH:MM" -> the backup run's local "HH:MM"
  def backup_time(local_time)
    h, m = local_time.split(':').map(&:to_i)
    t = (h * 3600 + m * 60 + BACKUP_DELAY) % 86_400
    format('%02d:%02d', t / 3600, t % 3600 / 60)
  end

  # local "HH:MM" today -> GitHub cron (GitHub only runs on UTC)
  def utc_cron(local_time)
    h, m = local_time.split(':').map(&:to_i)
    now = Time.now
    t = Time.local(now.year, now.month, now.day, h, m).utc
    "#{t.min} #{t.hour} * * *"
  end

  # accounts: [{n:, name:, daily:}] - n is the secret number (ACCOUNTn/PASSWORDn)
  # exact: cron-job.org starts the daily run; GitHub's schedule is only the backup.
  def workflow_yaml(accounts, local_time, exact: false)
    matrix = accounts.map do |a|
      "          - account: ACCOUNT#{a[:n]}\n" \
      "            password: PASSWORD#{a[:n]}\n" \
      "            bypass_login: '#{a[:daily] ? 'false' : 'true'}'\n"
    end.join
    <<~YAML
      # Made by Chrono4Lich. Chrono replaces this file when you click "Set up / update GitHub",
      # so make changes in Chrono rather than here.
      # Claims SimuCoins (and, where turned on, daily login rewards) with elanthia-online/simu-rewards.
      name: rewards

      on:
        workflow_dispatch:
        schedule:
      #{schedule_comment(local_time, exact)}
          - cron: "#{exact ? utc_cron(backup_time(local_time)) : utc_cron(local_time)}"

      permissions:
        contents: read

      # one run at a time, so two runs never log the same characters in together
      concurrency:
        group: rewards
        cancel-in-progress: false

      jobs:
      #{exact ? check_job : ''}
        login-account:
      #{exact ? "    needs: check\n    if: needs.check.outputs.skip != 'true'\n" : ''}    runs-on: ubuntu-latest
          strategy:
            fail-fast: false
            matrix:
              include:
      #{matrix.rstrip}
          name: rewards ${{ matrix.account }}
          steps:
            # A failed claim (for example Simutronics' servers answering "internal server error")
            # is tried again after 5 minutes, then after 15. Claiming twice is harmless.
            - name: claim
              id: try1
              continue-on-error: true
              uses: #{ACTION}
              with:
                account: ${{ secrets[matrix.account] }}
                password: ${{ secrets[matrix.password] }}
                game: GS3
                bypass_login: ${{ matrix.bypass_login }}
            - name: wait 5 minutes before trying again
              if: steps.try1.outcome == 'failure'
              run: sleep 300
            - name: claim (try 2)
              id: try2
              if: steps.try1.outcome == 'failure'
              continue-on-error: true
              uses: #{ACTION}
              with:
                account: ${{ secrets[matrix.account] }}
                password: ${{ secrets[matrix.password] }}
                game: GS3
                bypass_login: ${{ matrix.bypass_login }}
            - name: wait 15 minutes before the last try
              if: steps.try2.outcome == 'failure'
              run: sleep 900
            - name: claim (try 3)
              id: try3
              if: steps.try2.outcome == 'failure'
              uses: #{ACTION}
              with:
                account: ${{ secrets[matrix.account] }}
                password: ${{ secrets[matrix.password] }}
                game: GS3
                bypass_login: ${{ matrix.bypass_login }}

        keepalive:
          # GitHub pauses scheduled workflows after 60 days without activity in the repository.
          # Re-enabling the workflow on each scheduled run keeps it going.
          if: github.event_name == 'schedule'
          runs-on: ubuntu-latest
          permissions:
            actions: write
          steps:
            - run: gh api -X PUT "repos/${{ github.repository }}/actions/workflows/#{WORKFLOW}/enable"
              env:
                GH_TOKEN: ${{ github.token }}
    YAML
  end

  def schedule_comment(local_time, exact)
    lines =
      if exact
        ["Backup only: cron-job.org starts the daily run at #{local_time} (set up by Chrono).",
         "This runs at #{backup_time(local_time)} and claims only if no run has succeeded in the last",
         '12 hours. GitHub runs on UTC, so it shifts by an hour with daylight saving time.']
      else
        ["#{local_time} on the computer that set this up. GitHub runs on UTC, so this shifts by an",
         'hour when daylight saving time starts or ends. GitHub may also start it late.']
      end
    lines.map { |l| "    # #{l}" }.join("\n")
  end

  # Backup runs check first whether the day's run already succeeded.
  def check_job
    <<~JOB.gsub(/^/, '  ').rstrip
      check:
        runs-on: ubuntu-latest
        permissions:
          actions: read
        outputs:
          skip: ${{ steps.check.outputs.skip }}
        steps:
          - id: check
            env:
              GH_TOKEN: ${{ github.token }}
            run: |
              skip=false
              if [ "${{ github.event_name }}" = "schedule" ]; then
                since=$(date -u -d '-12 hours' +%Y-%m-%dT%H:%M:%SZ)
                n=$(gh run list -R "${{ github.repository }}" --workflow #{WORKFLOW} --status success \\
                      --created ">=$since" --json databaseId --jq length || echo 0)
                if [ "${n:-0}" -gt 0 ]; then
                  skip=true
                  echo "A run already succeeded since $since; nothing to do."
                fi
              fi
              echo "skip=$skip" >> "$GITHUB_OUTPUT"
    JOB
  end

  # ---------- setup, run, stop ----------

  def login(token) = api(:get, '/user', token)['login']

  def ensure_repo(token, owner)
    code, data = http(:get, "#{API}/repos/#{owner}/#{REPO_NAME}", token: token)
    if code == 200
      raise Error, "github.com/#{owner}/#{REPO_NAME} exists and is public. Chrono only uses a private repository; make it private or rename it on GitHub, then try again." unless data['private']
      return data
    end
    raise Error, "GitHub answered #{code} when looking for the repository: #{data['message']}" unless code == 404

    api(:post, '/user/repos', token, { name: REPO_NAME, private: true, auto_init: true,
                                       description: 'Daily Simutronics rewards, set up by Chrono4Lich' })
  end

  def put_secret(token, repo, name, value, key)
    sealed = SealedBox.seal(value.to_s, Base64.decode64(key['key']))
    api(:put, "/repos/#{repo}/actions/secrets/#{name}", token,
        { encrypted_value: Base64.strict_encode64(sealed), key_id: key['key_id'] })
  end

  def put_file(token, repo, path, content, message)
    code, existing = http(:get, "#{API}/repos/#{repo}/contents/#{path}", token: token)
    body = { message: message, content: Base64.strict_encode64(content) }
    body[:sha] = existing['sha'] if code == 200 && existing['sha']
    api(:put, "/repos/#{repo}/contents/#{path}", token, body)
  end

  # accounts: [{name:, password:, daily:}]. progress: called with a line of text per step.
  # Returns {repo:, login:, accounts:, cron:, time:}.
  # first_run: start a run right away so the user can see it work (only on the first setup:
  # with daily logins on, a run while someone is playing would disconnect them).
  def sync!(token, accounts, local_time, exact: false, first_run: true, progress: ->(_) {})
    fail! 'No accounts are set to claim on GitHub.' if accounts.empty?
    owner = login(token)
    progress.call("Signed in to GitHub as #{owner}.")
    repo_data = ensure_repo(token, owner)
    repo = repo_data['full_name'] || "#{owner}/#{REPO_NAME}"
    progress.call("Private repository: github.com/#{repo}")

    key = api(:get, "/repos/#{repo}/actions/secrets/public-key", token)
    numbered = accounts.sort_by { |a| a[:name] }.each_with_index.map { |a, i| a.merge(n: i + 1) }
    numbered.each do |a|
      put_secret(token, repo, "ACCOUNT#{a[:n]}", a[:name], key)
      put_secret(token, repo, "PASSWORD#{a[:n]}", a[:password], key)
      progress.call("Saved the encrypted login for #{a[:name]}.")
    end
    # remove secrets left from accounts no longer on GitHub
    existing = api(:get, "/repos/#{repo}/actions/secrets?per_page=100", token)['secrets'].to_a.map { |s| s['name'] }
    existing.grep(/\A(ACCOUNT|PASSWORD)(\d+)\z/).each do |name|
      next if name[/\d+/].to_i <= numbered.size
      api(:delete, "/repos/#{repo}/actions/secrets/#{name}", token, ok: [204, 404])
    end

    put_file(token, repo, ".github/workflows/#{WORKFLOW}", workflow_yaml(numbered, local_time, exact: exact),
             'Chrono4Lich: update the rewards schedule')
    if exact
      progress.call("Wrote the daily run (started by cron-job.org at #{local_time}), with GitHub's own " \
                    "schedule as a backup at #{backup_time(local_time)}.")
    else
      progress.call("Wrote the daily schedule (#{local_time} here, #{utc_cron(local_time)} UTC on GitHub).")
    end
    api(:put, "/repos/#{repo}/actions/workflows/#{WORKFLOW}/enable", token, ok: [204, 404])
    if first_run
      run_now!(token, repo, repo_data['default_branch'] || 'main')
      progress.call('Started a first run so you can see it work.')
    else
      progress.call('Updated. The next run is at the scheduled time.')
    end
    log "GITHUB set up #{repo} for #{numbered.map { |a| a[:name] }.join(', ')} at #{local_time}"
    { repo: repo, login: owner, accounts: numbered.map { |a| a[:name] }, cron: utc_cron(local_time), time: local_time,
      branch: repo_data['default_branch'] || 'main', exact: exact }
  end

  def run_now!(token, repo, branch)
    # A just-written workflow can take a moment to register; retry briefly.
    4.times do |i|
      code, data = http(:post, "#{API}/repos/#{repo}/actions/workflows/#{WORKFLOW}/dispatches",
                        body: { ref: branch }, token: token)
      return true if [200, 204].include?(code)
      raise Error, "GitHub wouldn't start the run (#{code}): #{data['message']}" unless [404, 422].include?(code) && i < 3

      sleep 3
    end
  end

  # Turns the schedule off and deletes the stored passwords. The repository itself is kept
  # (deleting a repository needs a broader permission than Chrono asks for).
  def stop!(token, repo)
    api(:put, "/repos/#{repo}/actions/workflows/#{WORKFLOW}/disable", token, ok: [204, 404])
    names = api(:get, "/repos/#{repo}/actions/secrets?per_page=100", token)['secrets'].to_a.map { |s| s['name'] }
    names.grep(/\A(ACCOUNT|PASSWORD|GAMECODE)\d+\z/).each do |name|
      api(:delete, "/repos/#{repo}/actions/secrets/#{name}", token, ok: [204, 404])
    end
    log "GITHUB stopped #{repo}: schedule off, stored logins deleted"
  end

  def actions_url(repo) = "#{WEB}/#{repo}/actions"

  # ---------- Chrono's own updates ----------

  # The newest published release of Chrono: {version: '1.8.1', url: release page, notes:}, or nil
  # if GitHub can't be reached (the check is a convenience; it never gets in the way).
  def latest_release
    code, data = http(:get, "#{API}/repos/#{PROJECT_REPO}/releases/latest")
    return nil unless code == 200 && data.is_a?(Hash) && data['tag_name']

    version = data['tag_name'].to_s.sub(/\Av/i, '')
    return nil unless Gem::Version.correct?(version)

    { version: version, url: data['html_url'] || "#{PROJECT_URL}/releases/latest", notes: data['body'].to_s }
  rescue StandardError
    nil
  end

  def newer?(available, current)
    Gem::Version.new(available) > Gem::Version.new(current)
  rescue ArgumentError
    false
  end

  # ---------- the token cron-job.org uses to start runs ----------

  def dispatch_url(repo) = "#{API}/repos/#{repo}/actions/workflows/#{WORKFLOW}/dispatches"

  # GitHub's page for a new fine-grained token, filled in: Actions read/write, no expiry. The
  # user still picks the one repository it may use (GitHub's page can't preselect it).
  def run_token_url
    q = URI.encode_www_form(name: 'Chrono4Lich exact timing',
                            description: "Lets cron-job.org start Chrono4Lich's daily rewards run in #{REPO_NAME}. " \
                                         'Only for that repository; can start runs, cannot read your logins.',
                            expires_in: 'none', actions: 'write')
    "#{WEB}/settings/personal-access-tokens/new?#{q}"
  end

  # Checks that the token can start runs in the repository, without starting one: it asks GitHub
  # to run the workflow on a branch that doesn't exist. GitHub checks permission first (403/404),
  # then the branch (422), so 422 means the token works.
  # (Whether the token is limited to this one repository can't be checked: any token can see the
  # user's public repositories, so GitHub lists them all. The setup window asks for it instead.)
  def check_run_token(token, repo)
    token = token.to_s.strip
    raise Error, 'Paste the token GitHub showed you (it starts with github_pat_).' if token.empty?
    if token.start_with?('gho_', 'ghu_')
      raise Error, "That's a sign-in token, not the one from GitHub's token page. Create the token on that page and paste it."
    end

    code, data = http(:post, dispatch_url(repo), body: { ref: CHECK_REF }, token: token)
    case code
    when 422, 200, 204 then true
    when 401 then raise Error, 'GitHub didn\'t accept that token. Check you copied all of it, or create a new one.'
    when 403 then raise Error, "The token can see #{repo} but can't start runs. On GitHub, edit the token: under " \
                               'Permissions, set "Actions" to "Read and write".'
    when 404 then raise Error, "The token can't see #{repo}. On GitHub, edit the token: under Repository access, choose " \
                               "\"Only select repositories\" and pick #{REPO_NAME}."
    else raise Error, "GitHub answered #{code} when checking the token: #{data['message']}"
    end
  end
end
