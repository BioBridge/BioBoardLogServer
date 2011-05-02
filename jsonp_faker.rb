#!/usr/bin/env ruby

require 'socket'
require 'rubygems'
require 'json'

host = 'localhost'
port = 9090
header = "BioBoard0.1"


def format_msg(str)

end

s = TCPSocket.open(host, port)

s.send(header, 0)



1000.times do |i|

  n = Math.exp((i.to_f / 100))

  msg = format_msg("42:#{n}")
  
  s.send(msg, 0)

  puts "Sent: #{msg}"

  line = s.gets

  puts "Received: #{line}"

  sleep(3)

end


