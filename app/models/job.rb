class Job < ApplicationRecord
  validates_presence_of :url
  validates_uniqueness_of :id

  scope :status, ->(status) { where(status: status) }

  def self.clean_up
    Job.status(["complete",'error']).where('created_at < ?', 1.week.ago).in_batches.delete_all
  end

  def self.check_statuses
    Job.where(status: ["queued", "working"]).find_each(&:check_status)
  end

  def check_status
    return if sidekiq_id.blank?
    return if finished?
    update(status: fetch_status)
  end

  def fetch_status
    Sidekiq::Status.status(sidekiq_id).presence || 'error'
  end

  def finished?
    ['complete', 'error'].include?(status)
  end

  def start_dependency_parsing
    if fast_parse?
      perform_dependency_parsing
    else
      parse_dependencies_async
    end
  end

  def parse_dependencies_async
    sidekiq_id = ParseDependenciesWorker.perform_async(id)
    update(sidekiq_id: sidekiq_id)
  end

  def fast_parse?
    single_parsable_file?
  end

  def perform_dependency_parsing
    begin
      Dir.mktmpdir do |dir|
        sha256 = download_file(dir)

        if existing_job = Job.find_by(sha256: sha256, status: 'complete')
          results = existing_job.results
        else
          results = parse_dependencies(dir)
        end
        update!(results: results, status: 'complete', sha256: sha256)
      end
    rescue => e
      update(results: {error: e.inspect}, status: 'error')
    end
  end

  def parse_dependencies(dir)
    ManifestParser.parse(working_directory(dir))
  end

  def download_file(dir)
    path = working_directory(dir)
    downloaded_file = File.open(path, "wb")

    request = Typhoeus::Request.new(url, followlocation: true, timeout: 60)
    request.on_headers do |response|
      return nil unless [200,301,302].include? response.code
    end
    request.on_body { |chunk| downloaded_file.write(chunk) }
    request.on_complete { downloaded_file.close }
    request.run

    return Digest::SHA256.hexdigest File.read(path)
  end

  def single_parsable_file?
    ManifestParser.identify(basename)
  end

  def working_directory(dir)
    File.join([dir, basename])
  end

  def basename
    File.basename(url)
  end

  def self.formats
    {
      actions: [
        ".github/workflows/*.yml",
        ".github/workflows/*.yaml",
      ],
      bower: [
        "bower.json"
      ],
      cargo: [
        "Cargo.toml",
        "Cargo.lock"
      ],
      carthage: [
        "Cartfile",
        "Cartfile.private",
        "Cartfile.resolved"
      ],
      clojars: [
        "project.clj"
      ],
      cocoapods: [
        "Podfile",
        "Podfile.lock",
        "*.podspec"
      ],
      conan: [
        "conanfile.txt",
        "conanfile.py",
        "conan.lock"
      ],
      conda: [
        "environment.yml",
        "environment.yaml",
      ],
      cpan: [
        "META.json",
        "META.yml"
      ],
      cran: [
        "DESCRIPTION",
        "renv.lock"
      ],
      docker: [
        "Dockerfile",
        "docker-compose.yml",
        "docker-compose.yaml",
      ],
      dub: [
        "dub.json",
        "dub.sdl"
      ],
      elm: [
        "elm-package.json"
      ],
      go: [
        "glide.yaml",
        "glide.lock",
        "Godeps",
        "Godeps/Godeps.json",
        "vendor/manifest",
        "vendor/vendor.json",
        "Gopkg.toml",
        "Gopkg.lock",
        "go.mod",
        "go.sum",
        "go-resolved-dependencies.json"
      ],
      hackage: [
        "*.cabal",
        "cabal.config",
        "stack.yaml.lock"
      ],
      haxelib: [
        "haxelib.json"
      ],
      hex: [
        "mix.exs",
        "mix.lock"
      ],
      homebrew: [
        "Brewfile",
        "Brewfile.lock.json"
      ],
      julia: [
        "REQUIRE"
      ],
      luarocks: [
        "*.rockspec"
      ],
      maven: [
        "pom.xml",
        "ivy.xml",
        "build.gradle",
        "build.gradle.kts",
        "gradle-dependencies-q.txt",
        "maven-resolved-dependencies.txt",
        "gradle.lockfile",
        "verification-metadata.xml"
      ],
      nimble: [
        "*.nimble"
      ],
      npm: [
        "package.json",
        "package-lock.json",
        "npm-shrinkwrap.json",
        "yarn.lock",
        "bun.lock",
        "npm-ls.json",
        "pnpm-lock.yaml"
      ],
      nuget: [
        "packages.config",
        "packages.lock.json",
        "Project.json",
        "Project.lock.json",
        "*.nuspec",
        "paket.lock",
        "*.csproj",
        "project.assets.json",
        "*.deps.json"
      ],
      packagist: [
        "composer.json",
        "composer.lock"
      ],
      pub: [
        "pubspec.yaml",
        "pubspec.lock"
      ],
      pypi: [
        "setup.py",
        "*requirements*.txt",
        "requirements/*.txt",
        "requirements.frozen",
        "pip-resolved-dependencies.txt",
        "pip-dependency-graph.json",
        "Pipfile",
        "Pipfile.lock",
        "pyproject.toml",
        "poetry.lock",
        "pylock.toml",
        "pdm.lock",
        "uv.lock"
      ],
      rubygems: [
        "Gemfile",
        "Gemfile.lock",
        "gems.rb",
        "gems.locked",
        "*.gemspec"
      ],
      shards: [
        "shard.yml",
        "shard.lock"
      ],
      swiftpm: [
        "Package.swift",
        "Package.resolved"
      ],
      vcpkg: [
        "vcpkg.json"
      ],
    }
  end
end
