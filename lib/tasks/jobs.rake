namespace :jobs do
  desc "Check status of in-progress jobs"
  task check_status: :environment do
    Job.check_statuses
  end

  desc 'clean up old jobs'
  task clean_up: :environment do
    Job.clean_up
  end
end