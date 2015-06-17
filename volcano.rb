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

    Dir.chdir(__dir__)

    @pids = []
    @transfert_type = BINARY_MODE
    @tsocket = nil

    # logger part
    file = File.open('logging.log', File::WRONLY | File::TRUNC | File::CREAT)
    @log = Logger.new MultiIO.new(STDOUT, file)
    @log.level = Logger::DEBUG
    @log.progname = 'VolcanoFTP'
    @log.formatter = proc do |severity, datetime, progname, msg|
      "[#{datetime} ##{Process.pid}] #{severity} -- #{progname}: #{msg}\n"
    end
    @log.info "Server is listening on port #{port}"

    # change that to root of FTP folder within yaml config file
    Dir.chdir(__dir__ + '/root')
  end

  def run
    while (42)
      selectResult = IO.select([@socket], nil, nil, 1)
      if selectResult == nil or selectResult[0].include?(@socket) == false
        @pids.each do |pid|
          if not Process.waitpid(pid, Process::WNOHANG).nil?
            ####
            # Gather data/stats here for last terminated process
            ####
            @pids.delete(pid)
          end
        end
      else
        @cs,  = @socket.accept
        peeraddr = @cs.peeraddr.dup
        @pids << Kernel.fork do
          begin
            @log.info "Instanciating connection from #{@cs.peeraddr[2]}:#{@cs.peeraddr[1]}"
            @cs.write "220 Connected to VolcanoFTP\r\n"
            while not (line = @cs.gets).nil?
              if not line.end_with? "\r\n"
                @log.warn "[server<-client]: #{line}"
              end
              while line.end_with? "\r\n"
                line = line[0..-2]
              end
              @log.info "[server<-client]: #{line}"
              cmd = 'ftp_' << line.split.first
              if self.respond_to?(cmd, true)
                send(cmd, line.split.delete(0))
              else
                ftp_502(line)
              end
              # Handle commands here
            end
          rescue RuntimeError => e
            @log.fatal "Client encountered a problem while talking with server : #{e}"
            @cs.close
            Kernel.exit!
          rescue Exception
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

  def ftp_syst(args)
    @cs.write "215 UNIX Type: L8\r\n"
    @log.info "[server->client]: 215 UNIX Type: L8"
  end

  def ftp_noop(args)
    @cs.write "200 Don't worry my lovely client, I'm here ;)\r\n"
    @log.info "[server->client]: 200 Don't worry my lovely client, I'm here ;)"
  end

  def ftp_502(*args)
    @cs.write "502 Command not implemented\r\n"
    @log.info "[server->client]: 502 Command not implemented"
  end

  def ftp_exit(args = nil)
    @cs.write "221 Thank you for using VolcanoFTP\r\n"
    @log.info "[server->client]: 221 Thank you for using Volcano FTP"
  end

  def ftp_USER(args)
    @cs.write "230 You are now logged in as Anonymous\r\n"
    @log.info "[server->client]: 230 You are now logged in as Anonymous"
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
  ftp = VolcanoFtp.new(ARGV[0].to_i)
  ftp.run
rescue SystemExit, Interrupt
  puts 'Caught CTRL+C, exiting'
rescue RuntimeError => e
  puts "VolcanoFTP encountered a RunTimeError : #{e}"
end
# killing all forked processes

puts "Killing all processes now..."
`pkill volcanoFTP`
