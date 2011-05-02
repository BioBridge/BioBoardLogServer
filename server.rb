#!/usr/bin/env ruby

require 'rubygems'
require 'active_record'
require 'eventmachine'
require 'json'

$outputs = []

class Project < ActiveRecord::Base
end

class Probe < ActiveRecord::Base
  belongs_to :probe_type
end

class ProbeType < ActiveRecord::Base
  has_many :probes
end


class Measurement < ActiveRecord::Base
end


class ProtocolException < Exception

end


class JSONPHandler

  def self.header
   "GET /data.js HTTP/1.1"
  end

  def self.type
    :output
  end

  def initialize(connection)
    @state = :initializing # :initializing or :ready
    @connection = connection
    @req_end = "\r\n\r\n"
    @data = ''

    @headers = {
      'Content-Type' => 'text/javascript; charset=UTF-8',
      'Cache-Control' => 'max-age=0, must-revalidate'
    }
    
#    EM.add_periodic_timer(5) do 
#      send_data("ping\n") # keep-alive ping
#    end

    puts "Initialized JSONP connection"

  end

  def ready?
    if @state == :ready
      return true
    end
    false
  end

  def output(str)
    send_response(str) if ready?
  end

  def send_init_response
    @connection.send_data("HTTP/1.1 200 OK\r\n")

    @headers.each_pair do |key, value|
      @connection.send_data("#{key}: #{value}\r\n")
    end

    @connection.send_data("\r\n")
    puts "jsonp init response sent"
  end

  def send_response(str)

    @connection.send_data("parseResponse(#{str.to_json});\r\n")
    @connection.send_data("\r\n\r\n")

    @connection.close_connection_after_writing
    cleanup
  end

  def handle(ndata)
    @data += ndata
    if @data.index(@req_end)
      puts "jsonp got double newline"
      send_init_response
      @state = :ready
    end
  end

  def handle_error(str='')
    puts "error: #{str}"
    @connection.close_connection
    cleanup
  end

  def cleanup
    $outputs.delete(self)
  end

end


class BioBoardHandler

  def self.header
    "!BIOBOARD:0.1"
  end

  def self.type
    :input
  end

  def initialize(connection)
    @connection = connection

    @project = nil
    @probes = []

    # The phase of communications:
    #  :initialized - Header received, waiting for project ID message
    #  :project_identified - The project ID packet has been received, waiting for probe enumeration
    #  :ready - Probe enumeration completed, ready for data
    @phase = :initialized 

    # The state of low-level data reception:
    #  :ready - Ready for new msg
    #  :in_progress - Currently receiving a message
    #  :error - Badness

    @state = :ready

    @data = ''

    @schar = '@'
    @echar = "$"
  end

  def find_probe_by_arduino_name(arduino_name)
    @probes.each do |probe|
      if probe.arduino_name == arduino_name
        return probe
      end
    end
    return nil
  end


  def handle_data(msg)

    m = Measurement.new

    probe_type, arduino_probe_name, m.value = msg.split(':')

    probe = find_probe_by_arduino_name(arduino_probe_name)

    m.probe_id = probe.id
    m.time = Time.now
    m.save!

    output(msg)

    puts "saved!"
  end

  def handle_msg(msg)
    msg = msg[(@schar.length)..(-1-@echar.length)] # start start and end 
    puts "Got message: " + msg

    if @phase == :ready
      handle_data(msg)
    elsif @phase == :project_identified

      handle_probe_enumeration(msg)
      
    elsif @phase == :initialized

      handle_project_id(msg)
    end      
  end

  def handle_probe_enumeration(msg)
    if msg == 'PREND'
      if @probes.length <= 0
        handle_error('probe enumeration incomplete: no probes')
        return
      end
      puts "Probe enumeration complete"
      @phase = :ready
    else

      puts "Enumerating a probe ======================"
      
      label, probe_type_name, arduino_name = msg.split(':')
      if label != 'PR'
        handle_error('probe enumeration error: invalid message')
        return
      end
      
      probe = Probe.joins(:probe_type).where(["probe_types.name = ? and arduino_name = ? and project_id = ?", probe_type_name, arduino_name, @project.id]).find(:first)

      if !probe
        probe_type = ProbeType.find_by_name(probe_type_name)
        if !probe_type
          handle_error("probe enumeration error: unknown probe type")
          return
        end

        probe = Probe.new
        probe.project_id = @project.id
        probe.probe_type_id = probe_type.id
        probe.arduino_name = arduino_name
        probe.save!
      end

      @probes << probe

    end
  end

  def handle_project_id(msg)
    label, project_name = msg.split(':')
    if label != 'PROJ'
      handle_error("invalid project identification message: #{label}")
      return
    end

    if project_name == ''
      handle_error('invalid project identification: no project name given')
      return
    end

    @project = Project.find_by_name(project_name)
    if !@project
      handle_error('invalid project identification: project not found')
      return
    end

    puts "Project identified: #{@project.name} - #{@project.name}"

    @phase = :project_identified
  end

  def output(str)
    $outputs.each do |output|
      output.output(str)
    end
  end

  def handle_error(str='')
    puts "error: #{str}"
    @connection.close_connection
    @state = :error
  end

  def handle(ndata)
    begin
      while(ndata.length > 0)

        if @state == :error
          return

        elsif @state == :ready 
          if ndata[0..0] != @schar
            handle_error("wrong start char: #{ndata[0..0]}")
            return
          end
          
          index = ndata.index(@echar)
          if !index
            @data = ndata
            @state = :in_progress
          else
            @data = ndata[0..index]
            ndata = ndata[index+1..-1]
            handle_msg(@data)
            @state = :ready
          end

        elsif @state == :in_progress
          
          index = ndata.index(@echar)
          if !index
            @data += ndata
          else
            @data += ndata[0..index]
            ndata = ndata[index+1..-1]
            handle_msg(@data)
            @state = :ready
          end
        end
      end
    rescue ProtocolException => e
      handle_error("Exception: #{e}")
      return
    end
  end

end


class MessageConnection < EM::Connection
  attr_accessor :options

  
  def post_init
    
    @reset_char = '!'

    @state = :header  # :header (waiting for header) or :handling (got header, data sent to handler)

    @handlers = [BioBoardHandler, JSONPHandler]

    @longest_header_length = 0

    @handlers.each do |handler|
      if handler.header.length > @longest_header_length
        @longest_header_length = handler.header.length
      end
    end

    @data = ''
    
    puts "new connection"
  end

  
  def handler_from_header

    @handlers.each do |handler|
      if handler.header == @data[0..(handler.header.length-1)]
        h = handler.new(self)
        if handler.type == :output
          $outputs << h
        end
        return h, @data[handler.header.length..-1]
      end
    end

    raise "invalid header"


  end

  def receive_data(ndata)

    begin

      ndata = ndata.gsub("\n", '')
      ndata = ndata.gsub("\r", '')

      puts "got: " + ndata.inspect

      # reset when a reset char is encountered
      if ndata.index(@reset_char)
        ndata = ndata[ndata.index(@reset_char)..-1]
        @state = :header
      end

      if @state == :header
        if !ndata || (ndata == '')
          puts "error: connection closed before header received"
          close_connection
          return
        end
        
        @data += ndata
        @handler, ndata = handler_from_header
        
        if !@handler && @data.length >= @longest_header_length
          puts "error: header invalid"
          close_connection
        end
        
        if @handler
          @state = :handling
          @data = ''
        end
      end

      if @state == :handling
        @handler.handle(ndata)      
      end
      
    end
  rescue Exception => e
    puts "exception: #{e}"
    close_connection
  end
    
end



ActiveRecord::Base.establish_connection(
                                        :adapter  => 'sqlite3',
                                        :database => '../test.sqlite',
                                        :pool => 5,
                                        :timeout => 5000)

EM::run do
#  ip = '10.0.0.2'
  ip = '127.0.0.1'
  port = 9090

  EM::start_server(ip, port, MessageConnection) do |con|
    con.options = {}
  end
  puts 'running echo server on ' + port.to_s
end
