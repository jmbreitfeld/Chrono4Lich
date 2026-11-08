# chrono_eaccess.rb - asks Simutronics' login service (eAccess) which characters an account has.
#
# Follows the same exchange Lich uses for its saved-login setup (K, A, M, then N/F/G/P/C per game).
# It only lists characters; it never launches a game session, so nothing gets logged in.
# The password is used only on this connection: it is never written anywhere or logged.
#
# Security: if Lich has pinned Simutronics' certificate (data/simu.pem), the connection must
# match it. If Lich hasn't (first use), the certificate is accepted, as Lich itself does then.

require 'openssl'
require 'socket'
require 'io/wait'

module ChronoEAccess
  HOST = ENV['CHRONO_EACCESS_HOST'] || 'eaccess.play.net' # override for testing only
  PORT = Integer(ENV['CHRONO_EACCESS_PORT'] || 7910)
  CONNECT_TIMEOUT = 8
  READ_TIMEOUT    = 15
  GEMSTONE_CODES  = %w[GS3 GSF GST GSX].freeze

  class Error < StandardError; end

  module_function

  # Returns [{game_code:, game_name:, char_name:}] for every GemStone character on the account
  # in games the account is subscribed to.
  def list_characters(account, password, data_dir: nil)
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
        next unless GEMSTONE_CODES.include?(code)
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

    pem = data_dir && File.join(data_dir, 'simu.pem')
    ctx = OpenSSL::SSL::SSLContext.new
    if pem && File.exist?(pem)
      store = OpenSSL::X509::Store.new
      store.add_file(pem)
      ctx.cert_store = store
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
    else
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
    ssl.sync_close = true
    begin
      ssl.connect
    rescue OpenSSL::SSL::SSLError => e
      tcp.close rescue nil
      if pem && File.exist?(pem) && e.message =~ /certificate/i
        raise Error, 'The login service\'s security certificate doesn\'t match the one Lich saved. ' \
                     'Log in once with Lich (it updates the saved certificate), then try again.'
      end
      raise Error, "Secure connection to the login service failed: #{e.message}"
    end
    if pem && File.exist?(pem) && ssl.peer_cert.to_pem != File.read(pem)
      ssl.close
      raise Error, 'The login service\'s security certificate doesn\'t match the one Lich saved. ' \
                   'Log in once with Lich (it updates the saved certificate), then try again.'
    end
    ssl
  end

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
