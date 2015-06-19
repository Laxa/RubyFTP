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
    if Process.euid != 0 and port < 1024
      raise 'You need root privilege to bind on port < 1024'
    end
    @socket = TCPServer.new port
    @socket.listen(42)

    Dir.chdir(__dir__)

    @pids = []
    @transfert_type = BINARY_MODE
    @tsocket = nil

    # logger part
    # file = File.open('logging.log', File::WRONLY | File::TRUNC | File::CREAT)
    @log = Logger.new MultiIO.new(STDOUT)
    @log.level = Logger::DEBUG
    @log.progname = 'VolcanoFTP'
    @log.formatter = proc do |severity, datetime, progname, msg|
      "[#{datetime} ##{Process.pid}] #{severity} -- #{progname}: #{msg}\n"
    end
    @log.info "Server is listening on port #{port}"
  end

  def run
    while (42)
      selectResult = IO.select([@socket], nil, nil, 1)
      if selectResult == nil or selectResult[0].include?(@socket) == false
        @pids.each do |pid|
          unless Process.waitpid(pid, Process::WNOHANG).nil?
            # Gather data/stats here for last terminated process
            # puts "deleteting pid #{pid}"
            @pids.delete(pid)
          end
        end
      else
        @cs,  = @socket.accept
        peeraddr = @cs.peeraddr.dup
        @pids << Kernel.fork do
          begin
            handle_client
          rescue SignalException => e
            @log.warn "Caught signal #{e}"
          rescue Exception => e
            @log.fatal "Encountered Exception : #{e}"
          ensure
            ftp_exit
            @log.info "Killing connection from #{peeraddr[2]}:#{peeraddr[1]}"
            @cs.close
            Kernel.exit!
          end
        end
      end
    end
  end

  protected

  def handle_client
    @log.info "Instanciating connection from #{@cs.peeraddr[2]}:#{@cs.peeraddr[1]}"
    send_to_client_and_log(220, "Connected to VolcanoFTP")
    # client connection is on his root folder
    @dir = '/'
    while not (line = @cs.gets).nil?
      unless line.end_with? "\r\n"
        @log.warn "[server<-client]: #{line}"
      end
      while line.end_with? "\r\n"
        line = line[0..-2]
      end
      @log.info "[server<-client]: #{line}"
      cmd = 'ftp_' << line.split.first.downcase
      if self.respond_to?(cmd, true)
        send(cmd, line.split.drop(1))
      else
        ftp_not_yet_implemented
      end
    end
  end

  def ftp_noop
    send_to_client_and_log(200, "OK")
  end

  def ftp_not_yet_implemented
    send_to_client_and_log(502, "Not yet implemented")
  end

  def ftp_exit(args = nil)
    send_to_client_and_log(221, "Thank you for using VolcanoFTP")
  end

  def ftp_user(args)
    send_to_client_and_log(230, "You are now logged in as Anonymous")
  end

  def ftp_pwd(args)
    send_to_client_and_log(257, @dir)
  end

  def send_to_client_and_log(code, data)
    @cs.write "#{code} #{data}\r\n"
    @log.info "[server->client]: #{code} #{data}"
  end

  private

end

class MultiIO
  def initialize(*targets)
    @targets = targets
  end

  def write(*args)
    @targets.each {|t| t.write(*args)}
  end

  def close
    @targets.each(&:close)
  end
end

# Main

# to kill all process if needed, we use a specific name
$0 = 'volcanoFTP'

begin
  port = ARGV[0].to_i.zero? ? 21 : ARGV[0].to_i
  ftp = VolcanoFtp.new(port)
  ftp.run
rescue SystemExit, Interrupt
  puts 'Caught CTRL+C, exiting'
rescue RuntimeError => e
  puts "VolcanoFTP encountered a RunTimeError : #{e}"
end

# killing all forked processes
puts "Killing all processes now..."
`pkill volcanoFTP`
