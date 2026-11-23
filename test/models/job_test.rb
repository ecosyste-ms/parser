require "test_helper"
require "rubygems/package"

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
    Dir.mktmpdir do |dir|
      FileUtils.cp(File.join(file_fixture_path, 'main.zip'), @job.working_directory(dir))
      results = @job.parse_dependencies(dir)

      assert_equal results[:manifests], [
        {
          :ecosystem=>"docker",
          :path=>"Dockerfile",
          :dependencies=>
            [{:name=>"node", :requirement=>"18.0.0-alpine", :type=>"build"}],
          :kind=>"manifest",
          :success=>true,
          :related_paths=>[]
        },
        {
          :ecosystem=>"npm",
          :path=>"package-lock.json",
          :dependencies=>
          [{:name=>"abort-controller", :requirement=>"3.0.0", :type=>"runtime", :local=>false},
            {:name=>"event-target-shim", :requirement=>"5.0.1", :type=>"runtime", :local=>false},
            {:name=>"node-fetch", :requirement=>"2.6.7", :type=>"runtime", :local=>false},
            {:name=>"tr46", :requirement=>"0.0.3", :type=>"runtime", :local=>false},
            {:name=>"webidl-conversions", :requirement=>"3.0.1", :type=>"runtime", :local=>false},
            {:name=>"whatwg-url", :requirement=>"5.0.0", :type=>"runtime", :local=>false}],
          :kind=>"lockfile",
          :success=>true,
          :related_paths=>["package.json"]
        },
        {
          :ecosystem=>"npm",
          :path=>"package.json",
          :dependencies=>
          [{:name=>"abort-controller", :requirement=>"^3.0.0", :type=>"runtime", :local=>false},
            {:name=>"node-fetch", :requirement=>"^2.6.7", :type=>"runtime", :local=>false}],
          :kind=>"manifest",
          :success=>true,
          :related_paths=>["package-lock.json"]
        }
      ]
    end
  end

  test 'works on jar files' do
    @job = Job.create(url: 'https://repo.clojars.org/vald-client-clj/vald-client-clj/v1.5.6/vald-client-clj-v1.5.6.jar', sidekiq_id: '123', ip: '123.456.78.9')

    Dir.mktmpdir do |dir|
      FileUtils.cp(File.join(file_fixture_path, 'vald-client-clj-v1.5.6.jar'), @job.working_directory(dir))
      results = @job.parse_dependencies(dir)
      
      assert_equal results[:manifests][1], {:ecosystem=>"maven",
        :path=>"maven/vald-client-clj/vald-client-clj/pom.xml",
        :dependencies=>
         [{:name=>"org.clojure:clojure", :requirement=>"1.11.1", :type=>"runtime"},
          {:name=>"io.grpc:grpc-api", :requirement=>"1.47.0", :type=>"runtime"},
          {:name=>"io.grpc:grpc-core", :requirement=>"1.47.0", :type=>"runtime"},
          {:name=>"io.grpc:grpc-protobuf", :requirement=>"1.47.0", :type=>"runtime"},
          {:name=>"io.grpc:grpc-stub", :requirement=>"1.47.0", :type=>"runtime"},
          {:name=>"io.envoyproxy.protoc-gen-validate:pgv-java-stub", :requirement=>"0.6.7", :type=>"runtime"},
          {:name=>"org.vdaas.vald:vald-client-java", :requirement=>"1.5.6", :type=>"runtime"}],
        :kind=>"manifest",
        :success=>true,
        :related_paths=>[]}
    end
  end

  test 'download_file' do
    stub_request(:get, "https://github.com/ecosyste-ms/digest/archive/refs/heads/main.zip")
      .to_return({ status: 200, body: file_fixture('main.zip') })

    Dir.mktmpdir do |dir|
      sha256 = @job.download_file(dir)
      assert_equal sha256, '826d05d1869c3aa66dce47e6f79fc6800f72d34b706adba1eecd0d2d5e98e17b'
    end
  end

  context 'extraction limit' do
    should 'refuse archives that unpack past the limit' do
      [file_fixture('main.zip').binread, ActiveSupport::Gzip.compress(tar_with('pkg/package.json' => '{}', 'pkg/big' => "\0" * 5.megabytes))].each do |body|
        job = Job.create(url: 'https://example.com/archive')
        stub_request(:get, job.url).to_return(status: 200, body: body)
        with_limit(:MAX_EXTRACTED_SIZE, 20.kilobytes) { job.perform_dependency_parsing }
        assert_equal 'error', job.status
        assert_match 'Job::ExtractError', job.results['error']
      end
    end

    should 'extract gzipped tarballs under the limit' do
      job = Job.create(url: 'https://example.com/pkg.tgz')
      stub_request(:get, job.url).to_return(status: 200, body: ActiveSupport::Gzip.compress(tar_with('pkg/package.json' => '{"dependencies":{"left-pad":"1.0.0"}}')))
      job.perform_dependency_parsing
      assert_equal 'complete', job.status
      assert_equal ['package.json'], job.results['manifests'].map { |m| m['path'] }
    end
  end

  should 'not parse through symlinks in an archive' do
    Tempfile.create(['outside', '.json']) do |outside|
      outside.write('{"dependencies":{"outside-secret":"1.0.0"}}')
      outside.flush

      io = StringIO.new
      Gem::Package::TarWriter.new(io) do |tar|
        tar.add_symlink('pkg/package.json', outside.path, 0644)
        tar.add_symlink('pkg/linked', File.dirname(outside.path), 0755)
        tar.add_file_simple('pkg/Gemfile', 0644, 10) { |f| f.write("gem 'rake'") }
      end

      job = Job.create(url: 'https://example.com/pkg.tgz')
      stub_request(:get, job.url).to_return(status: 200, body: ActiveSupport::Gzip.compress(io.string))
      job.perform_dependency_parsing

      assert_equal 'complete', job.status
      assert_equal ['Gemfile'], job.results['manifests'].map { |m| m['path'] }
    end
  end

  def tar_with(files)
    io = StringIO.new
    Gem::Package::TarWriter.new(io) do |tar|
      files.each { |name, content| tar.add_file_simple(name, 0644, content.bytesize) { |f| f.write(content) } }
    end
    io.string
  end

  def with_limit(name, bytes)
    original = Job.const_get(name)
    Job.send(:remove_const, name)
    Job.const_set(name, bytes)
    yield
  ensure
    Job.send(:remove_const, name)
    Job.const_set(name, original)
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

  context 'existing results' do
    should 'reuse existing results' do
      @existing_job = Job.create(
        url: 'https://github.com/ecosyste-ms/digest/archive/refs/heads/main.zip',
        sidekiq_id: '123',
        ip: '123.456.78.9',
        sha256: '826d05d1869c3aa66dce47e6f79fc6800f72d34b706adba1eecd0d2d5e98e17b',
        status: 'complete')
      
      stub_request(:get, "https://github.com/ecosyste-ms/digest/archive/refs/heads/main.zip")
        .to_return({ status: 200, body: file_fixture('main.zip') })

      @job.expects(:parse_dependencies).never

      @job.perform_dependency_parsing
      assert_equal @job.results, @existing_job.results
    end

    should 'not reuse existing results that errored' do
      @existing_job = Job.create(
        url: 'https://github.com/ecosyste-ms/digest/archive/refs/heads/main.zip',
        sidekiq_id: '123',
        ip: '123.456.78.9',
        sha256: '826d05d1869c3aa66dce47e6f79fc6800f72d34b706adba1eecd0d2d5e98e17b',
        status: 'error')
      
      stub_request(:get, "https://github.com/ecosyste-ms/digest/archive/refs/heads/main.zip")
        .to_return({ status: 200, body: file_fixture('main.zip') })

      @job.expects(:parse_dependencies).once

      @job.perform_dependency_parsing
    end
  end
end
