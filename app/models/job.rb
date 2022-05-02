class Job < ApplicationRecord
  validates_presence_of :url
  validates_uniqueness_of :id

  def check_status
    return if sidekiq_id.blank?
    return if status: 'complete'
    update(status: Sidekiq::Status.status(sidekiq_id))
  end

  def parse_dependencies_async
    sidekiq_id = ParseDependenciesWorker.perform_async(id)
    update(sidekiq_id: sidekiq_id)
  end

  def fast_parse?
    # TODO check size (head request)
    return true if single_parsable_file? 
  end

  def single_parsable_file?
    Bibliothecary.identify_manifests([basename]).any?
  end

  def basename
    File.basename(url)
  end

  def download(path)
    downloaded_file = File.open(path, "wb")

    request = Typhoeus::Request.new(url, followlocation: true)
    request.on_headers do |response|
      return nil if response.code != 200
    end
    request.on_body { |chunk| downloaded_file.write(chunk) }
    request.on_complete { downloaded_file.close }
    request.run
  end

  def mime_type(path)
    IO.popen(
      ["file", "--brief", "--mime-type", path],
      in: :close, err: :close
    ) { |io| io.read.chomp }
  end

  def parse_dependencies
    begin
      Dir.mktmpdir do |dir|
        path = File.join([dir, basename])
        download(path)

        case mime_type(path)
        when "application/zip"
          destination = File.join([dir, 'zip'])
          `unzip -q #{path} -d #{destination}`
          results = Bibliothecary.analyse(destination)
        when "application/gzip"
          destination = File.join([dir, 'tar'])
          `mkdir #{destination} && tar xzf #{path} -C #{destination} --strip-components 1`
          results = Bibliothecary.analyse(destination)
        when "text/plain", "application/json" # TODO there will be other mime types that need to be supported here
          results = Bibliothecary.analyse_file(basename, File.open(path).read)
        else
          # not supported (error maybe?)
          results = []
        end
        # TODO change platform to ecosystem
        update!(results: results)
      end

    rescue
      # TODO record error
      update!(results: [])
    end
  end
end
