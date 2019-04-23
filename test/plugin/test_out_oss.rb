require 'fluent/test'
require 'fluent/test/helpers'
require 'fluent/test/log'
require 'fluent/test/driver/output'
require 'fluent/plugin/out_oss'
require 'test/unit/rr'
require 'uuidtools'

class OSSOutputTest < Test::Unit::TestCase

  include Fluent::Test::Helpers

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
    path #{ENV['OSS_PATH']}
    store_as #{ENV['STORE_AS']}
    <buffer tag,time>
      @type memory
      timekey 30
      timekey_wait 1s
    </buffer>
    <format>
      @type json
    </format>
  ).freeze

  def create_driver
    Fluent::Test::Driver::Output.new(Fluent::Plugin::OSSOutput)
  end

  def test_configuration
    driver = create_driver
    driver.configure(CONFIG)

    assert_equal(driver.instance.endpoint, ENV['OSS_ENDPOINT'])
    assert_equal(driver.instance.bucket, ENV['OSS_BUCKET'])
    assert_equal(driver.instance.access_key_id, ENV['ACCESS_KEY_ID'])
    assert_equal(driver.instance.access_key_secret, ENV['ACCESS_KEY_SECRET'])
    assert_equal(driver.instance.oss_sdk_log_dir, '.')
    assert_equal(driver.instance.path, ENV['OSS_PATH'])

    assert_equal(driver.instance.store_as, ENV['STORE_AS'])
    assert_not_equal(driver.instance.store_as, ENV['STORE_AS'] + '-')

    assert_equal(driver.instance.buffer_config['@type'], 'memory')
    assert_equal(driver.instance.buffer_config['timekey'], 30)
    assert_equal(driver.instance.buffer_config['timekey_wait'], 1)
    assert_equal(driver.instance.formatter_configs[0]['@type'], 'json')

    driver.instance.shutdown
    puts driver.logs
  end

  def test_write_lines
    driver = create_driver
    driver.configure(CONFIG)

    time = event_time('2019-04-16 14:26:22 UTC')

    expect_records = 12_345
    content = get_random_content(expect_records)

    expected_content = []
    driver.run(default_tag: 'oss.output') do
      content.each do |line|
        driver.feed(time, 'message' => line)
        expected_content.append("{\"message\":\"#{line}\"}")
      end
    end

    oss = create_oss(driver)

    bucket = oss.get_bucket(driver.instance.bucket)

    verify_object_content(bucket, driver.instance.path,
                          driver.instance.store_as,
                          expected_content.join("\n") + "\n")
    puts driver.logs
  end

  def test_no_writes
    driver = create_driver
    driver.configure(CONFIG)

    driver.run(default_tag: 'oss.output') do
    end

    oss = create_oss(driver)

    bucket = oss.get_bucket(driver.instance.bucket)

    verify_object_content(bucket, driver.instance.path, driver.instance.store_as, nil)
    puts driver.logs
  end

  def verify_object_content(bucket, prefix, store_as, expected_content)
    objects = []
    bucket.list_objects(prefix: prefix).each do |object|
      objects.append(object.key)
    end
    assert_true(objects.size >= 1) unless expected_content.nil?
    assert_equal(objects.size, 0) if expected_content.nil?

    contents = []
    unless expected_content.nil?
      objects.each do |object|
        contents.append(decompress_object(bucket, object, store_as))
        bucket.delete_object(object)
      end
      assert_equal(contents.join, expected_content)
    end
  end

  def create_oss(driver)
    Aliyun::OSS::Client.new(
      endpoint: driver.instance.endpoint,
      access_key_id: driver.instance.access_key_id,
      access_key_secret: driver.instance.access_key_secret
    )
  end

  def get_random_content(lines)
    content = []
    lines.times do |i|
      value = ::UUIDTools::UUID.random_create.to_s + '-' + i.to_s
      content.append(value)
    end
    content
  end

  def decompress_object(bucket, key, store_as)
    decompressed_content = ''

    contents = []
    bucket.get_object(key) do |content|
      contents.append(content)
    end

    object = 'fluentd-oss-test-' + ::UUIDTools::UUID.random_create.to_s
    io = Tempfile.new(object)
    io.binmode
    io.write(contents.join)
    io.rewind

    case store_as
    when 'text', 'json'
      decompressed_content = contents
    when 'gzip_command', 'gzip'
      stdout, succeeded = Open3.capture2("gzip -dc #{io.path}")
    when 'lzo'
      stdout, succeeded = Open3.capture2("lzop -qdc #{io.path}")
    when 'lzma2'
      stdout, succeeded = Open3.capture2("xz -qdc #{io.path}")
    end

    io.close(true) rescue nil

    if succeeded
      stdout.each_line do |line|
        decompressed_content << line
      end
    end
    decompressed_content
  end
end
