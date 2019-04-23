# Aliyun OSS plugin for [Fluentd](http://github.com/fluent/fluentd)

It is fully free and fully open source. The license is Apache 2.0, meaning you are pretty much free to use it whatever you want.

## Overview
**Fluent OSS output plugin** buffers event logs in local files and uploads them to OSS periodically in background threads.

This plugin splits events by using the timestamp of event logs. For example,  a log '2019-04-09 message Hello' is reached, and then another log '2019-04-10 message World' is reached in this order, the former is stored in "20190409.gz" file, and latter in "20190410.gz" file.

**Fluent OSS input plugin** reads data from OSS periodically.

This plugin uses MNS on the same region of the OSS bucket. We must setup MNS and OSS event notification before using this plugin.

[This document](https://help.aliyun.com/document_detail/52656.html) shows how to setup MNS and OSS event notification.

This plugin will poll events from MNS queue and extract object keys from these events, and then will read those objects from OSS.

## Installation

Simply use RubyGems(Run command in td-agent installation directory):
```bash
[root@master td-agent]# ./embedded/bin/fluent-gem install fluent-plugin-oss
```
Then, you can check installed plugin
```bash
[root@master td-agent]# ./embedded/bin/fluent-gem list fluent-plugin-oss

*** LOCAL GEMS ***

fluent-plugin-oss (0.0.1)
```

## Development

### 1. Plugin Developement and Testing

#### Code
- Install dependencies

```sh
bundle install
```

#### Test

- Update your dependencies

```sh
bundle install
```

- Run tests
You should set environment variables like below:

test_out_oss.rb
```sh
STORE_AS="" OSS_ENDPOINT="" ACCESS_KEY_ID="" ACCESS_KEY_SECRET="" OSS_BUCKET="" OSS_PATH=""  bundle exec rspec test/plugin/test_out_oss.rb
```

test_in_oss.rb
```sh
STORE_AS=""  OSS_ENDPOINT="" ACCESS_KEY_ID="" ACCESS_KEY_SECRET="" OSS_BUCKET="" MNS_ENDPOINT="" MNS_QUEUE=""  bundle exec rspec test/plugin/test_in_oss.rb

```

## Usage
This is an example of fluent config.

It will read data posted by HTTP and buffer data to local directory before writing to OSS.
You can try it by running curl command:
```bash
[root@master td-agent]# while [[ 1 ]]; do curl -X POST -d 'json={"json":"message"}' http://localhost:8888/debug.test; done
```
	<match debug.*>
	  @type oss
	  endpoint <OSS endpoint to connect to>
	  bucket <Your Bucket>
	  access_key_id <Your Access Key>
	  access_key_secret <Your Secret Key>
	  path fluent-oss/logs
	  auto_create_bucket true
	  key_format %{path}/%{time_slice}_%{index}_%{thread_id}.%{file_extension}
	  store_as gzip
	  <buffer tag,time>
	    @type file
	    path /var/log/fluent/oss
	    timekey 60 # 1 min partition
	    timekey_wait 20s
	    #timekey_use_utc true
	  </buffer>
	  <format>
	    @type json
	  </format>
	</match>
	
	# HTTP input
	# POST http://localhost:8888/<tag>?json=<json>
	# POST http://localhost:8888/td.myapp.login?json={"user"%3A"me"}
	# @see http://docs.fluentd.org/articles/in_http
	<source>
	  @type http
	  @id input_http
	  port 8888
	</source>


## Configuration: Output Plugin
This plugin supports the following configuration options

|Configuration|Type|Required|Comments|Default|
|:---:|:---:|:---:|:---:|:---|
|endpoint|string|Yes|OSS endpoint to connect|
|bucket|string|Yes|Your OSS bucket name|
|access_key_id|string|Yes|Your access key id|
|access_key_secret|string|Yes|Your access secret key|
|path|string|No|Prefix that added to the generated file name|fluent/logs|
|oss_sdk_log_dir|string|No|OSS SDK log directory|/var/log/td-agent|
|upload_crc_enable|bool|No|Enable upload crc check|true|
|download_crc_enable|bool|No|Enable download crc check|true|
|open_timeout|integer|No|Timeout seconds for open connections|10|
|read_timeout|integer|No|Timeout seconds for read response|120|
|key_format|string|No|The format of OSS object keys|%{path}/%{time_slice}\_%{index}\_%{thread_id}.%{file_extension}|
|store_as|string|No|Archive format on OSS|gzip|
|auto_create_bucket|bool|No|Create OSS bucket if it does not exists|true|
|overwrite|bool|No|Overwrite already existing OSS path|false|
|check_bucket|bool|No|Check bucket if exists or not|true|
|check_object|bool|No|Check object before creation|true|
|hex_random_length|integer|No|The length of `%{hex_random}` placeholder(4-16)|4|
|index_format|string|No|`sprintf` format for `%{index}`|%d|
|warn_for_delay|time|No|Set a threshold of events latency and mark these slow events as delayed, output warning logs if delayed events were put into OSS|nil|

### Some configuration details
**key_format**

The format of OSS object keys. You can use the following built-in variables to generate keys dynamically:
*   %{path}
*   %{time_slice}
*   %{index}
*   %{file_extension}
*   %{hex_random}
*   %{uuid_flush}
*   %{thread_id}

* %{path} is exactly the value of **path** configured in the configuration file.
E.g., "fluent/logs" in the example configuration above.
* %{time_slice} is the time-slice in text that are formatted with **time_slice_format**.
* %{index} is the sequential number starts from 0, increments when multiple files are uploaded to OSS in the same time slice.
* %{file_extension} depends on **store_as** parameter.
* %{thread_id} is the unique ids of flush threads(flush thread number is define by `flush_thread_count`). You can use %{thread_id} with other built-in variables to make unique object names. 
* %{uuid_flush} a uuid that is renewed everytime the buffer is flushed. If you want to use this placeholder, install `uuidtools` gem first.
* %{hex_random} a random hex string that is renewed for each buffer chunk, not
guaranteed to be unique. This is used for performance tuning as the article below described,
[OSS performance best practice](https://help.aliyun.com/document_detail/64945.html).
You can configure the length of string with a
`hex_random_length` parameter (Default is 4).

The default format is `%{path}/%{time_slice}_%{index}_%{thread_id}.%{file_extension}`.
For instance, using the example configuration above, actual object keys on OSS
will be something like(flush_thread_count is 1):

    "fluent-oss/logs_20190410-10_15_0_69928273148640.gz"
    "fluent-oss/logs_20190410-10_16_0_69928273148640.gz"
    "fluent-oss/logs_20190410-10_17_0_69928273148640.gz"
    
With the configuration(flush_thread_count is 2):

    key_format %{path}/events/ts=%{time_slice}/events_%{index}_%{thread_id}.%{file_extension}
    time_slice_format %Y%m%d-%H
    path fluent-oss/logs

You get:

    fluent-oss/logs/events/ts=20190410-10/events_0_69997953090220.gz
    fluent-oss/logs/events/ts=20190410-10/events_0_69997953090620.gz
    fluent-oss/logs/events/ts=20190410-10/events_1_69997953090220.gz
    fluent-oss/logs/events/ts=20190410-10/events_1_69997953090620.gz
    fluent-oss/logs/events/ts=20190410-10/events_2_69997953090220.gz
    fluent-oss/logs/events/ts=20190410-10/events_2_69997953090620.gz
    
This plugin also supports add hostname to the final object keys, with the configuration:

**Note:** You should add double quotes to value of `key_format` if use this feature

    key_format "%{path}/events/ts=%{time_slice}/#{Socket.gethostname}/events_%{index}_%{thread_id}.%{file_extension}"
    time_slice_format %Y%m%d-%H
    path fluent-oss/logs
    
You get(flush_thread_count is 1):

    fluent-oss/logs/events/ts=20190410-10/master/events_0_70186087552680.gz
    fluent-oss/logs/events/ts=20190410-10/master/events_1_70186087552680.gz
    fluent-oss/logs/events/ts=20190410-10/master/events_2_70186087552680.gz
    
**store_as**

archive format on OSS. You can use several format:
*   gzip (default)
*   json
*   text
*   lzo (Need lzop command)
*   lzma2 (Need xz command)
*   gzip_command (Need gzip command)
    *   This compressor uses an external gzip command, hence would result in
        utilizing CPU cores well compared with `gzip`
            
**auto_create_bucket**

Create OSS bucket if it does not exists. Default is true.

**check_bucket**

Check configured bucket if it exists or not. Default is true.
When it is false, fluentd will not check the existence of the configured bucket.
This is the case where bucket will be pre-created before running fluentd.

**check_object**

Check object before creation if it exists or not. Default is true.

When it is false, key_format will be %{path}/%{time_slice}\_%{hms_slice}\_%{thread_id}.%{file_extension} by default where,
hms_slice will be time-slice in hhmmss format. With hms_slice and thread_id, each object is unique.
Example object name, assuming it is created on 2019/04/10 10:30:54 AM 20190410_103054_70186087552260.txt (extension can be anything as per user's choice)

**path**

Path prefix of the files on OSS. Default is "fluent-oss/logs".

**time_slice_format**

Format of the time used as the file name. Default is '%Y%m%d'. Use
'%Y%m%d%H' to split files hourly.

**utc**

Use UTC instead of local time.

**hex_random_length**

The length of `%{hex_random}` placeholder. Default is 4.

**index_format**

`%{index}` is formatted by [sprintf](http://ruby-doc.org/core-2.2.0/Kernel.html#method-i-sprintf) using this format_string. Default is '%d'. Zero padding is supported e.g. `%04d` to ensure minimum length four digits. `%{index}` can be in lowercase or uppercase hex using '%x' or '%X'

**overwrite**

Overwrite already existing path. Default is false, which raises an error
if an OSS object of the same path already exists, or increment the
`%{index}` placeholder until finding an absent path.

**warn_for_delay**

Set a threshold to treat events as delay, output warning logs if delayed events were put into OSS.

## Configuration: Input Plugin

|Configuration|Type|Required|Comments|Default|
|:---:|:---:|:---:|:---:|:---|
|endpoint|string|Yes|OSS endpoint to connect|
|bucket|string|Yes|Your OSS bucket name|
|access_key_id|string|Yes|Your access key id|
|access_key_secret|string|Yes|Your access secret key|
|oss_sdk_log_dir|string|No|OSS SDK log directory|/var/log/td-agent|
|upload_crc_enable|bool|No|Enable upload crc check|true|
|download_crc_enable|bool|No|Enable download crc check|true|
|open_timeout|integer|No|Timeout seconds for open connections|10|
|read_timeout|integer|No|Timeout seconds for read response|120|
|store_as|string|No|Archive format on OSS|gzip|
|flush_batch_lines|integer|No|Flush to down streams every `flush_batch_lines` lines.|10000|
|flush_pause_milliseconds|integer|No|Sleep interval between two flushes to downstream.|1|
|store_local|bool|No|Store OSS Objects to local or memory before parsing(Used for objects with `text`/`json`/`gzip` formats)|true|
|mns|configuration section|Yes|MNS configurations|

### Usage
This is an example of fluent config.

    <source>
      @type oss
      endpoint <OSS endpoint to connect to>
      bucket <Your Bucket>
      access_key_id <Your Access Key>
      access_key_secret <Your Secret Key>
      flush_batch_lines 1000
      <mns>
        endpoint <MNS endpoint to connect to, E.g.,{account-id}.mns.cn-zhangjiakou-internal.aliyuncs.com>
        queue <MNS queue>
        wait_seconds 10
        poll_interval_seconds 10
      </mns>
    </source>

### Some configuration details

**store_as**
archive format on OSS. You can use several format:
*   gzip (default)
*   json
*   text
*   lzo (Need lzop command)
*   lzma2 (Need xz command)
*   gzip_command (Need gzip command)
    *   This compressor uses an external gzip command, hence would result in
        utilizing CPU cores well compared with `gzip`

**flush_batch_lines**

Flush to down streams every `flush_batch_lines` lines.

**flush_pause_milliseconds**

Sleep interval between two flushes to downstream. Default is 1ms, and wil not sleep if `flush_pause_milliseconds` is less than or equal to 0.

**store_local(default is true)**

Store OSS Objects to local or memory before parsing(Used for objects with `text`/`json`/`gzip` formats).

Objects with `lzo`/`lzma2`/`gzip_command` formats are always stored to local directory before parsing.

**format**

Parse a line as this format in the OSS object. Supported formats are "apache_error", "apache2", "syslog", "json", "tsv", "ltsv", "csv", "nginx" and "none".

**mns**

[MNS consume messages](https://help.aliyun.com/document_detail/35136.html)

*   endpoint
*   queue
*   wait_seconds
*   poll_interval_seconds  Poll messages interval from MNS

For more details about mns configurations, please view MNS documentation in the link above.

## Website, license, et. al.

| Web site          | http://fluentd.org/                       |
|-------------------|-------------------------------------------|
| Documents         | http://docs.fluentd.org/                  |
| Source repository | http://github.com/aliyun/fluent-plugin-oss |
| Discussion        | http://groups.google.com/group/fluentd    |
| Author            | Jinhu Wu                        |
| License           | Apache License, Version 2.0               |
