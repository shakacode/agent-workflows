#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

SCRIPT = File.expand_path("validate-doc-links", __dir__)
load SCRIPT

class ValidateDocLinksTest < Minitest::Test
  DOC = "docs/operator-handbook.md"

  def with_doc_root
    Dir.mktmpdir("validate-doc-links-test") do |root|
      FileUtils.mkdir_p(File.join(root, "docs"))
      FileUtils.mkdir_p(File.join(root, "workflows"))
      write(root, "workflows/pr-processing.md", <<~MARKDOWN)
        # PR Processing

        ## Review Completion Gate

        Body.

        ## Promotion, Publishing, And Rollback Authority

        Body.
      MARKDOWN
      yield root
    end
  end

  def write(root, relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def validate(root)
    ValidateDocLinks.validate(root, documents: [DOC])
  end

  def test_valid_relative_and_anchor_links_pass
    with_doc_root do |root|
      write(root, DOC, <<~MARKDOWN)
        # Operator Handbook

        ## Where human judgment is required

        - [Review Completion Gate](../workflows/pr-processing.md#review-completion-gate)
        - [Promotion, Publishing, And Rollback Authority](../workflows/pr-processing.md#promotion-publishing-and-rollback-authority)
        - [Workflow](../workflows/pr-processing.md)
        - [Same document](#where-human-judgment-is-required)
        - [External](https://github.com/shakacode/agent-workflows#anything)
      MARKDOWN

      assert_empty validate(root)
    end
  end

  def test_missing_relative_file_fails
    with_doc_root do |root|
      write(root, DOC, <<~MARKDOWN)
        # Operator Handbook

        [Gone](../workflows/pr-missing.md#review-completion-gate)
      MARKDOWN

      assert_equal(
        ["#{DOC}:3: link target not found: ../workflows/pr-missing.md"],
        validate(root)
      )
    end
  end

  def test_missing_heading_anchor_fails
    with_doc_root do |root|
      write(root, DOC, <<~MARKDOWN)
        # Operator Handbook

        [Renamed](../workflows/pr-processing.md#review-completion-gate-renamed)
      MARKDOWN

      assert_equal(
        ["#{DOC}:3: heading anchor not found in workflows/pr-processing.md: #review-completion-gate-renamed"],
        validate(root)
      )
    end
  end

  def test_missing_anchor_in_same_document_fails
    with_doc_root do |root|
      write(root, DOC, "# Operator Handbook\n\n[Self](#no-such-section)\n")

      assert_equal(
        ["#{DOC}:3: heading anchor not found in #{DOC}: #no-such-section"],
        validate(root)
      )
    end
  end

  def test_missing_checked_document_fails
    with_doc_root do |root|
      assert_equal(["#{DOC}: checked document not found"], validate(root))
    end
  end

  def test_anchor_slugs_follow_github_normalization
    text = <<~MARKDOWN
      # Operator Handbook
      ## Merge Decision Under `ask`
      ### 1. Scope Decision
      ## Promotion, Publishing, And Rollback Authority
      ## Under_score And *emphasis*
    MARKDOWN

    assert_equal(
      %w[
        operator-handbook
        merge-decision-under-ask
        1-scope-decision
        promotion-publishing-and-rollback-authority
        under_score-and-emphasis
      ],
      ValidateDocLinks.heading_anchors(text)
    )
  end

  def test_duplicate_headings_get_numeric_suffixes
    text = "## Authority\n## Authority\n## Authority\n"

    assert_equal %w[authority authority-1 authority-2], ValidateDocLinks.heading_anchors(text)
  end

  def test_duplicate_heading_suffixes_skip_explicitly_occupied_slugs
    text = "## Authority\n## Authority-1\n## Authority\n"

    assert_equal %w[authority authority-1 authority-2], ValidateDocLinks.heading_anchors(text)
  end

  def test_inline_code_and_escaped_link_syntax_are_not_links
    text = <<~'MARKDOWN'
      `[Code Example](missing.md)` \[Escaped Example](missing.md) [Real](real.md)
    MARKDOWN

    assert_equal [["real.md", 1]], ValidateDocLinks.links(text)
  end

  def test_fenced_code_blocks_are_not_headings_and_do_not_contain_links
    text = <<~MARKDOWN
      # Real Heading

      ```bash
      # MERGE_STYLE is a comment, not a heading
      [Fake](../workflows/does-not-exist.md#nope)
      ```

      ~~~
      ## Also not a heading
      ~~~

      ## After The Fences
    MARKDOWN

    assert_equal %w[real-heading after-the-fences], ValidateDocLinks.heading_anchors(text)
    assert_equal [], ValidateDocLinks.links(text)
  end

  def test_fenced_code_inside_the_checked_document_is_skipped
    with_doc_root do |root|
      write(root, DOC, <<~MARKDOWN)
        # Operator Handbook

        ```markdown
        [Example](../workflows/pr-missing.md#nope)
        ```

        [Real](../workflows/pr-processing.md#review-completion-gate)
      MARKDOWN

      assert_empty validate(root)
    end
  end

  def test_document_without_relative_links_fails
    with_doc_root do |root|
      write(root, DOC, "# Operator Handbook\n\n[External](https://example.com)\n")

      assert_equal ["#{DOC}: no relative links found"], validate(root)
    end
  end

  def test_link_to_a_directory_fails
    with_doc_root do |root|
      write(root, DOC, "# Operator Handbook\n\n[Dir](../workflows)\n")

      assert_equal ["#{DOC}:3: link target not found: ../workflows"], validate(root)
    end
  end

  def test_repository_operator_handbook_links_resolve
    root = File.expand_path("..", __dir__)

    assert_empty ValidateDocLinks.validate(root)
  end
end
