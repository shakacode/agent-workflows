# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../../bin/agent_doctor/install_ownership"

class AgentDoctorInstallOwnershipTest < Minitest::Test
  def setup
    @temporary = Dir.mktmpdir
    @source = File.join(@temporary, "source")
    @destination = File.join(@temporary, "destination")
    FileUtils.mkdir_p(File.join(@source, "nested"))
    File.write(File.join(@source, "nested", "module.rb"), "source\n")
    FileUtils.cp_r(@source, @destination, preserve: true)
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def test_compare_includes_content_and_mode
    assert AgentDoctor::InstallOwnership.compare(@source, @destination)

    File.chmod(0o600, File.join(@destination, "nested", "module.rb"))

    refute AgentDoctor::InstallOwnership.compare(@source, @destination)
  end

  def test_marker_verifies_only_the_recorded_tree
    marker = File.join(@destination, ".agent-workflows-managed")
    File.write(marker, "#{AgentDoctor::InstallOwnership.marker(@destination)}\n")

    assert AgentDoctor::InstallOwnership.verify(@destination, marker)
    File.write(File.join(@destination, "nested", "module.rb"), "changed\n")
    refute AgentDoctor::InstallOwnership.verify(@destination, marker)
  end

  def test_comparison_ignores_only_root_ownership_markers
    File.write(File.join(@destination, ".agent-stack-managed"), "agent-stack-module-v1:agent_doctor\n")
    File.write(File.join(@destination, ".agent-workflows-managed"), "recorded digest\n")

    assert AgentDoctor::InstallOwnership.compare(@source, @destination)
  end

  def test_digest_is_independent_of_equivalent_tree_creation_order
    first = File.join(@temporary, "first")
    second = File.join(@temporary, "second")
    entries = { "alpha.txt" => "alpha\n", "middle.txt" => "middle\n", "zeta.txt" => "zeta\n" }
    FileUtils.mkdir_p([first, second])
    entries.each { |name, value| File.write(File.join(first, name), value) }
    entries.reverse_each { |name, value| File.write(File.join(second, name), value) }
    creation_orders = { first => entries.keys, second => entries.keys.reverse }
    original_find = Find.method(:find)
    Find.singleton_class.define_method(:find) do |root, &block|
      block.call(root)
      creation_orders.fetch(root).each { |name| block.call(File.join(root, name)) }
    end
    begin
      assert_equal AgentDoctor::InstallOwnership.digest(first), AgentDoctor::InstallOwnership.digest(second)
    ensure
      Find.singleton_class.define_method(:find, original_find)
    end
  end
end
