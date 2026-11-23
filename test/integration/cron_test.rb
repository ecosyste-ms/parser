require 'test_helper'
require 'rake'

class CronTest < ActiveSupport::TestCase
  test 'every cron command in app.json runs a defined rake task' do
    Rails.application.load_tasks if Rake::Task.tasks.empty?

    JSON.parse(Rails.root.join('app.json').read)['cron'].each do |entry|
      task = entry['command'][/rake (\S+)/, 1]
      assert Rake::Task.task_defined?(task), "#{task} is not a rake task"
    end
  end
end
