# chrono_eaccess.rb - asks Simutronics' login service (eAccess) which characters an account has.
#
# Follows the same exchange Lich uses for its saved-login setup (K, A, M, then N/F/G/P/C per game).
# It only lists characters; it never launches a game session, so nothing gets logged in.
# The password is used only on this connection: it is never written anywhere or logged.
#
# Security: the login service uses its own (self-signed) certificate. Before anything is sent,
# the certificate it presents must be exactly one Chrono knows: the one Lich saved (data/simu.pem,
# which Lich keeps up to date), or one listed in KNOWN_CERTS below. Anything else, Chrono stops,
# so the password never goes to an impostor. (The password is only masked on the wire, not
# encrypted, so that check is what protects it.)

require 'openssl'
require 'socket'
require 'io/wait'
require 'digest'
require_relative 'chrono_config'

module ChronoEAccess
  HOST = ChronoConfig.dev_env('CHRONO_EACCESS_HOST') || 'eaccess.play.net' # (testing only)
  PORT = Integer(ChronoConfig.dev_env('CHRONO_EACCESS_PORT') || 7910)
  CONNECT_TIMEOUT   = 8
  HANDSHAKE_TIMEOUT = 15
  READ_TIMEOUT      = 15
  # SHA-256 of Simutronics' eAccess certificate(s) (DER), for players whose Lich hasn't saved
  # simu.pem yet. Lich's simu.pem is trusted as well, so a certificate change Lich has picked up
  # keeps working; add the new one here in the next release.
  KNOWN_CERTS = [
    '10b737e661987d15bc5c8245e3f8b78291d41ed8abc76672ecb02fe78ed0218a' # Simutronics Corp., Missouri; issued 2018-07-16, valid until 3017
  ].freeze
  GEMSTONE_CODES  = %w[GS3 GSF GST GSX].freeze
  DRAGONREALMS_CODES = %w[DR DRF DRT DRX].freeze
  ALL_CODES = (GEMSTONE_CODES + DRAGONREALMS_CODES).freeze

  class Error < StandardError; end

  module_function

  # Returns [{game_code:, game_name:, char_name:}] for every character on the account in the games
  # given by codes (GemStone's unless told otherwise) that the account is subscribed to.
  def list_characters(account, password, data_dir: nil, codes: GEMSTONE_CODES)
    account = account.to_s.strip
    raise Error, 'Enter the account name.' if account.empty?
    raise Error, 'Enter the password.' if password.to_s.empty?
    raise Error, 'The password has characters the login service can\'t accept.' unless password.ascii_only?

    conn = connect(data_dir)
    begin
      games = authenticate(conn, account, password)
      found = []
      games.sub(/\AM\t/, '').scan(/[^\t]+\t[^\t\n]+/).each do |pair|
        code, name = pair.split("\t")
        next unless codes.include?(code)
        next unless exchange(conn, "N\t#{code}\n").include?('STORM')
        next unless exchange(conn, "F\t#{code}\n") =~ /NORMAL|PREMIUM|TRIAL|INTERNAL|FREE/ # not subscribed: skip

        exchange(conn, "G\t#{code}\n")
        exchange(conn, "P\t#{code}\n")
        chars = exchange(conn, "C\n")
        chars.sub(/\AC\t\d+\t\d+\t\d+\t\d+[\t\n]?/, '').scan(/[^\t]+\t[^\t\n]+/).each do |slot_name|
          _slot, char_name = slot_name.split("\t")
          found << { game_code: code, game_name: name.strip, char_name: char_name.strip }
        end
      end
      found
    ensure
      conn.close rescue nil
    end
  end

  # The account's plan in each of the given games it plays: {code => 'NORMAL'|'PREMIUM'|'TRIAL'|
  # 'INTERNAL'|'FREE'}, the same answer Lich reads at login. FREE is free-to-play. Games the account
  # doesn't play (the service says NEW_TO_GAME) are left out.
  def plans(account, password, codes: ALL_CODES, data_dir: nil)
    conn = connect(data_dir)
    begin
      games = authenticate(conn, account, password)
      found = {}
      games.sub(/\AM\t/, '').scan(/[^\t]+\t[^\t\n]+/).each do |pair|
        code = pair.split("\t").first
        next unless codes.include?(code)
        next unless exchange(conn, "N\t#{code}\n").include?('STORM')

        tier = exchange(conn, "F\t#{code}\n")[/NORMAL|PREMIUM|TRIAL|INTERNAL|FREE/]
        found[code] = tier if tier
      end
      found
    ensure
      conn.close rescue nil
    end
  end

  # Asks for a one-time key to enter the game as one character, the same way Lich does before
  # it connects. Returns {host:, port:, key:}. Using the key is what actually logs the character in.
  def launch_key(account, password, game_code, char_name, data_dir: nil)
    conn = connect(data_dir)
    begin
      authenticate(conn, account, password)
      reply = exchange(conn, "F\t#{game_code}\n")
      raise Error, "Account #{account} isn't subscribed to #{game_code}." unless reply =~ /NORMAL|PREMIUM|TRIAL|INTERNAL|FREE/

      exchange(conn, "G\t#{game_code}\n")
      exchange(conn, "P\t#{game_code}\n")
      chars = exchange(conn, "C\n")
      slot = chars.sub(/\AC\t\d+\t\d+\t\d+\t\d+[\t\n]?/, '').scan(/[^\t]+\t[^\t\n]+/)
                  .map { |pair| pair.split("\t").map(&:strip) }
                  .find { |_s, name| name.casecmp?(char_name) }&.first
      raise Error, "#{char_name} isn't a character on account #{account} in #{game_code}." unless slot

      reply = exchange(conn, "L\t#{slot}\tSTORM\n")
      raise Error, "The login service wouldn't start #{char_name}: #{reply.strip[0, 80]}" unless reply.start_with?("L\tOK\t")

      fields = reply.sub(/\AL\tOK\t/, '').strip.split("\t").to_h { |kv| kv.split('=', 2) }
      host = fields['GAMEHOST']
      port = Integer(fields['GAMEPORT'], exception: false)
      key  = fields['KEY']
      raise Error, "The login service's reply for #{char_name} was missing details." unless host && port && key

      { host: host, port: port, key: key }
    ensure
      conn.close rescue nil
    end
  end

  def authenticate(conn, account, password)
    raise Error, 'The password has characters the login service can\'t accept.' unless password.to_s.ascii_only?
    key = exchange(conn, "K\n")
    raise Error, 'The login service sent an unexpected reply. Try again in a minute.' if key.strip.empty? || key.bytesize < password.bytesize

    masked = password.bytes.each_with_index.map { |b, i| (((b - 32) ^ key.getbyte(i)) + 32).chr }.join
    reply = exchange(conn, "A\t#{account}\t#{masked}\n")
    raise Error, rejection_message(reply.split(/\s+/).last.to_s, account) unless reply.include?("\tKEY\t")

    games = exchange(conn, "M\n")
    raise Error, "Unexpected reply from the login service: #{games[0, 60].inspect}" unless games.start_with?("M\t")
    games
  end

  def rejection_message(code, account)
    case code
    when /PASSWORD/ then "Wrong password for account #{account}."
    when /NORECORD/ then "There is no account named #{account}."
    when /REJECT|INVALID/ then "The login service rejected account #{account} (#{code})."
    else "The login service didn't accept the login (#{code.empty? ? 'empty reply' : code}). Try again in a minute."
    end
  end

  def connect(data_dir)
    tcp = begin
      Socket.tcp(HOST, PORT, connect_timeout: CONNECT_TIMEOUT)
    rescue Errno::ETIMEDOUT, IO::TimeoutError
      raise Error, "Couldn't reach the login service (#{HOST}:#{PORT}). Check your internet connection or firewall."
    rescue SocketError, SystemCallError => e
      raise Error, "Couldn't reach the login service (#{HOST}:#{PORT}): #{e.message}"
    end

    trusted = trusted_certs(data_dir)
    # The certificate is self-signed, so the usual checks can't apply; it's compared exactly below,
    # after the handshake and before anything is sent.
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
    ssl.sync_close = true
    begin
      handshake(ssl)
    rescue OpenSSL::SSL::SSLError, SystemCallError, IOError => e
      tcp.close rescue nil
      raise Error, "Secure connection to the login service failed: #{e.message}"
    end
    seen = ssl.peer_cert && Digest::SHA256.hexdigest(ssl.peer_cert.to_der)
    unless seen && trusted.include?(seen)
      ssl.close rescue nil
      if trusted.empty?
        raise Error, 'Chrono can\'t confirm it\'s talking to Simutronics yet: Lich hasn\'t saved the login ' \
                     'service\'s certificate. Log in to any character once with Lich (that saves it), then try again.'
      end
      saved = data_dir && File.exist?(File.join(data_dir, 'simu.pem')) ? 'the one Lich saved' : 'Simutronics\' known one'
      raise Error, "The login service's security certificate isn't #{saved}, so Chrono stopped " \
                   'before sending the password. Log in once with Lich (it updates the saved certificate ' \
                   'if Simutronics changed it), then try again. If it keeps happening, your connection may ' \
                   'be being intercepted.'
    end
    ssl
  end

  # SHA-256 fingerprints of the certificates Chrono accepts.
  def trusted_certs(data_dir)
    list = KNOWN_CERTS.map(&:downcase)
    pem = data_dir && File.join(data_dir, 'simu.pem')
    if pem && File.exist?(pem)
      begin
        File.read(pem).scan(/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m).each do |c|
          list << Digest::SHA256.hexdigest(OpenSSL::X509::Certificate.new(c).to_der)
        end
      rescue OpenSSL::X509::CertificateError, SystemCallError
        nil # an unreadable simu.pem just doesn't count
      end
    end
    list.uniq
  end

  # TLS handshake with a deadline, so a server that stops partway can't hang a scheduled run.
  def handshake(ssl)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HANDSHAKE_TIMEOUT
    loop do
      case ssl.connect_nonblock(exception: false)
      when :wait_readable then wait = ssl.to_io.wait_readable(left(deadline))
      when :wait_writable then wait = ssl.to_io.wait_writable(left(deadline))
      else return
      end
      raise Error, 'The login service didn\'t complete a secure connection in time. Try again in a minute.' unless wait
    end
  end

  def left(deadline) = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max

  # One command, one reply, like Lich: the service doesn't reliably end replies with a newline.
  def exchange(conn, command)
    conn.write(command)
    unless conn.pending.positive? || conn.to_io.wait_readable(READ_TIMEOUT)
      raise Error, 'The login service stopped answering. Try again in a minute.'
    end

    conn.readpartial(8192).force_encoding(Encoding::BINARY)
  rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError
    raise Error, 'The login service closed the connection unexpectedly. Try again in a minute.'
  end
end
