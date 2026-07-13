# frozen_string_literal: true

require "digest"
require "find"

module AgentDoctor
  module InstallOwnership
    MARKER_PREFIX = "agent-workflows-doctor-v1"
    IGNORED_ROOT_ENTRIES = [".agent-stack-managed", ".agent-workflows-managed"].freeze

    module_function

    def digest(root)
      root = File.expand_path(root)
      result = Digest::SHA256.new
      Find.find(root) do |path|
        relative = path == root ? "." : path.delete_prefix("#{root}/")
        if IGNORED_ROOT_ENTRIES.include?(relative)
          Find.prune
          next
        end

        stat = File.lstat(path)
        value = case stat.ftype
                when "file" then File.binread(path)
                when "link" then File.readlink(path)
                when "directory" then ""
                else raise ArgumentError, "unsupported doctor install entry: #{relative}"
                end
        append(result, relative, stat.ftype, (stat.mode & 0o7777).to_s(8), value)
        Find.prune if stat.symlink?
      end
      result.hexdigest
    end

    def compare(left, right)
      digest(left) == digest(right)
    rescue ArgumentError, SystemCallError
      false
    end

    def marker(root)
      "#{MARKER_PREFIX}:#{digest(root)}"
    end

    def verify(root, marker_path)
      stat = File.lstat(marker_path)
      stat.file? && File.binread(marker_path) == "#{marker(root)}\n"
    rescue ArgumentError, SystemCallError
      false
    end

    def append(result, *fields)
      fields.each do |field|
        bytes = field.to_s.b
        result << [bytes.bytesize].pack("Q>") << bytes
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  case command
  when "compare"
    exit(AgentDoctor::InstallOwnership.compare(ARGV.fetch(0), ARGV.fetch(1)) ? 0 : 1)
  when "marker"
    puts AgentDoctor::InstallOwnership.marker(ARGV.fetch(0))
  when "verify"
    exit(AgentDoctor::InstallOwnership.verify(ARGV.fetch(0), ARGV.fetch(1)) ? 0 : 1)
  else
    warn "Usage: install_ownership.rb compare LEFT RIGHT | marker ROOT | verify ROOT MARKER"
    exit 64
  end
end
