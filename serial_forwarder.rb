#!/usr/bin/env ruby

#require 'rubygems'
#require 'serialport'

#sp = SerialPort.open("/dev/ttyUSB0", 19200)

#while(true) 
#  puts "Waiting..."
#  puts "Got: #{sp.read}"
#end

require 'socket'

hostname = 'localhost'
port = 9090

c = TCPSocket.open(hostname, port)

sp = File.new('/dev/ttyUSB0', 'r')
while true
  line = sp.readline
  puts line
  begin
    c.write(line)
  rescue Exception => e
    c.close
    c = TCPSocket.open(hostname, port)
  end
end

