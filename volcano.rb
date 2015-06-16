#!/usr/bin/env ruby

require 'socket'
require 'yaml'
require 'logger'
include Socket::Constants

# Volcano FTP contants
BINARY_MODE = 0
ASCII_MODE = 1
MIN_PORT = 1025
MAX_PORT = 65534

# Volcano FTP class
class VolcanoFtp
  def initialize(port = 21)
    # Prepare instance
    if Process.euid != 1 and port < 1024
      raise 'You need root privilege to bind on port < 1024'
    end
    @socket = TCPServer.new port
    @socket.listen(42)

    @pids = []
    @transfert_type = BINARY_MODE
    @tsocket = nil

    # logger part
    @log = Logger.new('logging.log')
    @log.level = Logger::DEBUG
    puts "Server ready to listen for clients on port #{port}"
    @log.info "Server ready to listen for clients on port #{port}"
  end

  def run
    while (42)
      selectResult = IO.select([@socket], nil, nil, 1)
      if selectResult == nil or selectResult[0].include?(@socket) == false
        @pids.each do |pid|
          if not Process.waitpid(pid, Process::WNOHANG).nil?
            ####
            # Do stuff with newly terminated processes here
            ####
            @pids.delete(pid)
          end
        end
        if !@pids.count.zero?
          puts "Currently connected clients : #{@pids}"
        end
      else
        @cs,  = @socket.accept
        peeraddr = @cs.peeraddr.dup
        @pids << Kernel.fork do
          puts "[#{Process.pid}] Instanciating connection from #{@cs.peeraddr[2]}:#{@cs.peeraddr[1]}"
          @log.info "[#{Process.pid}] Instanciating connection from #{@cs.peeraddr[2]}:#{@cs.peeraddr[1]}"
          @cs.write "220-\r\n\r\n Welcome to Volcano FTP server !\r\n\r\n220 Connected\r\n"
          while not (line = @cs.gets).nil?
            puts "[#{Process.pid}] Client sent : --#{line}--"
            @log.info "Client sent : --#{line}--"
            begin
            rescue RunTimeError => e
              @log.fatal "Client encountered a problem while talking with server : #{e}"
            end
            ####
            # Handle commands here
            ####
          end
          puts "[#{Process.pid}] Killing connection from #{peeraddr[2]}:#{peeraddr[1]}"
          @log.info "[#{Process.pid}] Killing connection from #{peeraddr[2]}:#{peeraddr[1]}"
          @cs.close
          Kernel.exit!
        end
      end
    end
  end

protected

  def ftp_syst(args)
    @cs.write "215 UNIX Type: L8\r\n"
    @log.info "215 UNIX Type: L8\r\n"
  end

  def ftp_noop(args)
    @cs.write "200 Don't worry my lovely client, I'm here ;)"
    @log.info "200 Don't worry my lovely client, I'm here ;)"
  end

  def ftp_502(*args)
    @cs.write "502 Command not implemented\r\n"
    $log.info "502 Command not implemented\r\n"
  end

  def ftp_exit(args)
    @cs.write "221 Thank you for using Volcano FTP\r\n"
    @log.info "221 Thank you for using Volcano FTP\r\n"
  end

private

end

# Main

begin
  ftp = VolcanoFtp.new(ARGV[0].to_i)
  ftp.run
rescue SystemExit, Interrupt
  puts 'Caught CTRL+C, exiting'
rescue RuntimeError => e
  puts "VolcanoFTP encountered a RunTimeError : #{e}"
end
