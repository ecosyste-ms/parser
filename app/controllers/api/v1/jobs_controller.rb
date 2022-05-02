class Api::V1::JobsController < Api::V1::ApplicationController
  def create
    @job = Job.new(url: params[:url], status: 'pending', ip: request.remote_ip)
    if @job.save
      if @job.fast_parse?
        @job.parse_dependencies
      else
        @job.parse_dependencies_async
      end
      redirect_to api_v1_job_path(@job)
    else
      # validation error
    end
  end

  def show
    @job = Job.find(params[:id])
  end
end