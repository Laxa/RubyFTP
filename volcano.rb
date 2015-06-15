#!/usr/bin/env ruby
require "socket"
include Socket::Constants

# Volcano FTP contants
BINARY_MODE = 0
ASCII_MODE = 1
MIN_PORT = 1025
MAX_PORT = 65534

# Volcano FTP class
class VolcanoFtp
  def initialize(port)
    # Prepare instance
    @socket = TCPServer.new("", port)
    @socket.listen(42)

    @pids = []
    @transfert_type = BINARY_MODE
    @tsocket = nil
    puts "Server ready to listen for clients on port #{port}"
  end

  def ftp_syst(args)
    @cs.write "215 UNIX Type: L8\r\n"
    0
  end

  def ftp_noop(args)
    @cs.write "200 Don't worry my lovely client, I'm here ;)"
    0
  end

  def ftp_502(*args)
    puts "Command not found"
    @cs.write "502 Command not implemented\r\n"
    0
  end

  def ftp_exit(args)
    @cs.write "221 Thank you for using Volcano FTP\r\n"
    -1
  end

  def run
    while (42)
      selectResult = IO.select([@socket], nil, nil, 0.1)
      if selectResult == nil or selectResult[0].include?(@socket) == false
        @pids.each do |pid|
          if not Process.waitpid(pid, Process::WNOHANG).nil?
            ####
            # Do stuff with newly terminated processes here

            ####
            @pids.delete(pid)
          end
        end
        p @pids
      else
        @cs,  = @socket.accept
        peeraddr = @cs.peeraddr.dup
        @pids << Kernel.fork do
          puts "[#{Process.pid}] Instanciating connection from #{@cs.peeraddr[2]}:#{@cs.peeraddr[1]}"
          @cs.write "220-\r\n\r\n Welcome to Volcano FTP server !\r\n\r\n220 Connected\r\n"
          while not (line = @cs.gets).nil?
            puts "[#{Process.pid}] Client sent : --#{line}--"
            ####
            # Handle commands here
            ####
          end
          puts "[#{Process.pid}] Killing connection from #{peeraddr[2]}:#{peeraddr[1]}"
          @cs.close
          Kernel.exit!
        end
      end
    end
  end

protected

  # Protected methods go here

end

# Main

if ARGV[0]
  begin
    ftp = VolcanoFtp.new(ARGV[0])
    ftp.run
  rescue SystemExit, Interrupt
    puts "Caught CTRL+C, exiting"
  rescue RuntimeError => e
    puts e
  end
end
