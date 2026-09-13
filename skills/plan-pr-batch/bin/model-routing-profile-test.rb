#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
load File.expand_path("model-routing-profile", __dir__)

class ModelRoutingProfileTest < Minitest::Test
  def test_pilot_routes_judgment_and_retains_bounded_implementation
    assert_equal "gpt-6-astra", ModelRoutingProfile.resolve("diagnosis").dig("preference", "model")
    assert_equal "high", ModelRoutingProfile.resolve("difficult-review").dig("preference", "effort")
    assert_equal "xhigh", ModelRoutingProfile.resolve("adversarial-review").dig("preference", "effort")
    assert_equal "gpt-5.6-terra", ModelRoutingProfile.resolve("bounded-implementation").dig("preference", "model")
    assert_equal "helper", ModelRoutingProfile.resolve("deterministic-work").dig("preference", "class")
  end

  def test_profile_never_infers_runtime_or_measured_superiority
    result = ModelRoutingProfile.resolve("integration")
    assert result.fetch("advisory")
    assert_equal "unmeasured-pilot", result.fetch("status")
    assert_equal ["UNKNOWN"], result.fetch("observed").values.uniq
  end

  def test_unknown_role_and_profile_reject
    assert_raises(KeyError) { ModelRoutingProfile.resolve("unknown-role") }
    assert_raises(KeyError) { ModelRoutingProfile.resolve("diagnosis", "unknown-profile") }
  end
end
