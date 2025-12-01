#!/bin/env ruby
## finder.rb

require 'find'
require 'json'
require 'pry'

def log(message, level = :debug)
  puts sprintf('[%s] [%5s] %s', Time.now.strftime('%H.%M.%S'), level.to_s.upcase!, message)
  exit(1) if level.eql?(:fatal)
end

def output(found, file)
  File.open(file, 'w') do |f|
    f.puts(JSON.pretty_unparse(found))
  end
end


## main()
input  = ARGV.last
output = sprintf('found.%s.json', $$)

log(sprintf('input[%s]', input))
log(sprintf('output[%s]', output))

files = Hash.new
found = Find.find(input).to_a.sort

log(sprintf('found[%d] candidates', found.size))

found.each do |f|
  next if File.directory?(f)
  next if f.match(/\._/) # no silly hidden files
  next if f.match(/\.THM/) # no theme files from gopro
  next if f.match(/\.LRV/) # don't even know what these are in the first place
  next unless f.match(/2025/) # temporary
  if files.has_key?(f)
    binding.pry
  end

  files[f] = Hash.new

end

log(sprintf('filtered to[%d] candidates', files.size))
output(files, output)

binding.pry
