source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby '4.0.0'

gem "railties", "~> 8.1.1"
gem "activesupport", "~> 8.1.1"
gem "activemodel", "~> 8.1.1"
gem "activerecord", "~> 8.1.1"
gem "actionpack", "~> 8.1.1"
gem "actionview", "~> 8.1.1"

gem "secure_headers"
gem "sprockets-rails"
gem "pg"
gem "puma"
gem "jbuilder"
gem "bootsnap", require: false
gem "sassc-rails"
gem "faraday"
gem "faraday-retry"
gem "faraday-gzip"
gem "faraday-follow_redirects"
gem "faraday-multipart"
gem 'faraday-net_http_persistent'
gem "redis"
gem "sidekiq"
gem 'sidekiq-status'
gem "ecosystems-bibliothecary", github: 'ecosyste-ms/bibliothecary', require: 'bibliothecary'
gem "pghero"
gem 'bootstrap'
gem 'rack-cors'
gem 'rswag-api'
gem 'rswag-ui'
gem 'nokogiri'
gem 'appsignal'
gem 'csv'
gem 'ostruct'


group :development do
  gem "web-console"
end

group :test do
  gem "shoulda"
  gem "webmock"
  gem "mocha"
  gem "rails-controller-testing"
  gem "minitest", "~> 5.0"
end

gem "bootstrap-icons", require: "bootstrap_icons"

group :development, :test do
  gem "dotenv-rails", "~> 3.2"
end
