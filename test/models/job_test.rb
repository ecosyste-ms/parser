require "test_helper"

class JobTest < ActiveSupport::TestCase
  context 'validations' do
    should validate_presence_of(:url)
    should validate_uniqueness_of(:id).case_insensitive
  end

  setup do
    @job = Job.create(url: 'https://github.com/ecosyste-ms/digest/archive/refs/heads/main.zip', sidekiq_id: '123', ip: '123.456.78.9')
  end

  test 'check_status' do
    Sidekiq::Status.expects(:status).with(@job.sidekiq_id).returns(:queued)
    @job.check_status
    assert_equal @job.status, "queued"
  end

  test 'parse_dependencies_async' do
    ParseDependenciesWorker.expects(:perform_async).with(@job.id)
    @job.parse_dependencies_async
  end

  test 'parse_dependencies' do
    # TODO
  end

  context 'fast_parse?' do
    should 'quickly parse a json file' do
      @job.url = 'https://raw.githubusercontent.com/ecosyste-ms/digest/main/package.json'
      assert @job.fast_parse?
    end
  
    should 'quickly parse a Gemfile' do
      @job.url = 'https://raw.githubusercontent.com/ecosyste-ms/parser/main/Gemfile'
      assert @job.fast_parse?
    end

    should 'not quickly parse a zip file' do
      @job.url = 'https://github.com/ecosyste-ms/digest/archive/refs/heads/main.zip'
      refute @job.fast_parse?
    end
  end

  test 'basename' do
    # TODO
  end

  test 'download' do
    # TODO
  end

  test 'mime_type' do
    # TODO
  end
end
