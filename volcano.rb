#!/usr/bin/env ruby

require 'rubygems'
require 'nokogiri'
require 'securerandom'
require 'socket'
require 'yaml'
require 'logger'
require 'timeout'
require 'stringio'
include Socket::Constants

# Volcano FTP class
class VolcanoFtp
  def initialize
    conf = config_yaml
    if conf['Bind']
      @socket = TCPServer.new(@bind, @port)
    else
      @socket = TCPServer.new @port
    end
    @socket.listen(42)

    @tsocket = nil
    @tport = nil

    # logger part
    @log = Logger.new STDOUT
    raise 'Log level not defined in config' unless conf['LogLevel'] >= 0 and conf['LogLevel'] <= 5
    @log.level = conf['LogLevel']
    @log.progname = 'VolcanoFTP'
    @log.formatter = proc do |severity, datetime, progname, msg|
      "[#{datetime} ##{Process.pid}] #{severity} -- #{progname}: #{msg}\n"
    end
    ip = @bind.nil? ? '127.0.0.1' : @bind
    @log.info "Server is listening on port #{@port} on #{ip}"
  end

  def config_yaml
    yaml_content = YAML.load_file('conf.yml')
    if yaml_content['Port'].nil?
      @port = 21
    else
      @port = yaml_content['Port']
    end
    if Process.euid != 0 and @port < 1024
      raise 'You need root privilege to bind on port < 1024'
    end
    @bind = yaml_content['Bind']
    if File.directory? yaml_content['Dir']
      @rootFolder = yaml_content['Dir']
    else
      raise "'#{yaml_content['dir']}' is not a correct directory"
    end
    return yaml_content
  end

  def run
    while 42
      selectResult = IO.select([@socket], nil, nil, 1)
      @cs,  = @socket.accept
      peeraddr = @cs.peeraddr.dup
      Kernel.fork do
        begin
          @logintime = Time.now
          @sessionid = SecureRandom.hex(10)
          @fileXml = Nokogiri::XML::DocumentFragment.parse ''
          @file_node = Nokogiri::XML::Node.new('file', @fileXml)
          @filecount = 0
          handle_client
        rescue SignalException => e
          @log.warn "Caught signal #{e}"
          unexpected
        rescue Exception => e
          @log.fatal "Encountered Exception : #{e}"
          unexpected
        ensure
          logouttime = Time.now
          duration = logouttime - @logintime
          if File.exist?('stat.xml')
            xmlFile = File.read('stat.xml')
          else
            xmlFile = '<volcano></volcano>'
          end
          xmlData = Nokogiri::XML.parse xmlFile
          session_node = Nokogiri::XML::Node.new('session', xmlData)
          logintime_node = Nokogiri::XML::Node.new('logintime', xmlData)
          logouttime_node = Nokogiri::XML::Node.new('logouttime', xmlData)
          duration_node = Nokogiri::XML::Node.new('duration', xmlData)
          filecount_node = Nokogiri::XML::Node.new('filecount', xmlData)

          session_node['id'] = @sessionid
          logintime_node.content = @logintime
          logouttime_node.content = logouttime
          duration_node.content = duration
          filecount_node.content = @filecount

          session_node << logintime_node
          session_node << logouttime_node
          session_node << duration_node
          @file_node << filecount_node
          session_node << @file_node
          xmlData.root << session_node

          File.open('stat.xml', 'w') do |file|
            file.print xmlData.to_xml
          end

          @log.info "Killing connection from #{peeraddr[2]}:#{peeraddr[1]}"
          @cs.close
          Kernel.exit!
        end
      end
    end
  end

  protected

  def handle_client
    @log.info "Instanciating connection from #{@cs.peeraddr[2]}:#{@cs.peeraddr[1]}"
    send_to_client_and_log(220, 'Connected to VolcanoFTP')
    # client connection is on his root folder
    @cwd = '/'
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
    return send_to_client_and_log(451, 'Need PORT command') if @tport.nil?
    send_to_client_and_log(150, 'Opening binary data connection')
    begin
      @tsocket = TCPSocket.new('localhost', @tport)
    rescue => e
      dataIO.close
      @tport = nil
      return send_to_client_and_log(425, "#{e}")
    end
    begin
      transfered_bytes = 0
      until (data = dataIO.gets).nil?
        @tsocket.write(data)
        transfered_bytes += data.size
      end
    rescue => e
      send_to_client_and_log(426, "#{e}")
    ensure
      @tsocket.close
      @tport = nil
      dataIO.close
      @log.info "Transfered #{transfered_bytes} bytes"
      file = Nokogiri::XML::Node.new("file#{@filecount}_size", @fileXml)
      file.content = transfered_bytes
      @file_node << file
      @filecount += 1
    end
    send_to_client_and_log(226, 'Done')
  end

  def receive_data(dataIO)
    return send_to_client_and_log(451, 'Need PORT command') if @tport.nil?
    send_to_client_and_log(150, 'Opening binary data connection')
    begin
      @tsocket = TCPSocket.new('localhost', @tport)
    rescue => e
      dataIO.close
      @tport = nil
      return send_to_client_and_log(425, "#{e}")
    end
    begin
      transfered_bytes = 0
      until (data = @tsocket.gets).nil?
        dataIO.write(data)
        transfered_bytes += data.size
      end
    rescue => e
      send_to_client_and_log(426, "#{e}")
    ensure
      @tsocket.close
      @tport = nil
      dataIO.close
      @log.info "Received #{transfered_bytes} bytes"
      file = Nokogiri::XML::Node.new("file#{@filecount}_size", @fileXml)
      file.content = transfered_bytes
      @file_node << file
      @filecount += 1
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
    data = `ls -la '#{path}'`
    @log.debug "#{path}"
    if (data.length.zero? or data.nil?)
      return send_to_client_and_log(500, 'Problem occured')
    end
    io = StringIO.new(data)
    transmit_data(io)
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
    return send_to_client_and_log(501, 'No argument') if args.first.nil?
    file = @rootFolder + File.expand_path(args.join(' '), @cwd)
    @log.debug file
    return send_to_client_and_log(451, 'Dir not found') unless File.exist?(File.dirname(file))
    #    return send_to_client_and_log(451, 'File name already exist') if File.exist? file
    io = File.open(file, 'wb')
    receive_data(io)
  end

  # retrieve file
  def ftp_retr(args)
    return send_to_client_and_log(501, 'No argument') if args.first.nil?
    file = @rootFolder + File.expand_path(args.join(' '), @cwd)
    @log.debug file
    return send_to_client_and_log(451, 'File not found') unless File.exists?(file)
    io = File.open(file, 'rb')
    transmit_data(io)
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
      @tport = nil
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
    send_to_client_and_log(257, "\"#{@cwd}\" is current directory")
  end

  def send_to_client_and_log(code, data)
    @cs.write "#{code} #{data}\r\n"
    @log.info "[server->client]: #{code} #{data}"
  end

  private

end

# Main

# to kill all process if needed, we use a specific name
$0 = 'volcanoFTP'

begin
  # using standart FTP port if none is specified in CLI
  ftp = VolcanoFtp.new
  ftp.run
rescue SystemExit, Interrupt
  puts 'Caught CTRL+C, exiting'
rescue RuntimeError => e
  puts "VolcanoFTP encountered a RunTimeError : #{e}"
end

# killing all forked processes
puts 'Killing all processes now...'
`pkill volcanoFTP`
