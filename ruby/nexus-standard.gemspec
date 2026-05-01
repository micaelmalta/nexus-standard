Gem::Specification.new do |spec|
  spec.name          = "nexus-standard"
  spec.version       = "1.0.0"
  spec.authors       = ["Micael Malta"]
  spec.email         = ["micael@example.com"]

  spec.summary       = "Zero-copy reader for the Nexus Standard (NXS) binary format"
  spec.description   = <<~DESC
    Pure-Ruby reader for NXB files produced by the NXS compiler. Provides
    zero-copy memory-mapped access to typed records with O(1) random access
    via the tail-index.
  DESC
  spec.homepage      = "https://github.com/micaelmalta/nxs"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.0"

  spec.files = [
    "nxs.rb",
    "README.md",
    "LICENSE",
  ]

  spec.require_paths = ["."]

  spec.metadata = {
    "source_code_uri" => "https://github.com/micaelmalta/nxs",
    "changelog_uri"   => "https://github.com/micaelmalta/nxs/releases",
  }
end
