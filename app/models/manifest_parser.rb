require "json"
require "tempfile"
require "timeout"

class ManifestParser
  class Error < StandardError; end

  def self.parse(path)
    run("-strip-components", "1", "--", path.to_s)
  end

  def self.identify(filename)
    run("-identify", "--", filename).fetch(:supported)
  end

  def self.run(*arguments, timeout: 300)
    command = ENV.fetch("MANIFEST_PARSER_COMMAND", Rails.root.join("tmp", "manifest-parser").to_s)
    Tempfile.create("manifest-parser-output") do |output|
      Tempfile.create("manifest-parser-error") do |errors|
        pid = Process.spawn(command, *arguments, in: File::NULL, out: output, err: errors, pgroup: true)
        begin
          _, status = Timeout.timeout(timeout) { Process.wait2(pid) }
        rescue Timeout::Error
          begin
            Process.kill("KILL", -pid)
          rescue Errno::ESRCH
          end
          Process.wait(pid)
          raise Error, "manifest parser timed out"
        end

        errors.rewind
        raise Error, errors.read.strip.presence || "manifest parser exited with status #{status.exitstatus}" unless status.success?

        output.rewind
        result = JSON.parse(output.read, symbolize_names: true)
        raise Error, "manifest parser returned a non-object result" unless result.is_a?(Hash)

        result
      end
    end
  rescue JSON::ParserError => error
    raise Error, "manifest parser returned invalid JSON: #{error.message}"
  rescue Errno::ENOENT => error
    raise Error, "manifest parser executable not found: #{error.message}"
  end
end
