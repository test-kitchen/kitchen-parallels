source "https://rubygems.org"

if ENV["TEST_KITCHEN_PATH"]
  gem "test-kitchen", path: ENV.fetch("TEST_KITCHEN_PATH")
else
  gem "test-kitchen", github: "test-kitchen/test-kitchen", ref: "891904408ce03df546120e6b67e4e7888ecd432e"
end

gemspec development_group: :test

gem "rake"

group :cookstyle do
  gem "cookstyle"
end

group :smoke do
  gem "kitchen-ansible", "~> 0.58.0"
  gem "kitchen-cinc", "~> 1.1.0"
  gem "kitchen-puppet", "~> 3.7.0"
  gem "mixlib-install", "4.1.0", source: "https://rubygems.cinc.sh"
end
