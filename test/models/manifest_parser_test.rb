require 'test_helper'
require 'rbconfig'

class ManifestParserTest < ActiveSupport::TestCase
  test 'reports subprocess failures' do
    with_command('warn "unable to read archive"; exit 1') do
      error = assert_raises(ManifestParser::Error) { ManifestParser.parse('archive.zip') }
      assert_equal 'unable to read archive', error.message
    end
  end

  test 'rejects malformed JSON output' do
    with_command('puts "not JSON"') do
      error = assert_raises(ManifestParser::Error) { ManifestParser.parse('archive.zip') }
      assert_match /invalid JSON/, error.message
    end
  end

  test 'rejects a non-object result' do
    with_command('puts "[]"') do
      error = assert_raises(ManifestParser::Error) { ManifestParser.parse('archive.zip') }
      assert_match /non-object/, error.message
    end
  end

  test 'kills and reaps a timed-out parser' do
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, 'pid')
      with_command("File.write(#{pidfile.inspect}, Process.pid); sleep 30") do
        error = assert_raises(ManifestParser::Error) { ManifestParser.run('archive.zip', timeout: 1) }
        assert_equal 'manifest parser timed out', error.message
        pid = Integer(File.read(pidfile))
        assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      end
    end
  end

  def with_command(body)
    previous = ENV['MANIFEST_PARSER_COMMAND']
    Dir.mktmpdir do |dir|
      command = File.join(dir, 'parser')
      File.write(command, "#!#{RbConfig.ruby}\n#{body}\n")
      File.chmod(0o755, command)
      ENV['MANIFEST_PARSER_COMMAND'] = command
      yield
    end
  ensure
    ENV['MANIFEST_PARSER_COMMAND'] = previous
  end
end
