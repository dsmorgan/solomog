#!/usr/bin/env ruby
# ingest.rb — read Kubernetes YAML/JSON (a stacked file, a JSON List, or many files)
# into one JSON array for `solomog graph INPUT=`. Each object gains `_source`.
#
# Usage: ingest.rb [--files-from list] [file ...]
#   INGEST_ROOT  when set, `_source` is the path relative to this directory.
#
# Ruby 2.6 (macOS). Local files the user pointed at — same trust as the rest of solomog.

require 'json'
require 'yaml'

def source_of(path)
  full = File.expand_path(path)
  root = ENV['INGEST_ROOT']
  if root && !root.empty?
    root = File.expand_path(root)
    prefix = root + '/'
    return full.sub(/\A#{Regexp.escape(prefix)}/, '') if full.start_with?(prefix)
  end
  File.basename(full)
end

def load_docs(path, raw)
  stripped = raw.lstrip
  return [] if stripped.empty?
  jsonish = File.extname(path) == '.json' || stripped.start_with?('{', '[')
  if jsonish
    begin
      parsed = JSON.parse(raw)
      return parsed.is_a?(Array) ? parsed : [parsed]
    rescue JSON::ParserError
      raise if File.extname(path) == '.json'
    end
  end
  YAML.load_stream(raw) || []
end

def unwrap(doc, source, out)
  return if doc.nil?
  unless doc.is_a?(Hash)
    out << { '_skip' => 'not an object', '_source' => source }
    return
  end
  if doc['kind'] == 'List' && doc['items'].is_a?(Array)
    doc['items'].each { |item| unwrap(item, source, out) }
    return
  end
  doc['_source'] = source
  out << doc
end

paths = ARGV
if paths[0] == '--files-from'
  list = paths[1] or abort 'ingest.rb: --files-from needs a path'
  paths = File.readlines(list).map { |l| l.sub(/\n\z/, '') }.reject(&:empty?)
end
abort 'ingest.rb: no files' if paths.empty?

docs = []
errors = []
paths.each do |path|
  begin
    raw = File.read(path)
    load_docs(path, raw).each { |doc| unwrap(doc, source_of(path), docs) }
  rescue StandardError => e
    errors << "#{path}: #{e.message}"
  end
end

unless errors.empty?
  warn errors.join("\n")
  exit 1
end

puts JSON.generate(docs)
