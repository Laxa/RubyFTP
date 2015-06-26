#!/usr/bin/env ruby

require 'socket'
require 'yaml'
require 'logger'
require 'timeout'
require 'stringio'
require 'shellwords'
include Socket::Constants

# Volcano FTP contants
BINARY_MODE = 1
ASCII_MODE = 0
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
    @tport = nil

    # logger part
    # file = File.open('logging.log', File::WRONLY | File::TRUNC | File::CREAT)
    @log = Logger.new MultiIO.new(STDOUT)
    # make that a configurable settings in the YAML file
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
            unexpected
          rescue Exception => e
            @log.fatal "Encountered Exception : #{e}"
            unexpected
          ensure
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
    @cwd = '/'
    # rootFolder HAS to be absolute path
    # if yaml config is done, we need to be sure we have an absolute path
    @rootFolder = Dir.pwd + '/root'
    @rootFolder = '/Users/laxa/Documents'
    until (line = @cs.gets).nil?
      unless line.end_with? "\r\n"
        @log.warn "[server<-client]: #{line}"
      end
      while line.end_with? "\r\n"
        line = line[0..-2]
      end
      @log.info "[server<-client]: #{line}"
      cmd = 'ftp_' << line.split.first.downcase
      if cmd == 'ftp_quit'
        return ftp_exit
      elsif self.respond_to?(cmd, true)
        send(cmd, line.split.drop(1))
      else
        ftp_not_yet_implemented
      end
    end
    @log.warn 'Client killed connection to server'
  end

  def transmit_data(dataIO)
    send_to_client_and_log(150, 'Opening binary data connection')
    begin
      @tsocket = TCPSocket.new('localhost', @tport)
    rescue => e
      return send_to_client_and_log(425, "#{e}")
    end
    begin
      until (data = dataIO.gets).nil?
        @tsocket.write(data)
      end
    rescue => e
      send_to_client_and_log(426, "#{e}")
    ensure
      @tsocket.close
    end
    send_to_client_and_log(226, 'Done')
  end

  def unexpected
    send_to_client_and_log(421, 'Something unexpected happened')
  end

  # List the Working directory if no args is specified, otherwise, list folder/file
  def ftp_list(args)
    # we use '.' as ref to be sure we don't go out of ftp folder
    unless (args.first.nil?)
      path = @rootFolder + File.expand_path(args.first, @cwd)
    else
      path = @rootFolder + @cwd
    end
    path = Shellwords.escape(path)
    data = `ls -la #{path}`
    @log.debug "#{path}"
    if (data.length.zero? or data.nil?)
      return send_to_client_and_log(500, 'Problem occured')
    end
    dataIO = StringIO.new(data)
    transmit_data(dataIO)
  end

  # Change Working Directory
  # client is sending relative path on rootFolder
  def ftp_cwd(args)
    return send_to_client_and_log(501, 'No argument') if args.first.nil?
    target = File.expand_path(args.join(' '), @cwd)
    @log.debug "#{target}"
    if File.directory? @rootFolder + target
      @cwd = target
      @log.debug "New cwd: #{@cwd}"
      return send_to_client_and_log(250, "CWD set to #{@cwd}")
    else
      return send_to_client_and_log(500, 'Target is not valid')
    end
  end

  # store file
  def ftp_stor(args)
    # TODO
    ftp_not_yet_implemented
  end

  # retrieve file
  def ftp_retr(args)
    # TODO
    ftp_not_yet_implemented
  end

  def ftp_syst(args)
    send_to_client_and_log(215, 'UNIX Type: L8')
  end

  # check connection is alive
  def ftp_noop
    send_to_client_and_log(200, 'OK')
  end

  def ftp_not_yet_implemented
    send_to_client_and_log(502, 'Not yet implemented')
  end

  def ftp_exit(args = nil)
    send_to_client_and_log(221, 'Thank you for using VolcanoFTP')
  end

  def ftp_quit(args)
    ftp_exit(args)
  end

  # Define transfer type between client and server
  def ftp_type(args)
    if (args.first.downcase == 'i')
      send_to_client_and_log(200, "Transfer type is set to 'Binary data'")
    else
      send_to_client_and_log(504, 'Only binary data transfer type accepted')
    end
  end

  # Define passive mode, client connect to server for data transmissions
  def ftp_pasv(args)
    ftp_not_yet_implemented
  end

  # define port to use for data transmission, only handle active mode in Volcano
  def ftp_port(args)
    begin
      args = args.first.split(/,/)
      @tport = args[4].to_i << 8 | args[5].to_i
    rescue => e
      return send_to_client_and_log(500, "#{e}")
    end
    send_to_client_and_log(200, "Port is set to #{@tport}")
  end

  def is_port_open?(port)
    unless (@tsocket.nil?)
      @tsocket.close
    end
    begin
      Timeout::timeout(1) do
        begin
          @tsocket = TCPSocket.new('127.0.0.1', port)
          puts "toto"
          return true
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
          return false
        end
      end
    rescue Timeout::Error
      puts "timeout"
    end
    return false
  end

  # Handle basic AUTH
  def ftp_user(args)
    send_to_client_and_log(230, 'You are now logged in as Anonymous')
  end

  # Print Working Directory
  def ftp_pwd(args)
    send_to_client_and_log(257, @cwd)
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
  # using standart FTP port if none is specified in CLI
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
