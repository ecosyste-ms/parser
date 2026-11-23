class Job < ApplicationRecord
  class DownloadError < StandardError; end

  class DownloadLimitError < DownloadError; end

  class ExtractError < StandardError; end

  ARCHIVE_MIME_TYPES = ["application/zip", "application/java-archive", "application/gzip"]
  DOWNLOAD_TIMEOUT = 60
  MAX_DOWNLOAD_SIZE = 250.megabytes
  MAX_EXTRACTED_SIZE = 1.gigabyte
  MAX_REDIRECTS = 5
  REDIRECT_CODES = [301, 302, 303, 307, 308]
  DENIED_RANGES = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
    192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
    ::/128 ::1/128 64:ff9b::/96 fc00::/7 fe80::/10 ff00::/8
  ].map { |range| IPAddr.new(range) }

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
    # TODO check size (head request)
    return true if single_parsable_file? 
  end

  def perform_dependency_parsing
    begin
      Dir.mktmpdir do |dir|
        sha256 = download_file(dir)
        archive = archive?(working_directory(dir))

        # single file results depend on the url's filename, so only archives are reused
        if archive && (existing_job = Job.find_by(sha256: sha256, status: 'complete'))
          results = existing_job.results
        else
          Timeout::timeout(5.minutes) do
            results = parse_dependencies(dir)
          end
        end
        update!(results: results, status: 'complete', sha256: sha256)
      end
    rescue => e
      update(results: {error: e.inspect}, status: 'error')
    end
  end

  def archive?(path)
    ARCHIVE_MIME_TYPES.include?(mime_type(path))
  end

  def parse_dependencies(dir)
    path = working_directory(dir)

    case mime_type(path)
    when *ARCHIVE_MIME_TYPES
      destination = File.join([dir, 'archive'])
      extract_archive(path, destination)
      results = Bibliothecary.analyse(destination)
    when "text/plain", "application/json" # TODO there will be other mime types that need to be supported here
      results = Bibliothecary.analyse_file(basename, File.open(path).read)
    else
      results = []
    end

    return { manifests: results.map{|m| normalize_manifest(m) }}
  end

  # Re-streams the archive as uncompressed tar so the unpacked size can be
  # counted before it reaches disk; rlimit_fsize covers sparse entries.
  def extract_archive(path, destination)
    FileUtils.mkdir(destination)
    extracted = 0

    IO.popen(["bsdtar", "-cf", "-", "@#{path}"], "rb", err: File::NULL) do |source|
      IO.popen(["bsdtar", "--strip-components=1", "-xf", "-", "-C", destination], "wb", err: File::NULL, rlimit_fsize: MAX_EXTRACTED_SIZE) do |sink|
        while (chunk = source.read(1.megabyte))
          extracted += chunk.bytesize
          break if extracted > MAX_EXTRACTED_SIZE
          sink.write(chunk)
        end
      rescue Errno::EPIPE
        # extractor exited early; its exit status is checked below
      end
      raise ExtractError, "archive contains a file larger than #{MAX_EXTRACTED_SIZE} bytes" if $?.signaled?
    end

    raise ExtractError, "archive unpacks to more than #{MAX_EXTRACTED_SIZE} bytes" if extracted > MAX_EXTRACTED_SIZE

    # symlinks could point the parser at files outside the archive
    Dir.glob("**/*", File::FNM_DOTMATCH, base: destination).each do |entry|
      entry = File.join(destination, entry)
      File.delete(entry) if File.symlink?(entry)
    end
  end

  def normalize_manifest(manifest)
    manifest_hash = manifest.is_a?(Hash) ? manifest.dup : manifest.to_h
    manifest_hash.transform_keys!{ |key| key == :platform ? :ecosystem : key }

    dependencies = manifest_hash[:dependencies]
    if dependencies.is_a?(Array)
      dependencies = dependencies.map do |dep|
        if dep.is_a?(Bibliothecary::Dependency)
          dependency_to_hash(dep)
        else
          dep
        end
      end
    end

    {
      ecosystem: manifest_hash[:ecosystem],
      path: manifest_hash[:path],
      dependencies: dependencies,
      kind: manifest_hash[:kind],
      success: manifest_hash[:success],
      related_paths: manifest_hash[:related_paths]
    }
  end

  def dependency_to_hash(dep)
    hash = {
      name: dep.name,
      requirement: dep.requirement,
      type: dep.type || "runtime"
    }

    hash[:local] = dep.local unless dep.local.nil?

    hash
  end

  def download_file(dir, timeout: DOWNLOAD_TIMEOUT, max_size: MAX_DOWNLOAD_SIZE)
    path = working_directory(dir)
    target = url
    response = nil
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    (MAX_REDIRECTS + 1).times do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise DownloadLimitError, "download timed out" if remaining <= 0
      response = fetch(target, path, timeout: remaining, max_size: max_size)
      raise DownloadLimitError, "download timed out" if response.timed_out?
      break unless REDIRECT_CODES.include?(response.code)
      location = response.headers && response.headers["Location"]
      raise DownloadError, "redirect without a location" if location.blank?
      target = URI.join(target, Array(location).last).to_s
    end

    raise DownloadError, "too many redirects" if REDIRECT_CODES.include?(response.code)
    raise DownloadError, "unexpected response #{response.code}" unless response.code == 200

    Digest::SHA256.file(path).hexdigest
  end

  # Redirects are followed by the caller so every hop gets the same checks.
  def fetch(target, path, timeout:, max_size:)
    uri = URI.parse(target)
    raise DownloadError, "unsupported url" unless uri.is_a?(URI::HTTP) && uri.hostname.present?

    options = { followlocation: false, timeout_ms: (timeout * 1000).ceil }
    pinned = public_addresses(uri.hostname)
    # pin the checked addresses so curl cannot re-resolve to a different one
    resolve_list = Ethon::Curl.slist_append(nil, "#{uri.hostname}:#{uri.port}:#{pinned.join(',')}") if pinned
    options[:resolve] = resolve_list if resolve_list

    size = 0
    response = File.open(path, "wb") do |file|
      request = Typhoeus::Request.new(uri.to_s, options)
      request.on_body do |chunk, streamed|
        next unless streamed.code == 200
        size += chunk.bytesize
        next :abort if size > max_size
        file.write(chunk)
      end
      request.run
    end

    raise DownloadLimitError, "download larger than #{max_size} bytes" if size > max_size
    response
  ensure
    Ethon::Curl.slist_free_all(resolve_list) if resolve_list
  end

  # Returns the addresses to pin for a hostname, nil for an IP literal.
  def public_addresses(host)
    literal = begin
      IPAddr.new(host)
    rescue IPAddr::InvalidAddressError
      nil
    end

    addresses = literal ? [literal.to_s] : resolve_host(host)
    raise DownloadError, "could not resolve #{host}" if addresses.empty?
    raise DownloadError, "address not allowed" if addresses.any? { |address| denied_address?(address) }

    return nil if literal
    addresses.map { |address| address.include?(":") ? "[#{address}]" : address }
  end

  def resolve_host(host)
    Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address).uniq
  end

  def denied_address?(address)
    ip = IPAddr.new(address.split("%").first)
    ip = ip.native if ip.ipv4_mapped?
    DENIED_RANGES.any? { |range| range.include?(ip) }
  end

  def mime_type(path)
    IO.popen(
      ["file", "--brief", "--mime-type", path],
      in: :close, err: :close
    ) { |io| io.read.chomp }
  end

  def single_parsable_file?
    Bibliothecary.identify_manifests([basename]).any?
  end

  def working_directory(dir)
    # fixed name: the URL basename is attacker-controlled
    File.join([dir, "download"])
  end

  def basename
    File.basename(url)
  end

  def self.formats
    {
      actions: [
        "action.yml",
        "action.yaml",
        ".github/workflows/*.yml",
        ".github/workflows/*.yaml",
      ],
      bentoml: [
        "bentofile.yaml"
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
        "*.podspec",
        "*.podspec.json"
      ],
      cog: [
        "cog.yaml"
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
      cyclonedx: [
        "cyclonedx.xml",
        "cyclonedx.json",
        "*.cdx.xml",
        "*.cdx.json"
      ],
      docker: [
        "Dockerfile",
        "docker-compose*.yml",
        "docker-compose*.yaml",
      ],
      dub: [
        "dub.json",
        "dub.sdl"
      ],
      dvc: [
        "dvc.yaml"
      ],
      elm: [
        "elm-package.json",
        "elm_dependencies.json",
        "elm-stuff/exact-dependencies.json"
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
        "sbt-update-full.txt",
        "maven-dependency-tree.txt",
        "maven-dependency-tree.dot",
        "gradle.lockfile",
        "verification-metadata.xml"
      ],
      meteor: [
        "versions.json"
      ],
      mlflow: [
        "MLmodel"
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
      ollama: [
        "Modelfile"
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
        "req*.txt",
        "req*.pip",
        "requirements/*.txt",
        "requirements/*.pip",
        "requirements.frozen",
        "pip-resolved-dependencies.txt",
        "pip-dependency-graph.json",
        "Pipfile",
        "Pipfile.lock",
        "pyproject.toml",
        "poetry.lock",
        "pylock*.toml",
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
        "vcpkg.json",
        "_generated-vcpkg-list.json"
      ],
    }
  end
end
