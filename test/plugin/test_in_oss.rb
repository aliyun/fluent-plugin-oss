require 'fluent/test'
require 'fluent/test/helpers'
require 'fluent/test/log'
require 'fluent/test/driver/input'
require 'fluent/plugin/in_oss'
require 'test/unit/rr'
require 'uuidtools'

class OSSInputTest < Test::Unit::TestCase

  include Fluent::Test::Helpers
  include REXML

  def setup
    Fluent::Test.setup
    @time = Time.now
    stub(Fluent::EventTime).now { @time } if Fluent.const_defined?(:EventTime)
  end

  CONFIG = %(
    endpoint  #{ENV['OSS_ENDPOINT']}
    bucket    #{ENV['OSS_BUCKET']}
    access_key_id #{ENV['ACCESS_KEY_ID']}
    access_key_secret #{ENV['ACCESS_KEY_SECRET']}
    oss_sdk_log_dir .
    store_as #{ENV['STORE_AS']}
    store_local #{ENV['STORE_LOCAL']}
    <mns>
      endpoint #{ENV['MNS_ENDPOINT']}
      queue #{ENV['MNS_QUEUE']}
      wait_seconds #{ENV['WAIT_SECONDS']}
      poll_interval_seconds #{ENV['POLL_INTERVAL_SECONDS']}
    </mns>
    <parse>
      @type json
    </parse>
  ).freeze

  def create_driver
    Fluent::Test::Driver::Input.new(Fluent::Plugin::OSSInput)
  end

  def test_configuration
    driver = create_driver
    driver.configure(CONFIG)

    assert_equal(driver.instance.endpoint, ENV['OSS_ENDPOINT'])
    assert_equal(driver.instance.bucket, ENV['OSS_BUCKET'])
    assert_equal(driver.instance.access_key_id, ENV['ACCESS_KEY_ID'])
    assert_equal(driver.instance.access_key_secret, ENV['ACCESS_KEY_SECRET'])
    assert_equal(driver.instance.oss_sdk_log_dir, '.')
    assert_equal(driver.instance.store_as, ENV['STORE_AS'])
    assert_not_equal(driver.instance.store_as, ENV['STORE_AS'] + '-')

    assert_equal(driver.instance.store_local, ENV['STORE_LOCAL'].to_bool) unless ENV['STORE_LOCAL'].nil?

    assert_not_equal(driver.instance.store_local, !ENV['STORE_LOCAL'].to_bool) unless ENV['STORE_LOCAL'].nil?

    assert_equal(driver.instance.mns.endpoint, ENV['MNS_ENDPOINT'])
    assert_equal(driver.instance.mns.queue, ENV['MNS_QUEUE'])
    assert_equal(driver.instance.mns.wait_seconds, ENV['WAIT_SECONDS'].to_i) unless ENV['WAIT_SECONDS'].nil?
    assert_equal(driver.instance.mns.poll_interval_seconds, ENV['POLL_INTERVAL_SECONDS'].to_i) unless ENV['POLL_INTERVAL_SECONDS'].nil?

    assert_equal(driver.instance.parser_configs[0]['@type'], 'json')

    driver.instance.shutdown
    puts driver.logs
  end

  def test_emit_events
    driver = create_driver
    driver.configure(CONFIG)

    expect_records = 12_345
    oss = create_oss(driver)

    bucket = oss.get_bucket(driver.instance.bucket)

    # create test object to bucket
    content = get_random_content(expect_records)
    object = get_test_object(content, bucket, driver.instance.store_as)

    driver.run(expect_records: expect_records)

    assert_equal(driver.events.size, expect_records)

    result = ''
    driver.events.each do |event|
      result << event[2].to_s.gsub(/=>/, ':') << "\n"
    end

    assert_equal(result, content)

    assert_false(driver.instance.instance_variable_get(:@running))
    puts driver.logs

    # delete test object
    bucket.delete_object(object)
  end

  def test_no_events
    driver = create_driver
    driver.configure(CONFIG)

    expect_records = 0
    driver.run(expect_records: expect_records)

    assert_equal(driver.events.size, expect_records)

    assert_false(driver.instance.instance_variable_get(:@running))
    puts driver.logs
  end

  def get_test_object(content, bucket, store_as)
    object = 'fluentd-oss-test-' + ::UUIDTools::UUID.random_create.to_s
    io = Tempfile.new(object)
    io.binmode
    io.write(content)
    io.rewind

    out = Tempfile.new('chunk-test-' + store_as + '-out-')
    out.binmode

    case store_as
    when 'text'
      object += '.txt'
      bucket.put_object(object, file: io.path)
    when 'json'
      object += '.' + store_as
      bucket.put_object(object, file: io.path)
    when 'gzip_command', 'gzip'
      object += '.gz'
      system "gzip -c #{io.path} > #{out.path}"
      bucket.put_object(object, file: out.path)
    when 'lzo'
      object += '.' + store_as
      system "lzop -qf1 -c #{io.path} > #{out.path}"
      bucket.put_object(object, file: out.path)
    when 'lzma2'
      object += '.xz'
      system "xz -qf0 -c #{io.path} > #{out.path}"
      bucket.put_object(object, file: out.path)
    end

    io.close(true) rescue nil
    out.close(true) rescue nil
    object
  end

  def get_random_content(lines)
    content = []
    lines.times do |i|
      value = ::UUIDTools::UUID.random_create.to_s + '-' + i.to_s
      content.append('{"message":"' + value + '"}' + "\n")
    end
    content.join
  end

  def create_oss(driver)
    Aliyun::OSS::Client.new(
      endpoint: driver.instance.endpoint,
      access_key_id: driver.instance.access_key_id,
      access_key_secret: driver.instance.access_key_secret
    )
  end
end