require 'test_helper'
require 'rubygems/package'

class ApiV1JobsControllerTest < ActionDispatch::IntegrationTest
  test 'submit a job' do
    post api_v1_jobs_path(url: 'https://github.com/ecosyste-ms/digest/archive/refs/heads/main.zip')
    assert_response :redirect
    assert_match /\/api\/v1\/jobs\//, @response.location
  end

  test 'shell metacharacters in a gzip url are not executed' do
    assert_no_injection('pkg.tgz', gzipped_tarball('pkg/package.json' => '{"dependencies":{"left-pad":"1.0.0"}}')) do |job|
      assert_equal ['left-pad'], job.results['manifests'].first['dependencies'].map { |d| d['name'] }
    end
  end

  test 'shell metacharacters in a zip url are not executed' do
    assert_no_injection('main.zip', file_fixture('main.zip').binread) do |job|
      assert_includes job.results['manifests'].map { |m| m['path'] }, 'package.json'
    end
  end

  test 'parses a small manifest inline' do
    stub_request(:get, 'https://example.com/package.json').to_return(status: 200, body: '{"dependencies":{"left-pad":"1.0.0"}}')
    assert_no_difference -> { ParseDependenciesWorker.jobs.size } do
      post api_v1_jobs_path, params: { url: 'https://example.com/package.json' }
    end

    job = Job.last
    assert_equal 'complete', job.status
    assert_equal ['package.json'], job.results['manifests'].map { |m| m['path'] }
  end

  test 'hands inline downloads to the worker when they are archives, too large or too slow' do
    responses = [
      { status: 200, body: file_fixture('main.zip').binread },
      { status: 200, body: 'a' * (Job::INLINE_MAX_SIZE + 1) },
      :timeout
    ]

    responses.each_with_index do |response, index|
      url = "https://example.com/#{index}/package.json"
      stub = stub_request(:get, url)
      response == :timeout ? stub.to_timeout : stub.to_return(response)

      assert_difference -> { ParseDependenciesWorker.jobs.size }, 1 do
        post api_v1_jobs_path, params: { url: url }
      end
      assert_equal 'pending', Job.find_by(url: url).status
    end
  end

  def assert_no_injection(filename, body)
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        stub_request(:get, /attacker\.test/).to_return(status: 200, body: body)

        Sidekiq::Testing.inline! do
          post api_v1_jobs_path, params: { url: "http://attacker.test/x/#{filename};touch$IFS'INJECTED';false" }
        end
        assert_response :redirect

        refute File.exist?('INJECTED'), 'injected command ran'
        job = Job.last
        assert_equal 'complete', job.status
        yield job
      end
    end
  end

  def gzipped_tarball(files)
    io = StringIO.new
    Zlib::GzipWriter.wrap(io) do |gz|
      Gem::Package::TarWriter.new(gz) do |tar|
        files.each { |name, content| tar.add_file_simple(name, 0644, content.bytesize) { |f| f.write(content) } }
      end
    end
    io.string
  end

  test 'submit an invalid job' do
    post api_v1_jobs_path
    assert_response :bad_request

    actual_response = JSON.parse(@response.body)

    assert_equal actual_response["title"], "Bad Request"
    assert_equal actual_response["details"], ["Url can't be blank"]
  end

  test 'shows the error status when the worker failed while the job was being loaded' do
    job = Job.create(url: 'https://example.com/a.zip', status: 'working', sidekiq_id: '123')
    stale = Job.find(job.id)
    Job.where(id: job.id).update_all(status: 'error', results: { error: 'failed' })
    Job.expects(:find).with(job.id).returns(stale)
    Sidekiq::Status.stubs(:status).returns(:complete)

    get api_v1_job_path(id: job.id)
    assert_response :success
    assert_equal 'error', JSON.parse(@response.body)['status']
    assert_equal 'failed', JSON.parse(@response.body)['results']['error']
  end

  test 'check on a job' do
    @job = Job.create(url: 'https://github.com/ecosyste-ms/digest/archive/refs/heads/main.zip')

    @job.expects(:check_status)
    Job.expects(:find).with(@job.id).returns(@job)

    get api_v1_job_path(id: @job.id)
    assert_response :success
    assert_template 'jobs/show', file: 'jobs/show.json.jbuilder'
    
    actual_response = JSON.parse(@response.body)

    assert_equal actual_response["url"], @job.url
  end
end