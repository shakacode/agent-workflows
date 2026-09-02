# frozen_string_literal: true

module RubyFileSurface
  module_function

  def ruby_file?(path)
    return true if path.end_with?(".rb", ".rake", ".gemspec", ".ru")
    return true if File.basename(path).match?(/\A(?:Gemfile|Rakefile)\z/)

    first_line(path)&.match?(%r{\A#!\s*(?:/usr/bin/env\s+|/(?:usr/)?bin/)ruby(?:\s|\z)})
  end

  def first_line(path)
    File.open(path, "rb") { |file| file.gets(nil, 256) }
  rescue ArgumentError, Errno::EACCES, Errno::ENOENT
    nil
  end
end
