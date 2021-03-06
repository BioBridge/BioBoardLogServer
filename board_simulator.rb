#!/usr/bin/env ruby
require 'socket'

project_name = 'BATCH1'

host = 'localhost'
port = 9090
header = "!BIOBOARD:0.1\n"


def format_msg(str)
  schar = '@'
  echar = "$"

  "#{schar}#{str}#{echar}\n"
end

def format_data(val)
  format_msg("PH:0:#{val}") + format_msg("TC:1:#{val+1}")
end

def probe_enumeration
  str = format_msg("PR:PH:0")
  str += format_msg("PR:TC:1")
  str += format_msg("PREND")
end

def project_identification(project_name)
  format_msg("PROJ:#{project_name}")
end

s = TCPSocket.open(host, port)

s.send(header, 0)

s.send(project_identification(project_name), 0)

s.send(probe_enumeration, 0)

1000.times do |i|

  n = Math.exp((i.to_f / 100))

  s.send(format_data(n), 0)

#  line = s.gets

#  puts "Received: #{line}"

  sleep(3)

end


