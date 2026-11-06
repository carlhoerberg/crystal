{% skip_file if flag?(:wasm32) %}

require "./spec_helper"

private class HappyEyeballsSocket
  getter? closed = false
  getter? finished = false
  getter timeout : Time::Span?
  @cancel = Channel(Nil).new(1)

  def initialize(@behavior : Symbol)
  end

  def connect(address, *, timeout)
    @timeout = timeout
    case @behavior
    when :stall
      @cancel.receive
      raise IO::Error.new("Cancelled")
    when :late_success
      sleep 5.milliseconds
    when :fail
      raise IO::TimeoutError.new("Connection timed out")
    end
  ensure
    @finished = true
  end

  def close
    return if @closed
    @closed = true
    @cancel.send(nil)
  end
end

private def happy_eyeballs_addresses
  Socket::Addrinfo.tcp("127.0.0.1", 80) + Socket::Addrinfo.tcp("127.0.0.2", 80)
end

describe Socket::HappyEyeballs do
  it "interleaves families while preserving the resolver's first preference and order within families" do
    v4 = Socket::Addrinfo.tcp("127.0.0.1", 80) + Socket::Addrinfo.tcp("127.0.0.2", 80)
    v6 = Socket::Addrinfo.tcp("::1", 80) + Socket::Addrinfo.tcp("::2", 80) + Socket::Addrinfo.tcp("::3", 80)
    Socket::HappyEyeballs.interleave(v6 + v4).map(&.ip_address.address).should eq([
      "::1", "127.0.0.1", "::2", "127.0.0.2", "::3",
    ])
    Socket::HappyEyeballs.interleave(v4 + v6).map(&.ip_address.address).should eq([
      "127.0.0.1", "::1", "127.0.0.2", "::2", "::3",
    ])
  end

  it "returns the first success without starting unnecessary attempts" do
    sockets = [] of HappyEyeballsSocket
    winner = Socket::HappyEyeballs.connect(happy_eyeballs_addresses) do
      socket = HappyEyeballsSocket.new(:success)
      sockets << socket
      socket
    end
    sockets.size.should eq(1)
    winner.should be(sockets.first)
    winner.closed?.should be_false
  ensure
    winner.try &.close
  end

  it "starts a second attempt while the first is pending and cancels the loser" do
    sockets = [HappyEyeballsSocket.new(:stall), HappyEyeballsSocket.new(:success)]
    starts = [] of Time::Instant
    winner = Socket::HappyEyeballs.connect(happy_eyeballs_addresses, 2.seconds, delay: 10.milliseconds) do
      socket = sockets[starts.size]
      starts << Time.instant
      socket
    end
    (starts[1] - starts[0]).should be >= 10.milliseconds
    winner.should be(sockets.last)
    winner.closed?.should be_false
    sockets.first.closed?.should be_true
    sockets.first.finished?.should be_true
    sockets.each { |socket| socket.timeout.should eq(2.seconds) }
  ensure
    winner.try &.close
  end

  it "allows an earlier pending attempt to win after a later one starts" do
    sockets = [HappyEyeballsSocket.new(:late_success), HappyEyeballsSocket.new(:stall)]
    index = 0
    winner = Socket::HappyEyeballs.connect(happy_eyeballs_addresses, delay: 1.millisecond) do
      socket = sockets[index]
      index += 1
      socket
    end
    index.should eq(2)
    winner.should be(sockets.first)
    winner.closed?.should be_false
    sockets.last.closed?.should be_true
    sockets.last.finished?.should be_true
  ensure
    winner.try &.close
  end

  it "starts the next attempt immediately after a failure" do
    sockets = [HappyEyeballsSocket.new(:fail), HappyEyeballsSocket.new(:success)]
    index = 0
    start = Time.instant
    winner = Socket::HappyEyeballs.connect(happy_eyeballs_addresses, delay: 5.seconds) do
      socket = sockets[index]
      index += 1
      socket
    end
    (Time.instant - start).should be < 2.seconds
    winner.should be(sockets.last)
    sockets.first.closed?.should be_true
  ensure
    winner.try &.close
  end

  it "keeps an earlier attempt alive when a later attempt fails" do
    sockets = [HappyEyeballsSocket.new(:stall), HappyEyeballsSocket.new(:fail), HappyEyeballsSocket.new(:success)]
    addresses = happy_eyeballs_addresses + Socket::Addrinfo.tcp("127.0.0.3", 80)
    index = 0
    winner = Socket::HappyEyeballs.connect(addresses, delay: 1.millisecond) do
      socket = sockets[index]
      index += 1
      socket
    end
    winner.should be(sockets.last)
    sockets.first.closed?.should be_true
    sockets.first.finished?.should be_true
    sockets[1].closed?.should be_true
  ensure
    winner.try &.close
  end

  it "handles an empty address list" do
    expect_raises(Socket::Error, "No addresses to connect to") do
      Socket::HappyEyeballs.connect([] of Socket::Addrinfo) { HappyEyeballsSocket.new(:success) }
    end
  end

  it "raises and closes every socket when all attempts fail" do
    sockets = [] of HappyEyeballsSocket
    expect_raises(IO::TimeoutError, "Connection timed out") do
      Socket::HappyEyeballs.connect(happy_eyeballs_addresses) do
        socket = HappyEyeballsSocket.new(:fail)
        sockets << socket
        socket
      end
    end
    sockets.size.should eq(2)
    sockets.all?(&.closed?).should be_true
    sockets.all?(&.finished?).should be_true
  end

  it "cancels outstanding attempts if creating another socket raises" do
    socket = HappyEyeballsSocket.new(:stall)
    created = false
    expect_raises(IO::Error, "Socket creation failed") do
      Socket::HappyEyeballs.connect(happy_eyeballs_addresses, delay: 1.millisecond) do
        raise IO::Error.new("Socket creation failed") if created
        created = true
        socket
      end
    end
    socket.closed?.should be_true
    socket.finished?.should be_true
  end
end

private class HappyEyeballsSubclass < TCPSocket
  getter initialized : Bool

  def initialize(host : String, port)
    @initialized = true
    super(host, port)
  end
end

describe "Happy Eyeballs integration", tags: "network" do
  it "falls back after a real connection refusal" do
    TCPServer.open("127.0.0.1", 0) do |server|
      addresses = Socket::Addrinfo.tcp("127.0.0.2", server.local_address.port) +
                  Socket::Addrinfo.tcp("127.0.0.1", server.local_address.port)
      sockets = [] of TCPSocket
      winner = Socket::HappyEyeballs.connect(addresses, 1.second) do |address|
        socket = TCPSocket.new(address.family)
        sockets << socket
        socket
      end
      begin
        winner.remote_address.should eq(server.local_address)
        sockets.size.should eq(2)
        sockets.first.closed?.should be_true
        server.accept.close
      ensure
        winner.close
      end
    end
  end

  it "preserves subclass initialization" do
    TCPServer.open("127.0.0.1", 0) do |server|
      socket = HappyEyeballsSubclass.new("localhost", server.local_address.port)
      begin
        socket.initialized.should be_true
        server.accept.close
      ensure
        socket.close
      end
    end
  end
end
