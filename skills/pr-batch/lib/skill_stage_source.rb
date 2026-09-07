# frozen_string_literal: true

require "pathname"

# Test/size-check projection of four explicitly staged skills. Never discovers
# arbitrary files or follows canonical workflows to satisfy a skill assertion.
# Runtime readers use the conditional links in SKILL.md, not this projection.
module SkillStageSource
  STAGES = {
    "address-review" => %w[coordinated-review intake review-wave fetch claim triage],
    "plan-pr-batch" => %w[intake-and-routing lane-plan handoff prompt-template],
    "pr-batch" => %w[launch planning prompt-template decisions-and-coordination recovery],
    "post-merge-audit" => %w[scope checks issues output]
  }.freeze
  BLOCK = %r{<!-- stage-reference: ([^\n]+) -->\n(.*?)<!-- /stage-reference -->}m

  module_function

  def read(path, **options)
    text = File.read(path, **options)
    skill = File.basename(File.dirname(path))
    return text unless File.basename(path) == "SKILL.md" && STAGES.key?(skill)

    expected = STAGES.fetch(skill).map { |name| "references/#{name}.md" }
    declared = text.scan(BLOCK).map(&:first)
    raise ArgumentError, "#{path}: stage declaration mismatch" unless declared == expected

    text.gsub(BLOCK) do
      relative = Regexp.last_match(1)
      routing = Regexp.last_match(2)
      # Stage routing blocks are prose-only. A fenced/inline-code copy of a
      # link is not reachable navigation, even if its bytes match.
      link = /\[[^\]]+\]\(#{Regexp.escape(relative)}\)/
      linked = !routing.match?(/`|~{3}/) && routing.lines.any? do |line|
        line.match?(/\A[[:alpha:]]/) && line.match?(link)
      end
      unless linked
        raise ArgumentError, "#{path}: missing direct stage link: #{relative}"
      end

      stage_path = File.expand_path(relative, File.dirname(path))
      source = File.read(stage_path, **options)
      raise ArgumentError, "#{stage_path}: empty stage" if source.strip.empty?

      # Keep existing section contracts relative to their entrypoint. Actual
      # source links/anchors are separately checked by the stage graph tests.
      rebase_prose_links(source, stage_path, path)
    end
  end

  def rebase_prose_links(source, stage_path, path)
    fence = nil
    chunks = [String.new]
    source.each_line do |line|
      if fence
        chunks << line
        if line.match?(/\A {0,3}#{Regexp.escape(fence[0])}{#{fence.length},}[ \t]*\r?\n?\z/)
          fence = nil
          chunks << String.new
        end
      elsif (opening = line.match(/\A {0,3}(`{3,}|~{3,})/))
        chunks[-1] = rebase_links(chunks.last, stage_path, path)
        fence = opening[1]
        chunks << line
      else
        chunks[-1] << line
      end
    end
    chunks[-1] = rebase_links(chunks.last, stage_path, path) unless fence
    chunks.join
  end

  def rebase_links(prose, stage_path, path)
    # Match code spans before links so literal examples retain their bytes.
    pattern = /(?<code>(?<ticks>`+)(?!`).*?(?<!`)\k<ticks>(?!`))|(?<!!)\[(?<label>[^\]]*)\]\((?<target>[^)\s]+)\)/m
    prose.gsub(pattern) do |link|
      match = Regexp.last_match
      target = match[:target]
      next link if match[:code] || target.match?(%r{\A(?:[a-z][a-z0-9+.-]*:|/|#|<)}i)

      file, anchor = target.split("#", 2)
      absolute = File.expand_path(file, File.dirname(stage_path))
      adjusted = Pathname.new(absolute).relative_path_from(Pathname.new(File.expand_path(File.dirname(path))))
      "[#{match[:label]}](#{adjusted}#{anchor ? "##{anchor}" : ''})"
    end
  end

  def stage(path, name)
    read(path) # Verify the declared stage set and every direct link first.
    skill = File.basename(File.dirname(path))
    raise ArgumentError, "unknown stage: #{name}" unless STAGES.fetch(skill).include?(name)

    File.read(File.join(File.dirname(path), "references", "#{name}.md"), encoding: "UTF-8")
  end
end
