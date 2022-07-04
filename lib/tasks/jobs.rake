namespace :jobs do
  desc "Check status of in-progress jobs"
  task check_status: :environment do
    Job.check_statuses
  end
end