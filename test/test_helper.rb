ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

require 'webmock/minitest'
require 'mocha/minitest'

Sidekiq.testing!(:fake)

class ActiveSupport::TestCase
  setup do
    Job.any_instance.stubs(:resolve_host).returns(["93.184.216.34"])
  end

  Shoulda::Matchers.configure do |config|
    config.integrate do |with|
      with.test_framework :minitest
      with.library :rails
    end
  end
end
