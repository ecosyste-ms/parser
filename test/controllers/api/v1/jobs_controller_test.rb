require 'test_helper'

class ApiV1JobsControllerTest < ActionDispatch::IntegrationTest
  test 'single manifest is parsed by the Go command and returned through v1' do
    url = 'https://example.org/package.json'
    stub_request(:get, url).to_return(status: 200, body: '{"dependencies":{"example":"^1.0.0"}}')

    post api_v1_jobs_path(url: url)
    assert_response :redirect
    follow_redirect!
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal 'complete', body['status']
    assert_equal url, body['url']
    assert_equal [{
      'ecosystem' => 'npm', 'path' => 'package.json', 'kind' => 'manifest',
      'success' => true, 'related_paths' => nil,
      'dependencies' => [{ 'name' => 'example', 'requirement' => '^1.0.0', 'type' => 'runtime', 'local' => false }]
    }], body.dig('results', 'manifests')
    assert_equal body['results'], Job.find(body['id']).results
  end

  test 'archive job is parsed by the worker and returned through v1' do
    url = 'https://example.org/main.zip'
    stub_request(:get, url).to_return(status: 200, body: file_fixture('main.zip'))

    post api_v1_jobs_path(url: url)
    assert_response :redirect
    location = response.location
    job = Job.find_by!(url: url)
    ParseDependenciesWorker.new.perform(job.id)

    get location
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 'complete', body['status']
    manifests = body.dig('results', 'manifests')
    assert_equal ['Dockerfile', 'package-lock.json', 'package.json'], manifests.map { |manifest| manifest['path'] }
    assert_equal ['package-lock.json'], manifests.last['related_paths']
    assert_equal '826d05d1869c3aa66dce47e6f79fc6800f72d34b706adba1eecd0d2d5e98e17b', body['sha256']
  end

  test 'malformed manifest retains a per-file failure in a completed job' do
    stub_request(:get, 'https://example.org/package.json').to_return(status: 200, body: '{')
    post api_v1_jobs_path(url: 'https://example.org/package.json')
    follow_redirect!
    body = JSON.parse(response.body)
    assert_equal 'complete', body['status']
    manifest = body.dig('results', 'manifests').first
    assert_equal false, manifest['success']
    assert_nil manifest['dependencies']
  end

  test 'corrupt archive marks the job as errored' do
    url = 'https://example.org/broken.zip'
    stub_request(:get, url).to_return(status: 200, body: 'not a zip')
    post api_v1_jobs_path(url: url)
    job = Job.find_by!(url: url)
    ParseDependenciesWorker.new.perform(job.id)
    get api_v1_job_path(job)
    body = JSON.parse(response.body)
    assert_equal 'error', body['status']
    assert_match /zip/, body.dig('results', 'error')
  end

  test 'submit a job' do
    post api_v1_jobs_path(url: 'https://github.com/ecosyste-ms/digest/archive/refs/heads/main.zip')
    assert_response :redirect
    assert_match /\/api\/v1\/jobs\//, @response.location
  end

  test 'submit an invalid job' do
    post api_v1_jobs_path
    assert_response :bad_request

    actual_response = JSON.parse(@response.body)

    assert_equal actual_response["title"], "Bad Request"
    assert_equal actual_response["details"], ["Url can't be blank"]
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
