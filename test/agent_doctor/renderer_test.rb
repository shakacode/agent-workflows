# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../../bin/agent_doctor/renderer"

class AgentDoctorRendererTest < Minitest::Test
  def test_human_summary_derives_component_count_from_payload
    output = StringIO.new
    payload = {
      "status" => "healthy",
      "components" => %w[first second].map do |name|
        { "component" => name, "status" => "healthy", "checks" => [] }
      end
    }

    AgentDoctor::Renderer.human(payload, output: output)

    assert_includes output.string, "2 components: 2 healthy, 0 degraded, 0 failed"
  end
end
