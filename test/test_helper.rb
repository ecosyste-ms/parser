ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

require 'webmock/minitest'
require 'mocha/minitest'

Sidekiq.testing!(:fake)

# shoulda-context overrides format_rerun_snippet with a version that calls an instance-level executable
Rails::TestUnitReporter.class_eval do
  def executable
    self.class.executable
  end
end

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
