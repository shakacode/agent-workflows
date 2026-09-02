# frozen_string_literal: true

module ManualTesting
  module EvidenceUpload
    ATTACHMENT_URL = %r{\Ahttps://github\.com/user-attachments/assets/[A-Za-z0-9_-]+\z}

    class UnsafeArtifact < StandardError; end

    module_function

    def exact_attachment_url?(value)
      value.is_a?(String) && value.match?(ATTACHMENT_URL)
    end

    def verified_artifact(path)
      expanded = File.expand_path(path)
      stat = File.lstat(expanded)
      raise UnsafeArtifact, "artifact must be a non-symlink regular file" unless stat.file? && !stat.symlink?

      File.realpath(expanded)
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, Errno::EACCES
      raise UnsafeArtifact, "artifact must be an existing non-symlink regular file"
    end
  end
end
