class ParseDependenciesWorker
  include Sidekiq::Worker
  include Sidekiq::Status::Worker

  def perform(job_id)
    Job.find_by_id(job_id).try(:perform_dependency_parsing)
  end
end