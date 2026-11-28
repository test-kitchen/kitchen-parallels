# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require_relative "lib/kitchen/driver/parallels_version"

Gem::Specification.new do |gem|
  gem.name = "kitchen-parallels"
  gem.version = Kitchen::Driver::PARALLELS_VERSION
  gem.authors = ["Dan Webb"]
  gem.email = ["dan.webb@damacus.io"]
  gem.summary = "Test Kitchen driver for Parallels Desktop"
  gem.license = "Apache-2.0"
  gem.homepage = "https://kitchen.ci/"
  gem.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "README.md", "LICENSE", "NOTICE"] }
  gem.require_paths = ["lib"]
  gem.required_ruby_version = ">= 3.1"
  gem.add_dependency "mixlib-shellout", ">= 3.0", "< 4.0"
  gem.add_dependency "rexml", ">= 3.4.2", "< 4.0"
  gem.add_dependency "test-kitchen", "~> 4.2"
  gem.add_development_dependency "minitest", "~> 5.0"
end
