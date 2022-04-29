require "test_helper"

class JobTest < ActiveSupport::TestCase
  context 'validations' do
    should validate_presence_of(:url)
    should validate_uniqueness_of(:id).case_insensitive
  end

  test 'check_status' do
    @job = Job.new(url: 'https://github.com/ecosyste-ms/digest/archive/refs/heads/main.zip', sidekiq_id: '123')
    Sidekiq::Status.expects(:status).with(@job.sidekiq_id).returns(:queued)
    @job.check_status
    assert_equal @job.status, "queued"
  end

  test 'parse_dependencies_async' do
    # TODO
  end

  test 'parse_dependencies' do
    # TODO
  end

  test 'fast_parse?' do
    # TODO
  end

  test 'single_parsable_file?' do
    # TODO
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
