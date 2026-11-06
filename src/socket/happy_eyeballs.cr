# :nodoc:
# Implements the connection racing phase of RFC 8305. DNS resolution and the
# initial address preference remain the responsibility of the system resolver.
module Socket::HappyEyeballs
  def self.interleave(addresses : Array(Addrinfo)) : Array(Addrinfo)
    return addresses if addresses.size < 2

    preferred, alternate = addresses.partition { |address| address.family == addresses.first.family }
    result = Array(Addrinfo).new(addresses.size)
    preferred.each_with_index do |address, index|
      result << address
      result << alternate[index] if index < alternate.size
    end
    result.concat(alternate[preferred.size..]) if alternate.size > preferred.size
    result
  end

  # The caller creates each socket; this method owns it until it returns the
  # winner. Buffered results let attempts finish even while losers are closed.
  def self.connect(addresses : Array(Addrinfo), connect_timeout = nil, delay = 250.milliseconds, & : Addrinfo -> T) : T forall T
    raise Socket::Error.new("No addresses to connect to") if addresses.empty?

    addresses = interleave(addresses)
    results = Channel(T | Exception).new(addresses.size)
    sockets = [] of T
    winner = nil
    pending = 0
    index = 0

    begin
      loop do
        address = addresses[index]
        socket = yield address
        sockets << socket
        pending += 1
        index += 1
        spawn attempt(socket, address, connect_timeout, results)

        deadline = Time.instant + delay
        loop do
          if index < addresses.size && pending > 0
            remaining = deadline - Time.instant
            break if remaining <= Time::Span.zero
            select
            when result = results.receive
            when timeout(remaining)
              break
            end
          else
            result = results.receive
          end

          pending -= 1
          if result.is_a?(Exception)
            break if index < addresses.size
            raise result if pending == 0
          else
            winner = result
            return result
          end
        end
      end
    ensure
      sockets.each do |socket|
        socket.close unless socket.same?(winner)
      end
      # Closing cancels pending connects. Wait for their fibers to release all
      # references before returning, including attempts that also succeeded.
      pending.times { results.receive }
    end
  end

  private def self.attempt(socket, address, connect_timeout, results) : Nil
    socket.connect(address, timeout: connect_timeout)
    results.send(socket)
  rescue ex
    results.send(ex)
  end
end
